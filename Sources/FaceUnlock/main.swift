import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Vision

setbuf(stdout, nil)

enum SessionState: String {
    case locked = "LOCKED"
    case unlocked = "UNLOCKED"
}

struct FaceTemplate: Codable {
    let createdAt: Date
    let samples: Int
    let vector: [Double]
}

final class TemplateStore {
    let url: URL

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".faceunlock", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("template.json")
    }

    func load() throws -> FaceTemplate {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FaceTemplate.self, from: data)
    }

    func save(_ template: FaceTemplate) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(template)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

struct FaceFrame {
    let vector: [Double]
    let eyeOpenness: Double
    let center: CGPoint
    let size: CGSize
}

final class FaceAnalyzer {
    private let sequenceHandler = VNSequenceRequestHandler()

    func analyze(_ sampleBuffer: CMSampleBuffer) -> FaceFrame? {
        let request = VNDetectFaceLandmarksRequest()
        do {
            try sequenceHandler.perform([request], on: sampleBuffer, orientation: .up)
        } catch {
            return nil
        }

        guard let face = request.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else {
            return nil
        }

        guard let vector = Self.vector(from: face) else { return nil }
        let openness = Self.eyeOpenness(from: face)
        let box = face.boundingBox
        return FaceFrame(
            vector: vector,
            eyeOpenness: openness,
            center: CGPoint(x: box.midX, y: box.midY),
            size: CGSize(width: box.width, height: box.height)
        )
    }

    static func similarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let distance = zip(lhs, rhs).reduce(0.0) { partial, pair in
            let delta = pair.0 - pair.1
            return partial + delta * delta
        }.squareRoot()
        return max(0, min(1, 1 - distance / Double(lhs.count).squareRoot()))
    }

    static func average(_ vectors: [[Double]]) -> [Double] {
        guard let first = vectors.first else { return [] }
        var result = Array(repeating: 0.0, count: first.count)
        for vector in vectors where vector.count == result.count {
            for index in result.indices {
                result[index] += vector[index]
            }
        }
        return result.map { $0 / Double(vectors.count) }
    }

    private static func vector(from face: VNFaceObservation) -> [Double]? {
        guard let landmarks = face.landmarks else { return nil }
        let regions: [VNFaceLandmarkRegion2D?] = [
            landmarks.faceContour,
            landmarks.leftEyebrow,
            landmarks.rightEyebrow,
            landmarks.leftEye,
            landmarks.rightEye,
            landmarks.nose,
            landmarks.noseCrest,
            landmarks.medianLine,
            landmarks.outerLips,
            landmarks.innerLips
        ]

        var values: [Double] = []
        for region in regions {
            guard let region else {
                values.append(contentsOf: Array(repeating: 0.0, count: 16))
                continue
            }
            values.append(contentsOf: resample(region.normalizedPoints, targetCount: 8))
        }
        values.append(Double(face.boundingBox.width / max(face.boundingBox.height, 0.001)))
        return values
    }

    private static func resample(_ points: [CGPoint], targetCount: Int) -> [Double] {
        guard !points.isEmpty else {
            return Array(repeating: 0.0, count: targetCount * 2)
        }

        var values: [Double] = []
        for index in 0..<targetCount {
            let sourceIndex = Int(round(Double(index) * Double(points.count - 1) / Double(max(targetCount - 1, 1))))
            let point = points[min(sourceIndex, points.count - 1)]
            values.append(Double(point.x))
            values.append(Double(point.y))
        }
        return values
    }

    private static func eyeOpenness(from face: VNFaceObservation) -> Double {
        guard let left = face.landmarks?.leftEye?.normalizedPoints,
              let right = face.landmarks?.rightEye?.normalizedPoints else {
            return 0
        }
        return (eyeAspect(left) + eyeAspect(right)) / 2
    }

    private static func eyeAspect(_ points: [CGPoint]) -> Double {
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else {
            return 0
        }
        return Double((maxY - minY) / max(maxX - minX, 0.001))
    }
}

final class LivenessDetector {
    private var frames: [FaceFrame] = []
    private let maxFrames = 45

    func reset() {
        frames.removeAll()
    }

