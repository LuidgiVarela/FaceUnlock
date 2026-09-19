import AppKit
import Foundation

struct FaceUnlockEngineSnapshot {
    var appRunning: Bool = true
    var sessionMonitorActive: Bool = false
    var currentSession: SessionState = .unlocked
    var unlockEngineEnabled: Bool = false
    var cameraOn: Bool = false
    var lastLockEvent: String = "Never"
    var lastFaceResult: String = "None"
    var lastUnlockAttempt: String = "None"
    var lastError: String = "None"
}

final class FaceUnlockLog: @unchecked Sendable {
    static let shared = FaceUnlockLog()

    private let queue = DispatchQueue(label: "faceunlock.log")
    private let url: URL

    private init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".faceunlock", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("faceunlock.log")
    }

    var path: String { url.path }

    func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let url = self.url
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    return
                }
            } else {
                try? data.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
        NSLog("FaceUnlock: \(message)")
    }
}

final class FaceUnlockEngine: @unchecked Sendable {
    private let camera = CameraManager()
    private let liveness = LivenessDetector()
    private let keyboardInjector = LockScreenKeyboardInjector()
    private let log = FaceUnlockLog.shared
    private let printEvents: Bool
    private let enableUnlockProvider: () -> Bool
    private let thresholdProvider: () -> Double
    private let maxAttemptsProvider: () -> Int
    private var monitor: SessionMonitor?
    private var template: FaceTemplate?
    private var matched = false
    private var unlockFeedbackDeadline: Date?
    private var faceDetectedLogged = false
    private var currentState: SessionState = .unlocked
    private var attempts = 0
    private var snapshotValue = FaceUnlockEngineSnapshot()
    var onSnapshotChanged: ((FaceUnlockEngineSnapshot) -> Void)?
    var onUnlockFeedbackRequested: (() -> Void)?

    init(
        printEvents: Bool,
        enableUnlockProvider: @escaping () -> Bool,
        thresholdProvider: @escaping () -> Double = { 0.82 },
        maxAttemptsProvider: @escaping () -> Int = { 3 }
    ) {
        self.printEvents = printEvents
        self.enableUnlockProvider = enableUnlockProvider
        self.thresholdProvider = thresholdProvider
        self.maxAttemptsProvider = maxAttemptsProvider
    }

    func start() {
        log.write("APP STARTED")
        template = try? TemplateStore().load()
        monitor = SessionMonitor(
            onDiagnostic: { [weak self] message in
                self?.log.write(message)
            },
            onChange: { [weak self] state in
                self?.stateChanged(state)
            }
        )
        snapshotValue.sessionMonitorActive = true
        log.write("SESSION MONITOR STARTED")
        monitor?.start()
        publish()
    }

    func stop() {
        unlockFeedbackDeadline = nil
        camera.stop()
        snapshotValue.cameraOn = false
        log.write("CAMERA STOP")
        publish()
    }

    func snapshot() -> FaceUnlockEngineSnapshot {
        snapshotValue.unlockEngineEnabled = enableUnlockProvider()
        return snapshotValue
    }

    func simulateEngineCheck() -> [String] {
        let faceEnrollment = FileManager.default.fileExists(atPath: TemplateStore().url.path)
        return [
            "Session Monitor: \(snapshotValue.sessionMonitorActive ? "ACTIVE" : "INACTIVE")",
            "Current Session: \(snapshotValue.currentSession.rawValue)",
            "Unlock Engine: \(enableUnlockProvider() ? "ENABLED" : "DISABLED")",
            "Face Enrollment: \(faceEnrollment ? "PASS" : "FAIL")",
            "Keychain Password: \(LoginPasswordKeychain.exists() ? "PASS" : "FAIL")",
            "Accessibility: \(AXIsProcessTrusted() ? "PASS" : "FAIL")",
            "CGEvent available: \(LockScreenKeyboardInjector.eventSourceAvailable() ? "YES" : "NO")",
            "Camera: \(snapshotValue.cameraOn ? "ON" : "OFF")"
        ]
    }

