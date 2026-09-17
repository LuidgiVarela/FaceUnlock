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

        let visibleDuration = reduceMotion ? 0.85 : 1.25
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
    private var transitionTimer: Timer?

    private let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: 52,
        weight: .medium,
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
        guard let closedLock = symbol(named: "lock.fill"),
              let openLock = symbol(named: "lock.open.fill") else {
            FaceUnlockLog.shared.write("ERROR: Unlock animation symbols unavailable")
            return
        }

        transitionTimer?.invalidate()
        imageView.image = closedLock
        imageView.alphaValue = 1

        if reduceMotion {
            imageView.image = openLock
            FaceUnlockLog.shared.write("UNLOCK ANIMATION OPEN")
            return
        }

        animateEntrance()

        let timer = Timer(
            timeInterval: 0.22,
            target: self,
            selector: #selector(openLockTimerFired(_:)),
            userInfo: openLock,
            repeats: false
        )
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc
    private func openLockTimerFired(_ timer: Timer) {
        transitionTimer = nil
        guard let openLock = timer.userInfo as? NSImage else { return }

        if #available(macOS 15.0, *) {
            imageView.setSymbolImage(
                openLock,
                contentTransition: .replace.magic(fallback: .downUp)
            )
        } else {
            imageView.setSymbolImage(openLock, contentTransition: .replace.downUp)
        }
        FaceUnlockLog.shared.write("UNLOCK ANIMATION OPEN")
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
}