    func add(_ frame: FaceFrame) -> Bool {
        frames.append(frame)
        if frames.count > maxFrames {
            frames.removeFirst(frames.count - maxFrames)
        }
        return passed
    }

    var passed: Bool {
        guard frames.count >= 12 else { return false }
        let eyes = frames.map(\.eyeOpenness)
        let centers = frames.map(\.center)
        let sizes = frames.map(\.size)
        let eyeRange = (eyes.max() ?? 0) - (eyes.min() ?? 0)
        let centerRangeX = (centers.map(\.x).max() ?? 0) - (centers.map(\.x).min() ?? 0)
        let centerRangeY = (centers.map(\.y).max() ?? 0) - (centers.map(\.y).min() ?? 0)
        let sizeRange = (sizes.map(\.width).max() ?? 0) - (sizes.map(\.width).min() ?? 0)

        let blinkLikeChange = eyeRange > 0.045
        let naturalMotion = hypot(centerRangeX, centerRangeY) > 0.018 || sizeRange > 0.018
        return blinkLikeChange && naturalMotion
    }
}

final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "faceunlock.camera")
    private let analyzer = FaceAnalyzer()
    private var onFrame: ((FaceFrame) -> Void)?
    private var onAnyVideoFrame: (() -> Void)?
    private var onStarted: (() -> Void)?
    private var didLogFace = false
    private var didLogAnyVideoFrame = false

    func start(
        onStarted: (() -> Void)? = nil,
        onAnyVideoFrame: (() -> Void)? = nil,
        onFrame: @escaping (FaceFrame) -> Void
    ) {
        self.onFrame = onFrame
        self.onAnyVideoFrame = onAnyVideoFrame
        self.onStarted = onStarted
        didLogFace = false
        didLogAnyVideoFrame = false

        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                print("CAMERA: permission denied")
                return
            }
            self.queue.async {
                self.configureIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                    print("CAMERA: ON")
                    self.onStarted?()
                }
            }
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.onFrame = nil
            self.onAnyVideoFrame = nil
            self.onStarted = nil
            self.didLogFace = false
            self.didLogAnyVideoFrame = false
            print("CAMERA: OFF")
            completion?()
        }
    }

    private func configureIfNeeded() {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("CAMERA: integrated camera unavailable")
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if !didLogAnyVideoFrame {
            didLogAnyVideoFrame = true
            onAnyVideoFrame?()
        }
        guard let frame = analyzer.analyze(sampleBuffer) else { return }
        if !didLogFace {
            didLogFace = true
            print("Face detected.")
            print("Checking liveness...")
        }
        onFrame?(frame)
    }
}

final class SessionMonitor: @unchecked Sendable {
    private let center = DistributedNotificationCenter.default()
    private var lockObserverRegistered = false
    private var unlockObserverRegistered = false
    private var fallbackTimer: Timer?
    private let onChange: (SessionState) -> Void
    private let onDiagnostic: ((String) -> Void)?
    private var lastState: SessionState?

    init(onDiagnostic: ((String) -> Void)? = nil, onChange: @escaping (SessionState) -> Void) {
        self.onDiagnostic = onDiagnostic
        self.onChange = onChange
    }

    deinit {
        center.removeObserver(self)
        fallbackTimer?.invalidate()
    }

    func start() {
        center.addObserver(
            self,
            selector: #selector(screenLocked(_:)),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        lockObserverRegistered = true
        center.addObserver(
            self,
            selector: #selector(screenUnlocked(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        unlockObserverRegistered = true

        diagnostic("Lock observer registered: \(Format.yesNo(lockObserverRegistered))")
        diagnostic("Unlock observer registered: \(Format.yesNo(unlockObserverRegistered))")

        let initial = currentState()
        lastState = initial
        onChange(initial)
        startFallbackTimer()
    }

    var lockObserverRetained: Bool { lockObserverRegistered }
    var unlockObserverRetained: Bool { unlockObserverRegistered }

    func currentState() -> SessionState {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = dictionary["CGSSessionScreenIsLocked"] as? Bool else {
            return .unlocked
        }
        return locked ? .locked : .unlocked
    }

    @objc private func screenLocked(_ notification: Notification) {
        diagnostic("Distributed notification received: \(notification.name.rawValue)")
        emit(.locked)
    }

    @objc private func screenUnlocked(_ notification: Notification) {
        diagnostic("Distributed notification received: \(notification.name.rawValue)")
        emit(.unlocked)
    }

    private func startFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollSessionState()
        }
        fallbackTimer?.tolerance = 0.25
        if let fallbackTimer {
            RunLoop.main.add(fallbackTimer, forMode: .common)
        }
        diagnostic("CGSession fallback polling: ENABLED")
    }