    private func stateChanged(_ state: SessionState) {
        currentState = state
        snapshotValue.currentSession = state
        snapshotValue.unlockEngineEnabled = enableUnlockProvider()

        printLine("")
        printLine("SESSION: \(state.rawValue)")

        switch state {
        case .unlocked:
            let shouldShowUnlockFeedback = unlockFeedbackDeadline.map { Date() <= $0 } ?? false
            unlockFeedbackDeadline = nil
            attempts = 0
            matched = false
            faceDetectedLogged = false
            liveness.reset()
            snapshotValue.cameraOn = false
            log.write("SESSION UNLOCKED")
            camera.stop()
            log.write("CAMERA STOP")
            if shouldShowUnlockFeedback {
                log.write("UNLOCK ANIMATION REQUESTED AFTER SESSION UNLOCKED")
                onUnlockFeedbackRequested?()
            }
        case .locked:
            unlockFeedbackDeadline = nil
            snapshotValue.lastLockEvent = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            log.write("SESSION LOCKED")
            printLine("Session lock detected.")
            guard enableUnlockProvider() else {
                printLine("Unlock mode: DISABLED")
                snapshotValue.lastError = "Unlock disabled"
                publish()
                return
            }
            printLine("Unlock mode: ENABLED")
            template = try? TemplateStore().load()
            guard template != nil else {
                snapshotValue.lastError = "No enrollment template"
                log.write("ERROR: No enrollment template")
                publish()
                return
            }
            guard LoginPasswordKeychain.exists() else {
                snapshotValue.lastError = "No Keychain password"
                log.write("ERROR: No Keychain password")
                publish()
                return
            }
            snapshotValue.cameraOn = true
            log.write("CAMERA START")
            camera.start { [weak self] frame in
                self?.process(frame)
            }
        }
        publish()
    }

    private func process(_ frame: FaceFrame) {
        guard currentState == .locked, !matched else { return }
        if !faceDetectedLogged {
            faceDetectedLogged = true
            snapshotValue.lastFaceResult = "Face detected"
            log.write("FACE DETECTED")
        }

        let live = liveness.add(frame)
        guard live else { return }
        printLine("Liveness: PASS")
        log.write("LIVENESS PASS")

        guard let template else {
            matched = true
            snapshotValue.lastFaceResult = "No enrollment template"
            snapshotValue.lastError = "No enrollment template"
            log.write("ERROR: No enrollment template")
            stopCameraAfterAttempt()
            return
        }

        let similarity = FaceAnalyzer.similarity(template.vector, frame.vector)
        printLine(String(format: "Face similarity: %.2f", similarity))
        if similarity >= thresholdProvider() {
            printLine("IDENTITY: MATCH")
            snapshotValue.lastFaceResult = String(format: "MATCH %.2f", similarity)
            log.write("IDENTITY MATCH")
            attemptUnlock()
            matched = true
            stopCameraAfterAttempt()
        } else {
            printLine("IDENTITY: NO MATCH")
            snapshotValue.lastFaceResult = String(format: "NO MATCH %.2f", similarity)
            log.write("IDENTITY NO MATCH")
            attempts += 1
            if attempts >= maxAttemptsProvider() {
                matched = true
                stopCameraAfterAttempt()
            } else {
                liveness.reset()
            }
        }
        publish()
    }

    private func attemptUnlock() {
        unlockFeedbackDeadline = nil
        guard currentState == .locked else {
            snapshotValue.lastError = "Session unlocked before injection"
            log.write("ERROR: Session unlocked before injection")
            return
        }
        guard attempts < maxAttemptsProvider() else {
            snapshotValue.lastError = "Maximum attempts reached"
            log.write("ERROR: Maximum attempts reached")
            return
        }
        attempts += 1

        do {
            var password = try LoginPasswordKeychain.loadPassword()
            defer { password.removeAll(keepingCapacity: false) }
            printLine("Keychain password available: YES")
            log.write("KEYCHAIN PASSWORD AVAILABLE")
            let accessibility = AXIsProcessTrusted()
            log.write("ACCESSIBILITY \(accessibility ? "PASS" : "FAIL")")
            log.write("CGEvent available: \(LockScreenKeyboardInjector.eventSourceAvailable() ? "YES" : "NO")")
            log.write("CGEvent injection started")
            unlockFeedbackDeadline = Date().addingTimeInterval(4)
            log.write("UNLOCK ANIMATION QUEUED")
            let sent = keyboardInjector.injectPasswordAndReturn(password, sessionState: currentState)
            if sent {
                printLine("Keyboard injection: SENT")
                snapshotValue.lastUnlockAttempt = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                log.write("Return sent")
            } else {
                unlockFeedbackDeadline = nil
                snapshotValue.lastError = "Keyboard injection failed"
                log.write("ERROR: Keyboard injection failed")
            }
        } catch {
            unlockFeedbackDeadline = nil
            printLine("Keychain password available: NO")
            printLine("Unlock skipped: \(error.localizedDescription)")
            snapshotValue.lastError = "Keychain unavailable"
            log.write("ERROR: Keychain unavailable")
        }
    }

    private func stopCameraAfterAttempt() {
        snapshotValue.cameraOn = false
        camera.stop()
        log.write("CAMERA STOP")
    }

    private func publish() {
        onSnapshotChanged?(snapshot())
    }

    private func printLine(_ text: String) {
        if printEvents {
            print(text)
        }
    }
}
