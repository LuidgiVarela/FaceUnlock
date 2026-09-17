import AppKit
import QuartzCore

@MainActor
final class UnlockAnimationController: NSObject {
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func show() {
        dismissTimer?.invalidate()
        panel?.orderOut(nil)
        panel?.close()

        let size = NSSize(width: 164, height: 164)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.canBecomeVisibleWithoutLogin = true
        panel.sharingType = .none

        let animationView = FaceUnlockSuccessView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = animationView
        panel.setFrame(Self.frame(for: size), display: true)
        panel.alphaValue = 1
        self.panel = panel

        panel.orderFrontRegardless()
        FaceUnlockLog.shared.write("UNLOCK ANIMATION START")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animationView.start(reduceMotion: reduceMotion)

        let visibleDuration = reduceMotion ? 0.85 : 1.55
        let timer = Timer(
            timeInterval: visibleDuration,
            target: self,
            selector: #selector(dismissTimerFired(_:)),
            userInfo: panel,
            repeats: false
        )
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc
    private func dismissTimerFired(_ timer: Timer) {
        guard let panel = timer.userInfo as? NSPanel else { return }
        dismissTimer = nil
        dismiss(panel)
    }

    private func dismiss(_ panel: NSPanel) {
        FaceUnlockLog.shared.write("UNLOCK ANIMATION DISMISS")
        panel.orderOut(nil)
        panel.close()
        if self.panel === panel {
            self.panel = nil
        }
    }

    private static func frame(for size: NSSize) -> NSRect {
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height - 72
        )
        return NSRect(origin: origin, size: size)
    }
}

private final class FaceUnlockSuccessView: NSView {
    private let backdropLayer = CALayer()
    private let glowLayer = CAShapeLayer()
    private let faceLayer = CAShapeLayer()
    private let eyesLayer = CAShapeLayer()
    private let smileLayer = CAShapeLayer()
    private let scanLayer = CALayer()
    private let checkLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        configureLayers()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let contentRect = bounds.insetBy(dx: 10, dy: 10)
        backdropLayer.frame = contentRect
        backdropLayer.cornerRadius = 36