    private func pollSessionState() {
        let state = currentState()
        guard state != lastState else { return }
        diagnostic("CGSession state changed: \(state.rawValue)")
        emit(state)
    }

    private func emit(_ state: SessionState) {
        guard state != lastState else { return }
        lastState = state
        onChange(state)
    }

    private func diagnostic(_ message: String) {
        onDiagnostic?(message)
    }
}

final class UnlockTestRunner: @unchecked Sendable {
    private let camera = CameraManager()
    private let liveness = LivenessDetector()
    private let template: FaceTemplate?
    private let sessionMonitor = SessionMonitor { _ in }
    private var finished = false

    init(template: FaceTemplate?) {
        self.template = template
    }

    func run(dryRun: Bool, timeout: Double = 20) {
        guard dryRun else {
            print("unlock-test currently supports only --dry-run.")
            exit(2)
        }
        guard template != nil else {
            print("No enrollment template found. Run: swift run faceunlock enroll")
            exit(2)
        }

        let state = sessionMonitor.currentState()
        print("SESSION: \(state.rawValue)")
        camera.start { [weak self] frame in
            self?.process(frame)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !self.finished else { return }
            self.finished = true
            print("UNLOCK TEST: TIMEOUT")
            self.camera.stop()
            exit(3)
        }
        RunLoop.main.run()
    }

    private func process(_ frame: FaceFrame) {
        guard !finished else { return }
        let live = liveness.add(frame)
        guard live else { return }

        print("Liveness: PASS")
        guard let template else { return }
        let similarity = FaceAnalyzer.similarity(template.vector, frame.vector)
        let matched = similarity >= 0.82
        print(String(format: "Face similarity: %.2f", similarity))
        print(matched ? "IDENTITY: MATCH" : "IDENTITY: NO MATCH")

        if matched {
            print("Keychain password available: \(Format.yesNo(LoginPasswordKeychain.passwordAvailable()))")
            print("")
            print("DRY RUN:")
            print("Would inject password into Lock Screen.")
            print("Would press Return.")
            print("")
            print("No keyboard events were sent.")
        }

        finished = true
        camera.stop()
        exit(matched ? 0 : 4)
    }
}

final class SessionTestRunner {
    private var monitor: SessionMonitor?

    func run() {
        print("SESSION TEST: START")
        print("No camera, no unlock, no keyboard injection.")
        monitor = SessionMonitor(
            onDiagnostic: { message in
                print(message)
            },
            onChange: { state in
                print("SESSION: \(state.rawValue)")
            }
        )
        monitor?.start()
        RunLoop.main.run()
    }
}

final class EnrollmentRunner: @unchecked Sendable {
    private let camera = CameraManager()
    private let store = TemplateStore()
    private let liveness = LivenessDetector()
    private let lock = NSLock()
    private let targetSamples: Int
    private let timeoutSeconds: Double
    private var vectors: [[Double]] = []
    private var lastCapturedFrame: FaceFrame?
    private var timeoutStarted = false
    private var livenessLogged = false
    private var finished = false

    init(targetSamples: Int, timeoutSeconds: Double = 30) {
        self.targetSamples = max(1, targetSamples)
        self.timeoutSeconds = timeoutSeconds
    }

    func run() {
        print("Enrollment started.")
        print("Look at the camera and move your head slightly.")
        camera.start(
            onAnyVideoFrame: { [weak self] in
                self?.startTimeoutIfNeeded()
            },
            onFrame: { [weak self] frame in
                self?.process(frame)
            }
        )

        RunLoop.main.run()
    }

