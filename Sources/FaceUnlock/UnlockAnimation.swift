import AppKit
import QuartzCore
import Symbols

@MainActor
final class UnlockAnimationController: NSObject {
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func show() {
        dismissTimer?.invalidate()
        panel?.orderOut(nil)
        panel?.close()

        let size = NSSize(width: 96, height: 96)
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

        let animationView = UnlockIndicatorView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = animationView
        panel.setFrame(Self.frame(for: size), display: true)
        panel.alphaValue = 1
        self.panel = panel

        panel.orderFrontRegardless()
        FaceUnlockLog.shared.write("UNLOCK ANIMATION START")

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animationView.start(reduceMotion: reduceMotion)

        let visibleDuration = reduceMotion ? 1.2 : 2.2
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
            y: screenFrame.maxY - size.height - 76
        )
        return NSRect(origin: origin, size: size)
    }
}

private final class UnlockIndicatorView: NSView {
    private let imageView = NSImageView()
    private var successTimer: Timer?
    private var bounceTimer: Timer?

    private let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: 56,
        weight: .regular,
        scale: .large
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer = CALayer()

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .white
        imageView.wantsLayer = true
        imageView.layer?.shadowColor = NSColor.black.cgColor
        imageView.layer?.shadowOpacity = 0.62
        imageView.layer?.shadowRadius = 4
        imageView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 72),
            imageView.heightAnchor.constraint(equalToConstant: 72)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func start(reduceMotion: Bool) {
        guard let faceID = symbol(named: "faceid"),
              let success = symbol(named: "checkmark.circle") else {
            FaceUnlockLog.shared.write("ERROR: Unlock animation symbols unavailable")
            return
        }

        successTimer?.invalidate()
        bounceTimer?.invalidate()
        imageView.removeAllSymbolEffects(animated: false)
        imageView.contentTintColor = .systemBlue
        imageView.image = faceID
        imageView.alphaValue = 1

        if reduceMotion {
            imageView.image = success
            FaceUnlockLog.shared.write("UNLOCK ANIMATION SUCCESS")
            return
        }

        animateEntrance()
        animateFaceIDScan()

        let timer = Timer(
            timeInterval: 0.78,
            target: self,
            selector: #selector(successTimerFired(_:)),
            userInfo: success,
            repeats: false
        )
        successTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        FaceUnlockLog.shared.write("UNLOCK ANIMATION FACE ID")
    }

    @objc
    private func successTimerFired(_ timer: Timer) {
        successTimer = nil
        guard let success = timer.userInfo as? NSImage else { return }

        imageView.removeAllSymbolEffects(animated: false)

        if #available(macOS 15.0, *) {
            imageView.setSymbolImage(
                success,
                contentTransition: .replace.magic(fallback: .downUp)
            )
        } else {
            imageView.setSymbolImage(success, contentTransition: .replace.downUp)
        }

        let timer = Timer(
            timeInterval: 0.18,
            target: self,
            selector: #selector(bounceTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
        bounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        FaceUnlockLog.shared.write("UNLOCK ANIMATION SUCCESS")
    }

    @objc
    private func bounceTimerFired(_ timer: Timer) {
        bounceTimer = nil
        imageView.addSymbolEffect(
            .bounce.up.wholeSymbol,
            options: .speed(1.15),
            animated: true
        )
    }

    private func symbol(named name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
    }

    private func animateEntrance() {
        guard let layer = imageView.layer else { return }

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = 0.16
        opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(opacity, forKey: "unlockEntranceOpacity")

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.9, 1.025, 1.0]
        scale.keyTimes = [0, 0.72, 1]
        scale.duration = 0.28
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "unlockEntranceScale")
    }

    private func animateFaceIDScan() {
        if #available(macOS 26.0, *) {
            imageView.addSymbolEffect(
                .drawOn.individually,
                options: .speed(1.35),
                animated: true
            )
        } else {
            imageView.addSymbolEffect(
                .pulse.byLayer,
                options: .speed(1.2),
                animated: true
            )
        }
    }
}