        let iconRect = NSRect(x: 38, y: 38, width: 88, height: 88)
        glowLayer.path = CGPath(ellipseIn: iconRect.insetBy(dx: -8, dy: -8), transform: nil)
        faceLayer.path = Self.faceCornersPath(in: iconRect)
        eyesLayer.path = Self.eyesPath(in: iconRect)
        smileLayer.path = Self.smilePath(in: iconRect)
        checkLayer.path = Self.checkPath(in: iconRect)
        scanLayer.frame = NSRect(x: iconRect.minX + 8, y: iconRect.minY + 20, width: iconRect.width - 16, height: 2)
    }

    func start(reduceMotion: Bool) {
        layoutSubtreeIfNeeded()
        resetLayers()
        animateViewOpacity(from: 0, to: 1, duration: reduceMotion ? 0.08 : 0.18, timing: .easeOut)

        if reduceMotion {
            showReducedMotionConfirmation()
            return
        }

        let now = CACurrentMediaTime()
        animateEntrance(at: now)
        animateScan(at: now + 0.16)
        animateConfirmation(at: now + 0.64)
    }

    private func configureLayers() {
        guard let layer else { return }

        backdropLayer.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        backdropLayer.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        backdropLayer.borderWidth = 1
        backdropLayer.shadowColor = NSColor.black.cgColor
        backdropLayer.shadowOpacity = 0.42
        backdropLayer.shadowRadius = 24
        backdropLayer.shadowOffset = CGSize(width: 0, height: -5)
        layer.addSublayer(backdropLayer)

        glowLayer.fillColor = NSColor.clear.cgColor
        glowLayer.strokeColor = NSColor.systemGreen.withAlphaComponent(0.4).cgColor
        glowLayer.lineWidth = 3
        glowLayer.opacity = 0
        backdropLayer.addSublayer(glowLayer)

        [faceLayer, eyesLayer, smileLayer, checkLayer].forEach {
            $0.fillColor = NSColor.clear.cgColor
            $0.lineCap = .round
            $0.lineJoin = .round
            backdropLayer.addSublayer($0)
        }

        faceLayer.strokeColor = NSColor.systemCyan.cgColor
        faceLayer.lineWidth = 5
        eyesLayer.strokeColor = NSColor.systemCyan.cgColor
        eyesLayer.lineWidth = 4
        smileLayer.strokeColor = NSColor.systemCyan.cgColor
        smileLayer.lineWidth = 4

        scanLayer.backgroundColor = NSColor.systemCyan.cgColor
        scanLayer.cornerRadius = 1
        scanLayer.shadowColor = NSColor.systemCyan.cgColor
        scanLayer.shadowOpacity = 0.9
        scanLayer.shadowRadius = 7
        backdropLayer.addSublayer(scanLayer)

        checkLayer.strokeColor = NSColor.systemGreen.cgColor
        checkLayer.lineWidth = 7
        checkLayer.opacity = 0
    }

    private func resetLayers() {
        [backdropLayer, glowLayer, faceLayer, eyesLayer, smileLayer, scanLayer, checkLayer].forEach {
            $0.removeAllAnimations()
        }
        backdropLayer.transform = CATransform3DIdentity
        faceLayer.strokeEnd = 1
        faceLayer.opacity = 1
        eyesLayer.opacity = 1
        smileLayer.opacity = 1
        scanLayer.opacity = 0
        glowLayer.opacity = 0
        checkLayer.opacity = 0
        checkLayer.strokeEnd = 0
    }

    private func animateViewOpacity(
        from: Float,
        to: Float,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName
    ) {
        guard let layer else { return }
        layer.opacity = to
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(animation, forKey: "viewOpacity")
    }

    private func animateEntrance(at beginTime: CFTimeInterval) {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.78, 1.04, 1.0]
        scale.keyTimes = [0, 0.72, 1]
        scale.duration = 0.4
        scale.beginTime = beginTime
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        backdropLayer.add(scale, forKey: "entrance")

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.38
        draw.beginTime = beginTime + 0.04
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        faceLayer.add(draw, forKey: "drawFace")
    }

    private func animateScan(at beginTime: CFTimeInterval) {
        scanLayer.opacity = 0

        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = 0
        move.toValue = 47
        move.duration = 0.42
        move.beginTime = beginTime
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.95, 0.95, 0]
        opacity.keyTimes = [0, 0.15, 0.82, 1]
        opacity.duration = 0.42
        opacity.beginTime = beginTime

        scanLayer.add(move, forKey: "scanMove")
        scanLayer.add(opacity, forKey: "scanOpacity")
    }

    private func animateConfirmation(at beginTime: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.16
        fade.beginTime = beginTime
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        [faceLayer, eyesLayer, smileLayer].forEach { $0.add(fade, forKey: "faceFade") }

        let checkOpacity = CABasicAnimation(keyPath: "opacity")
        checkOpacity.fromValue = 0
        checkOpacity.toValue = 1
        checkOpacity.duration = 0.08
        checkOpacity.beginTime = beginTime + 0.08
        checkOpacity.fillMode = .forwards
        checkOpacity.isRemovedOnCompletion = false
        checkLayer.add(checkOpacity, forKey: "checkOpacity")

        let checkDraw = CABasicAnimation(keyPath: "strokeEnd")
        checkDraw.fromValue = 0
        checkDraw.toValue = 1
        checkDraw.duration = 0.34
        checkDraw.beginTime = beginTime + 0.08
        checkDraw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        checkDraw.fillMode = .forwards
        checkDraw.isRemovedOnCompletion = false
        checkLayer.add(checkDraw, forKey: "checkDraw")

        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [0.82, 1.13, 1.0]
        pulse.keyTimes = [0, 0.62, 1]
        pulse.duration = 0.5
        pulse.beginTime = beginTime + 0.04
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glowLayer.opacity = 1
        glowLayer.add(pulse, forKey: "successPulse")

        let glowOpacity = CAKeyframeAnimation(keyPath: "opacity")
        glowOpacity.values = [0, 0.8, 0.3]
        glowOpacity.keyTimes = [0, 0.35, 1]
        glowOpacity.duration = 0.62
        glowOpacity.beginTime = beginTime
        glowOpacity.fillMode = .forwards
        glowOpacity.isRemovedOnCompletion = false
        glowLayer.add(glowOpacity, forKey: "glowOpacity")
    }

    private func showReducedMotionConfirmation() {
        faceLayer.opacity = 0
        eyesLayer.opacity = 0
        smileLayer.opacity = 0
        scanLayer.opacity = 0
        glowLayer.opacity = 0.45
        checkLayer.opacity = 1
        checkLayer.strokeEnd = 1
    }

    private static func faceCornersPath(in rect: NSRect) -> CGPath {
        let path = CGMutablePath()
        let segment: CGFloat = 22
        let radius: CGFloat = 10

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + segment))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + segment, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - segment, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + segment))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - segment))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - segment, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + segment, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - segment))
        return path
    }

    private static func eyesPath(in rect: NSRect) -> CGPath {
        let path = CGMutablePath()
        let y = rect.midY + 10
        path.move(to: CGPoint(x: rect.midX - 23, y: y))
        path.addLine(to: CGPoint(x: rect.midX - 17, y: y))
        path.move(to: CGPoint(x: rect.midX + 17, y: y))
        path.addLine(to: CGPoint(x: rect.midX + 23, y: y))
        return path
    }

    private static func smilePath(in rect: NSRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX - 19, y: rect.midY - 11))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + 19, y: rect.midY - 11),
            control: CGPoint(x: rect.midX, y: rect.midY - 27)
        )
        return path
    }

    private static func checkPath(in rect: NSRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX - 25, y: rect.midY - 1))
        path.addLine(to: CGPoint(x: rect.midX - 7, y: rect.midY - 20))
        path.addLine(to: CGPoint(x: rect.midX + 29, y: rect.midY + 21))
        return path
    }
}