    private func startTimeoutIfNeeded() {
        lock.lock()
        guard !timeoutStarted else {
            lock.unlock()
            return
        }
        timeoutStarted = true
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldTimeout = !self.finished && self.vectors.count < self.targetSamples
            let count = self.vectors.count
            self.lock.unlock()

            if shouldTimeout {
                self.finish(success: false, message: "Enrollment failed: captured \(count)/\(self.targetSamples) valid samples before timeout.")
            }
        }
    }

    private func process(_ frame: FaceFrame) {
        guard liveness.add(frame) else { return }

        lock.lock()
        if finished {
            lock.unlock()
            return
        }

        if !livenessLogged {
            livenessLogged = true
            print("Liveness: PASS")
        }

        guard isDistinctEnough(frame, comparedTo: lastCapturedFrame) else {
            lock.unlock()
            return
        }

        vectors.append(frame.vector)
        lastCapturedFrame = frame
        let count = vectors.count
        let complete = count >= targetSamples
        lock.unlock()

        print("Sample \(count)/\(targetSamples) captured.")

        if complete {
            finish(success: true, message: "Enrollment complete.")
        }
    }

    private func isDistinctEnough(_ frame: FaceFrame, comparedTo previous: FaceFrame?) -> Bool {
        guard let previous else { return true }
        let similarity = FaceAnalyzer.similarity(previous.vector, frame.vector)
        let centerDelta = hypot(frame.center.x - previous.center.x, frame.center.y - previous.center.y)
        let sizeDelta = abs(frame.size.width - previous.size.width) + abs(frame.size.height - previous.size.height)
        return similarity < 0.992 || centerDelta > 0.012 || sizeDelta > 0.018
    }

    private func finish(success: Bool, message: String) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let capturedVectors = vectors
        lock.unlock()

        print(message)

        guard success else {
            camera.stop {
                exit(2)
            }
            return
        }

        let template = FaceTemplate(createdAt: Date(), samples: capturedVectors.count, vector: FaceAnalyzer.average(capturedVectors))
        do {
            try store.save(template)
            print("Enrollment saved: \(store.url.path)")
            print("Samples: \(capturedVectors.count)")
            camera.stop {
                exit(0)
            }
        } catch {
            print("Enrollment failed: \(error)")
            camera.stop {
                exit(1)
            }
        }
    }
}

func printUsage() {
    print("""
    Usage:
      faceunlock enroll [sample-count]
      faceunlock monitor
      faceunlock monitor --enable-unlock
      faceunlock unlock-test --dry-run
      faceunlock session-test
      faceunlock password <enroll|status|delete>
      faceunlock permissions

    Notes:
      - Unlock requires explicit --enable-unlock and a Keychain-stored password.
      - Camera starts only during enrollment or after SESSION LOCKED.
      - Template path: ~/.faceunlock/template.json
    """)
}

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? "monitor"
let store = TemplateStore()

if command == "--app" || Bundle.main.bundlePath.hasSuffix(".app") {
    Task { @MainActor in
        runFaceUnlockApp()
    }
    RunLoop.main.run()
}

switch command {
case "enroll":
    let sampleCount = arguments.dropFirst().first.flatMap(Int.init) ?? 8
    let runner = EnrollmentRunner(targetSamples: sampleCount)
    runner.run()
case "monitor":
    if (try? store.load()) == nil {
        print("No enrollment template found. Run: swift run faceunlock enroll")
    }
    let enableUnlock = arguments.dropFirst().contains("--enable-unlock")
    print("SESSION: UNLOCKED")
    print("CAMERA: OFF")
    let engine = FaceUnlockEngine(
        printEvents: true,
        enableUnlockProvider: { enableUnlock },
        thresholdProvider: { 0.82 },
        maxAttemptsProvider: { 3 }
    )
    engine.start()
    RunLoop.main.run()
case "unlock-test":
    let dryRun = arguments.dropFirst().contains("--dry-run")
    UnlockTestRunner(template: try? store.load()).run(dryRun: dryRun)
case "session-test":
    SessionTestRunner().run()
case "password":
    PasswordCommand.run(arguments.dropFirst())
case "permissions":
    PermissionsCommand.run()
default:
    printUsage()
}
