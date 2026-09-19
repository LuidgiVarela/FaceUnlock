import AppKit
import AVFoundation
import Foundation
import ServiceManagement

enum AppPreferences {
    static let enableFaceUnlockKey = "EnableFaceUnlock"
    static let launchAtLoginKey = "LaunchAtLogin"
    static let recognitionThresholdKey = "RecognitionThreshold"
    static let maxAttemptsKey = "MaxAttemptsPerLock"
    static let onboardingFinishedKey = "OnboardingFinished"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enableFaceUnlockKey: true,
            launchAtLoginKey: true,
            recognitionThresholdKey: 0.82,
            maxAttemptsKey: 3,
            onboardingFinishedKey: false
        ])
    }

    static var enableFaceUnlock: Bool {
        get { UserDefaults.standard.bool(forKey: enableFaceUnlockKey) }
        set { UserDefaults.standard.set(newValue, forKey: enableFaceUnlockKey) }
    }

    static var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: launchAtLoginKey) }
        set { UserDefaults.standard.set(newValue, forKey: launchAtLoginKey) }
    }

    static var recognitionThreshold: Double {
        get { UserDefaults.standard.double(forKey: recognitionThresholdKey) }
        set { UserDefaults.standard.set(newValue, forKey: recognitionThresholdKey) }
    }

    static var maxAttempts: Int {
        get { max(1, UserDefaults.standard.integer(forKey: maxAttemptsKey)) }
        set { UserDefaults.standard.set(max(1, min(newValue, 5)), forKey: maxAttemptsKey) }
    }
}

@MainActor
final class FaceUnlockApplication: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private let unlockAnimation = UnlockAnimationController()
    private let engine = FaceUnlockEngine(
        printEvents: false,
        enableUnlockProvider: { AppPreferences.enableFaceUnlock },
        thresholdProvider: { AppPreferences.recognitionThreshold },
        maxAttemptsProvider: { AppPreferences.maxAttempts }
    )
    private var settingsWindow: SettingsWindowController?
    private var transientWindow: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        if let icon = NSImage(named: "FaceUnlock") {
            NSApp.applicationIconImage = icon
        }
        menuBar.configure(delegate: self)
        engine.onSnapshotChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.menuBar.refresh()
                self?.settingsWindow?.refresh()
            }
        }
        engine.onUnlockFeedbackRequested = { [weak self] in
            FaceUnlockLog.shared.write("UNLOCK ANIMATION CALLBACK RECEIVED")
            self?.unlockAnimation.show()
        }
        engine.start()
        applyLaunchAtLoginPreference()

        if !UserDefaults.standard.bool(forKey: AppPreferences.onboardingFinishedKey) {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    func toggleFaceUnlock() {
        AppPreferences.enableFaceUnlock.toggle()
        menuBar.refresh()
    }

    func toggleLaunchAtLogin() {
        AppPreferences.launchAtLogin.toggle()
        applyLaunchAtLoginPreference()
        menuBar.refresh()
    }

    func testFaceRecognition() {
        let controller = AppFaceTestController { [weak self] in
            self?.unlockAnimation.show()
        }
        transientWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        let controller = SettingsWindowController(app: self, engine: engine)
        settingsWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showDiagnostics() {
        let controller = DiagnosticsWindowController(lines: engine.simulateEngineCheck())
        transientWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func previewUnlockAnimation() {
        unlockAnimation.show()
    }

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: FaceUnlockLog.shared.path))
    }

    func startEnrollment() {
        let controller = AppEnrollmentController()
        transientWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updatePassword() {
        let controller = PasswordWindowController { [weak self] in
            self?.menuBar.refresh()
            self?.settingsWindow?.refresh()
        }
        transientWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func deletePassword() {
        let controller = ConfirmationWindowController(
            title: "Delete Stored Password",
            subtitle: "FaceUnlock will not unlock the Mac until a password is saved again.",
            symbol: "trash",
            destructiveTitle: "Delete Password",
            onConfirm: { [weak self] in
                do {
                    try LoginPasswordKeychain.delete()
                } catch {
                    showError("Could not delete password", detail: error.localizedDescription)
                }
                self?.menuBar.refresh()
                self?.settingsWindow?.refresh()
            }
        )
        transientWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openCameraSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func showOnboarding() {
        let existingFace = FileManager.default.fileExists(atPath: TemplateStore().url.path)
        let existingPassword = LoginPasswordKeychain.passwordAvailable()
        let controller = OnboardingWindowController(
            existingFace: existingFace,
            existingPassword: existingPassword,
            onFinish: {
                UserDefaults.standard.set(true, forKey: AppPreferences.onboardingFinishedKey)
            },
            onSettings: { [weak self] in
                UserDefaults.standard.set(true, forKey: AppPreferences.onboardingFinishedKey)
                self?.showSettings()
            }
        )
        transientWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyLaunchAtLoginPreference() {
        do {
            if AppPreferences.launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("FaceUnlock login item update failed: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class MenuBarController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var delegate: FaceUnlockApplication?

    func configure(delegate: FaceUnlockApplication) {
        self.delegate = delegate
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "faceid", accessibilityDescription: "FaceUnlock")
        }
        refresh()
    }

    func refresh() {
        let menu = NSMenu()
        menu.addItem(withTitle: "FaceUnlock", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Status: \(AppPreferences.enableFaceUnlock ? "Active" : "Disabled")", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Face enrolled: \(Format.yesNo(FileManager.default.fileExists(atPath: TemplateStore().url.path)))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Password stored: \(Format.yesNo(LoginPasswordKeychain.passwordAvailable()))", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let enable = NSMenuItem(title: "Enable Face Unlock", action: #selector(AppMenuActions.toggleFaceUnlock), keyEquivalent: "")
        enable.state = AppPreferences.enableFaceUnlock ? .on : .off
        enable.target = AppMenuActions.shared
        menu.addItem(enable)

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(AppMenuActions.toggleLaunchAtLogin), keyEquivalent: "")
        launch.state = AppPreferences.launchAtLogin ? .on : .off
        launch.target = AppMenuActions.shared
        menu.addItem(launch)

        menu.addItem(.separator())
        menu.addItem(actionItem("Test Face Recognition", #selector(AppMenuActions.testFaceRecognition)))
        menu.addItem(actionItem("Re-enroll Face", #selector(AppMenuActions.startEnrollment)))
        menu.addItem(actionItem("Update Password", #selector(AppMenuActions.updatePassword)))
        menu.addItem(actionItem("Settings", #selector(AppMenuActions.showSettings)))
        menu.addItem(actionItem("Diagnostics", #selector(AppMenuActions.showDiagnostics)))
        menu.addItem(actionItem("Preview Unlock Animation", #selector(AppMenuActions.previewUnlockAnimation)))
        menu.addItem(actionItem("Open Log", #selector(AppMenuActions.openLog)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit FaceUnlock", #selector(AppMenuActions.quit)))

        AppMenuActions.shared.delegate = delegate
        item.menu = menu
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = AppMenuActions.shared
        return item
    }
}

@MainActor
final class AppMenuActions: NSObject {
    static let shared = AppMenuActions()
    weak var delegate: FaceUnlockApplication?

    @objc func toggleFaceUnlock() { delegate?.toggleFaceUnlock() }
    @objc func toggleLaunchAtLogin() { delegate?.toggleLaunchAtLogin() }
    @objc func testFaceRecognition() { delegate?.testFaceRecognition() }
    @objc func startEnrollment() { delegate?.startEnrollment() }
    @objc func updatePassword() { delegate?.updatePassword() }
    @objc func showSettings() { delegate?.showSettings() }
    @objc func showDiagnostics() { delegate?.showDiagnostics() }
    @objc func previewUnlockAnimation() { delegate?.previewUnlockAnimation() }
    @objc func openLog() { delegate?.openLog() }
    @objc func quit() { delegate?.quit() }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private weak var app: FaceUnlockApplication?
    private let engine: FaceUnlockEngine
    private let contentStack = NSStackView()
    private let scrollView = NSScrollView()

    init(app: FaceUnlockApplication, engine: FaceUnlockEngine) {
        self.app = app
        self.engine = engine
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FaceUnlock Settings"
        window.minSize = NSSize(width: 700, height: 620)
        super.init(window: window)
        configureContent()
        window.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func refresh() {
        configureContent()
    }

    private func configureContent() {
        SettingsActions.shared.delegate = app

        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let snapshot = engine.snapshot()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addArrangedSubview(headerView(snapshot: snapshot))
        contentStack.addArrangedSubview(overviewCards())

        let topColumns = horizontalStack(spacing: 16)
        topColumns.addArrangedSubview(section(
            title: "General",
            subtitle: "Core behavior",
            views: [
                toggleRow(
                    title: "Enable Face Unlock",
                    detail: "Starts recognition only when the Mac is locked.",
                    checked: AppPreferences.enableFaceUnlock,
                    action: #selector(SettingsActions.toggleFaceUnlock)
                ),
                separator(),
                toggleRow(
                    title: "Launch at Login",
                    detail: "Keeps FaceUnlock available after you sign in.",
                    checked: AppPreferences.launchAtLogin,
                    action: #selector(SettingsActions.toggleLaunchAtLogin)
                )
            ]
        ))
        topColumns.addArrangedSubview(section(
            title: "Face",
            subtitle: "Local enrollment",
            views: [
                valueRow(title: "Face enrolled", value: faceEnrolled() ? "Yes" : "No", status: faceEnrolled() ? .ok : .warning),
                primaryButton("Re-enroll Face", symbol: "faceid", action: #selector(SettingsActions.startEnrollment))
            ]
        ))
        contentStack.addArrangedSubview(topColumns)

        let middleColumns = horizontalStack(spacing: 16)
        middleColumns.addArrangedSubview(section(
            title: "Password",
            subtitle: "Stored only in macOS Keychain",
            views: [
                valueRow(title: "Mac password stored", value: LoginPasswordKeychain.passwordAvailable() ? "Yes" : "No", status: LoginPasswordKeychain.passwordAvailable() ? .ok : .warning),
                buttonRow([
                    primaryButton("Update Password", symbol: "key.fill", action: #selector(SettingsActions.updatePassword)),
                    secondaryButton("Delete", symbol: "trash", action: #selector(SettingsActions.deletePassword))
                ])
            ]
        ))
        middleColumns.addArrangedSubview(section(
            title: "Security",
            subtitle: "Conservative defaults",
            views: [
                valueRow(title: "Maximum attempts per lock", value: "\(AppPreferences.maxAttempts)", status: .neutral),
                valueRow(title: "Recognition threshold", value: String(format: "%.2f", AppPreferences.recognitionThreshold), status: .neutral)
            ]
        ))
        contentStack.addArrangedSubview(middleColumns)

        let runtimeColumns = horizontalStack(spacing: 16)
        runtimeColumns.addArrangedSubview(section(
            title: "Runtime",
            subtitle: "Live engine status",
            views: [
                valueRow(title: "App running", value: Format.yesNo(snapshot.appRunning), status: snapshot.appRunning ? .ok : .error),
                valueRow(title: "Session monitor", value: snapshot.sessionMonitorActive ? "Active" : "Inactive", status: snapshot.sessionMonitorActive ? .ok : .error),
                valueRow(title: "Current session", value: snapshot.currentSession.rawValue.capitalized, status: snapshot.currentSession == .unlocked ? .neutral : .warning),
                valueRow(title: "Unlock engine", value: snapshot.unlockEngineEnabled ? "Enabled" : "Disabled", status: snapshot.unlockEngineEnabled ? .ok : .warning),
                valueRow(title: "Camera", value: snapshot.cameraOn ? "On" : "Off", status: snapshot.cameraOn ? .warning : .neutral),
                valueRow(title: "Last lock event", value: snapshot.lastLockEvent, status: .neutral),
                valueRow(title: "Last face result", value: snapshot.lastFaceResult, status: .neutral),
                valueRow(title: "Last unlock attempt", value: snapshot.lastUnlockAttempt, status: .neutral),
                valueRow(title: "Last error", value: snapshot.lastError, status: snapshot.lastError == "None" ? .ok : .error)
            ]
        ))
        runtimeColumns.addArrangedSubview(section(
            title: "Permissions",
            subtitle: "Required by macOS",
            views: [
                permissionRow(
                    symbol: "camera.fill",
                    title: "Camera",
                    detail: "Used only while locked, testing, or enrolling.",
                    granted: cameraGranted(),
                    actionTitle: "Open Camera Settings",
                    action: #selector(SettingsActions.openCameraSettings)
                ),
                separator(),
                permissionRow(
                    symbol: "keyboard.fill",
                    title: "Accessibility",
                    detail: "Allows FaceUnlock to type into Lock Screen.",
                    granted: AXIsProcessTrusted(),
                    actionTitle: "Open Accessibility Settings",
                    action: #selector(SettingsActions.openAccessibilitySettings)
                )
            ]
        ))
        contentStack.addArrangedSubview(runtimeColumns)

        let visual = NSVisualEffectView()
        visual.material = .windowBackground
        visual.blendingMode = .behindWindow
        visual.state = .active

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = contentStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: visual.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        window?.contentView = visual
    }

    private func headerView(snapshot: FaceUnlockEngineSnapshot) -> NSView {
        let container = roundedContainer(material: .underWindowBackground, radius: 18)
        let row = horizontalStack(spacing: 14)
        row.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        let icon = NSImageView(image: NSImage(named: "FaceUnlock") ?? NSImage(systemSymbolName: "faceid", accessibilityDescription: "FaceUnlock") ?? NSImage())
        icon.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48)
        ])
        row.addArrangedSubview(icon)

        let titleStack = verticalStack(spacing: 3)
        titleStack.addArrangedSubview(text("FaceUnlock", size: 24, weight: .semibold))
        titleStack.addArrangedSubview(text("Unlock your Mac with your face", size: 13, color: .secondaryLabelColor))
        row.addArrangedSubview(titleStack)

        row.addArrangedSubview(spacer())
        row.addArrangedSubview(badge(snapshot.unlockEngineEnabled ? "Active" : "Paused", status: snapshot.unlockEngineEnabled ? .ok : .warning))
        container.addSubview(row)
        pin(row, to: container)
        return container
    }

    private func overviewCards() -> NSView {
        let row = horizontalStack(spacing: 12)
        row.distribution = .fillEqually
        row.addArrangedSubview(statusCard(symbol: "faceid", title: "Face", value: faceEnrolled() ? "Enrolled" : "Missing", status: faceEnrolled() ? .ok : .warning))
        row.addArrangedSubview(statusCard(symbol: "key.fill", title: "Password", value: LoginPasswordKeychain.passwordAvailable() ? "Stored" : "Missing", status: LoginPasswordKeychain.passwordAvailable() ? .ok : .warning))
        row.addArrangedSubview(statusCard(symbol: "camera.fill", title: "Camera", value: cameraGranted() ? "Granted" : "Missing", status: cameraGranted() ? .ok : .error))
        row.addArrangedSubview(statusCard(symbol: "hand.raised.fill", title: "Accessibility", value: AXIsProcessTrusted() ? "Granted" : "Missing", status: AXIsProcessTrusted() ? .ok : .error))
        return row
    }

    private func section(title: String, subtitle: String, views: [NSView]) -> NSView {
        let container = roundedContainer(material: .contentBackground, radius: 14)
        let stack = verticalStack(spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.addArrangedSubview(text(title, size: 15, weight: .semibold))
        stack.addArrangedSubview(text(subtitle, size: 12, color: .secondaryLabelColor))
        views.forEach { stack.addArrangedSubview($0) }
        container.addSubview(stack)
        pin(stack, to: container)
        container.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        return container
    }

    private func statusCard(symbol: String, title: String, value: String, status: UIStatus) -> NSView {
        let container = roundedPlainContainer(status.backgroundColor, radius: 14)
        let stack = verticalStack(spacing: 6)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        icon.contentTintColor = status.foregroundColor
        icon.setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(text(title, size: 12, color: .secondaryLabelColor))
        stack.addArrangedSubview(text(value, size: 15, weight: .semibold, color: status.foregroundColor))
        container.addSubview(stack)
        pin(stack, to: container)
        return container
    }

    private func toggleRow(title: String, detail: String, checked: Bool, action: Selector) -> NSView {
        let row = horizontalStack(spacing: 12)
        let labels = verticalStack(spacing: 3)
        labels.addArrangedSubview(text(title, size: 13, weight: .medium))
        labels.addArrangedSubview(text(detail, size: 12, color: .secondaryLabelColor))
        row.addArrangedSubview(labels)
        row.addArrangedSubview(spacer())

        let toggle = NSButton(checkboxWithTitle: "", target: SettingsActions.shared, action: action)
        toggle.state = checked ? .on : .off
        toggle.setButtonType(.switch)
        row.addArrangedSubview(toggle)
        return row
    }

    private func permissionRow(symbol: String, title: String, detail: String, granted: Bool, actionTitle: String, action: Selector) -> NSView {
        let stack = verticalStack(spacing: 10)
        let row = horizontalStack(spacing: 10)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        icon.contentTintColor = granted ? UIStatus.ok.foregroundColor : UIStatus.error.foregroundColor
        row.addArrangedSubview(icon)

        let labels = verticalStack(spacing: 2)
        labels.addArrangedSubview(text(title, size: 13, weight: .medium))
        labels.addArrangedSubview(text(detail, size: 12, color: .secondaryLabelColor))
        row.addArrangedSubview(labels)
        row.addArrangedSubview(spacer())
        row.addArrangedSubview(badge(granted ? "Granted" : "Missing", status: granted ? .ok : .error))

        stack.addArrangedSubview(row)
        stack.addArrangedSubview(secondaryButton(actionTitle, symbol: "gearshape", action: action))
        return stack
    }

    private func valueRow(title: String, value: String, status: UIStatus) -> NSView {
        let row = horizontalStack(spacing: 10)
        row.addArrangedSubview(text(title, size: 13, color: .labelColor))
        row.addArrangedSubview(spacer())
        row.addArrangedSubview(badge(value, status: status))
        return row
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSView {
        let row = horizontalStack(spacing: 10)
        buttons.forEach { row.addArrangedSubview($0) }
        row.addArrangedSubview(spacer())
        return row
    }

    private func primaryButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: SettingsActions.shared, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }

    private func secondaryButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: SettingsActions.shared, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.bezelStyle = .rounded
        return button
    }

    private func badge(_ value: String, status: UIStatus) -> NSView {
        let label = text(value, size: 12, weight: .semibold, color: status.foregroundColor)
        label.alignment = .center
        let container = roundedPlainContainer(status.backgroundColor, radius: 8)
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        return container
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    private func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func horizontalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func roundedContainer(material: NSVisualEffectView.Material, radius: CGFloat) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        return view
    }

    private func roundedPlainContainer(_ color: NSColor, radius: CGFloat) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        return view
    }

    private func pin(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    private func faceEnrolled() -> Bool {
        FileManager.default.fileExists(atPath: TemplateStore().url.path)
    }

    private func cameraGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
}

private enum UIStatus {
    case ok
    case warning
    case error
    case neutral

    var foregroundColor: NSColor {
        switch self {
        case .ok:
            return NSColor.systemGreen
        case .warning:
            return NSColor.systemOrange
        case .error:
            return NSColor.systemRed
        case .neutral:
            return NSColor.secondaryLabelColor
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .ok:
            return NSColor.systemGreen.withAlphaComponent(0.12)
        case .warning:
            return NSColor.systemOrange.withAlphaComponent(0.14)
        case .error:
            return NSColor.systemRed.withAlphaComponent(0.12)
        case .neutral:
            return NSColor.controlColor.withAlphaComponent(0.55)
        }
    }
}

@MainActor
private enum AppStyle {
    static func window(title: String, size: NSSize, resizable: Bool = false) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable {
            style.insert(.resizable)
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()
        return window
    }

    static func root(spacing: CGFloat = 18) -> NSStackView {
        let stack = vertical(spacing: spacing)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        return stack
    }

    static func header(symbol: String, title: String, subtitle: String, status: String? = nil, statusKind: UIStatus = .neutral) -> NSView {
        let container = roundedMaterial(.underWindowBackground, radius: 18)
        let row = horizontal(spacing: 14)
        row.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(icon)

        let labels = vertical(spacing: 3)
        labels.addArrangedSubview(text(title, size: 21, weight: .semibold))
        labels.addArrangedSubview(text(subtitle, size: 13, color: .secondaryLabelColor))
        row.addArrangedSubview(labels)
        row.addArrangedSubview(spacer())
        if let status {
            row.addArrangedSubview(badge(status, status: statusKind))
        }

        container.addSubview(row)
        pin(row, to: container)
        return container
    }

    static func section(title: String, subtitle: String? = nil, views: [NSView]) -> NSView {
        let container = roundedMaterial(.contentBackground, radius: 14)
        let stack = vertical(spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.addArrangedSubview(text(title, size: 15, weight: .semibold))
        if let subtitle {
            stack.addArrangedSubview(text(subtitle, size: 12, color: .secondaryLabelColor))
        }
        views.forEach { stack.addArrangedSubview($0) }
        container.addSubview(stack)
        pin(stack, to: container)
        return container
    }

    static func valueRow(title: String, value: String, status: UIStatus = .neutral) -> NSView {
        let row = horizontal(spacing: 10)
        row.addArrangedSubview(text(title, size: 13))
        row.addArrangedSubview(spacer())
        row.addArrangedSubview(badge(value, status: status))
        return row
    }

    static func actionButton(_ title: String, symbol: String, action: Selector, target: AnyObject) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }

    static func destructiveButton(_ title: String, symbol: String, action: Selector, target: AnyObject) -> NSButton {
        let button = actionButton(title, symbol: symbol, action: action, target: target)
        button.contentTintColor = .systemRed
        return button
    }

    static func badge(_ value: String, status: UIStatus) -> NSView {
        let label = text(value, size: 12, weight: .semibold, color: status.foregroundColor)
        label.alignment = .center
        let container = roundedPlain(status.backgroundColor, radius: 8)
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        return container
    }

    static func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 0
        return field
    }

    static func secureField(width: CGFloat = 280) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = "Mac password"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    static func horizontal(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func vertical(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    static func roundedMaterial(_ material: NSVisualEffectView.Material, radius: CGFloat) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        return view
    }

    static func roundedPlain(_ color: NSColor, radius: CGFloat) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        return view
    }

    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}

@MainActor
final class SettingsActions: NSObject {
    static let shared = SettingsActions()
    weak var delegate: FaceUnlockApplication?

    @objc func toggleFaceUnlock() { delegate?.toggleFaceUnlock() }
    @objc func toggleLaunchAtLogin() { delegate?.toggleLaunchAtLogin() }
    @objc func startEnrollment() { delegate?.startEnrollment() }
    @objc func updatePassword() { delegate?.updatePassword() }
    @objc func deletePassword() { delegate?.deletePassword() }
    @objc func openCameraSettings() { delegate?.openCameraSettings() }
    @objc func openAccessibilitySettings() { delegate?.openAccessibilitySettings() }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let onFinish: () -> Void
    private let onSettings: () -> Void

    init(existingFace: Bool, existingPassword: Bool, onFinish: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onSettings = onSettings
        super.init(window: AppStyle.window(title: "Welcome to FaceUnlock", size: NSSize(width: 560, height: 430)))
        window?.contentView = makeContent(existingFace: existingFace, existingPassword: existingPassword)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func makeContent(existingFace: Bool, existingPassword: Bool) -> NSView {
        let root = AppStyle.root()
        root.addArrangedSubview(AppStyle.header(
            symbol: "faceid",
            title: "Welcome to FaceUnlock",
            subtitle: "Unlock your Mac just by looking at it.",
            status: "Ready",
            statusKind: .ok
        ))
        root.addArrangedSubview(AppStyle.section(
            title: "Setup",
            subtitle: "Existing local data was detected automatically.",
            views: [
                AppStyle.valueRow(title: "Existing face enrollment", value: existingFace ? "Detected" : "Missing", status: existingFace ? .ok : .warning),
                AppStyle.valueRow(title: "Existing Keychain password", value: existingPassword ? "Detected" : "Missing", status: existingPassword ? .ok : .warning),
                AppStyle.valueRow(title: "Camera while unlocked", value: "Off", status: .ok)
            ]
        ))

        let buttons = AppStyle.horizontal(spacing: 10)
        buttons.addArrangedSubview(AppStyle.spacer())
        buttons.addArrangedSubview(AppStyle.actionButton("Open Settings", symbol: "slider.horizontal.3", action: #selector(openSettings), target: self))
        buttons.addArrangedSubview(AppStyle.actionButton("Finish", symbol: "checkmark", action: #selector(finish), target: self))
        root.addArrangedSubview(buttons)
        return root
    }

    @objc private func finish() {
        onFinish()
        close()
    }

    @objc private func openSettings() {
        onSettings()
        close()
    }
}

@MainActor
final class DiagnosticsWindowController: NSWindowController {
    init(lines: [String]) {
        super.init(window: AppStyle.window(title: "Diagnostics", size: NSSize(width: 520, height: 420)))
        window?.contentView = makeContent(lines: lines)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func makeContent(lines: [String]) -> NSView {
        let root = AppStyle.root()
        root.addArrangedSubview(AppStyle.header(
            symbol: "stethoscope",
            title: "Diagnostics",
            subtitle: "Quick health check for FaceUnlock runtime.",
            status: "Live",
            statusKind: .neutral
        ))
        let rows = lines.map { line -> NSView in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let title = parts.first ?? line
            let value = parts.count > 1 ? parts[1] : ""
            let status: UIStatus = value.contains("PASS") || value.contains("ACTIVE") || value.contains("ENABLED") ? .ok : (value.contains("FAIL") || value.contains("NO") ? .warning : .neutral)
            return AppStyle.valueRow(title: title, value: value, status: status)
        }
        root.addArrangedSubview(AppStyle.section(title: "Engine Check", subtitle: "No unlock attempt is performed.", views: rows))
        return root
    }
}

@MainActor
final class PasswordWindowController: NSWindowController {
    private let passwordField = AppStyle.secureField(width: 300)
    private let statusLabel = AppStyle.text("Password is validated locally before it is saved.", size: 12, color: .secondaryLabelColor)
    private let onSaved: () -> Void

    init(onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
        super.init(window: AppStyle.window(title: "Update Password", size: NSSize(width: 520, height: 340)))
        window?.contentView = makeContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func makeContent() -> NSView {
        let root = AppStyle.root()
        root.addArrangedSubview(AppStyle.header(
            symbol: "key.fill",
            title: "Save Mac Password",
            subtitle: "Stored securely in macOS Keychain.",
            status: LoginPasswordKeychain.exists() ? "Stored" : "Missing",
            statusKind: LoginPasswordKeychain.exists() ? .ok : .warning
        ))
        root.addArrangedSubview(AppStyle.section(
            title: "Password",
            subtitle: "FaceUnlock never stores this outside Keychain.",
            views: [
                passwordField,
                statusLabel
            ]
        ))

        let buttons = AppStyle.horizontal(spacing: 10)
        buttons.addArrangedSubview(AppStyle.spacer())
        buttons.addArrangedSubview(AppStyle.actionButton("Cancel", symbol: "xmark", action: #selector(cancel), target: self))
        buttons.addArrangedSubview(AppStyle.actionButton("Save Password", symbol: "checkmark", action: #selector(save), target: self))
        root.addArrangedSubview(buttons)
        return root
    }

    @objc private func cancel() {
        close()
    }

    @objc private func save() {
        var password = passwordField.stringValue
        defer { password.removeAll(keepingCapacity: false) }
        guard PasswordCommand.verifyCurrentUserPassword(password) else {
            statusLabel.stringValue = "Password verification failed. Password not saved."
            statusLabel.textColor = .systemRed
            return
        }
        do {
            try LoginPasswordKeychain.store(password)
            statusLabel.stringValue = "Password verification passed. Stored in Keychain."
            statusLabel.textColor = .systemGreen
            onSaved()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.close()
            }
        } catch {
            statusLabel.stringValue = "Could not save password: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }
}

@MainActor
final class ConfirmationWindowController: NSWindowController {
    private let onConfirm: () -> Void

    init(title: String, subtitle: String, symbol: String, destructiveTitle: String, onConfirm: @escaping () -> Void) {
        self.onConfirm = onConfirm
        super.init(window: AppStyle.window(title: title, size: NSSize(width: 500, height: 310)))
        window?.contentView = makeContent(title: title, subtitle: subtitle, symbol: symbol, destructiveTitle: destructiveTitle)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func makeContent(title: String, subtitle: String, symbol: String, destructiveTitle: String) -> NSView {
        let root = AppStyle.root()
        root.addArrangedSubview(AppStyle.header(symbol: symbol, title: title, subtitle: subtitle, status: "Confirm", statusKind: .warning))
        root.addArrangedSubview(AppStyle.section(
            title: "Impact",
            subtitle: "Your face enrollment remains intact. Only the Keychain password item is removed.",
            views: [
                AppStyle.valueRow(title: "FaceUnlock automatic unlock", value: "Disabled until updated", status: .warning),
                AppStyle.valueRow(title: "Face enrollment", value: "Preserved", status: .ok)
            ]
        ))
        let buttons = AppStyle.horizontal(spacing: 10)
        buttons.addArrangedSubview(AppStyle.spacer())
        buttons.addArrangedSubview(AppStyle.actionButton("Cancel", symbol: "xmark", action: #selector(cancel), target: self))
        buttons.addArrangedSubview(AppStyle.destructiveButton(destructiveTitle, symbol: "trash", action: #selector(confirm), target: self))
        root.addArrangedSubview(buttons)
        return root
    }

    @objc private func cancel() {
        close()
    }

    @objc private func confirm() {
        onConfirm()
        close()
    }
}

@MainActor
final class AppEnrollmentController: NSWindowController, @unchecked Sendable {
    private let camera = CameraManager()
    private let liveness = LivenessDetector()
    private let store = TemplateStore()
    private var vectors: [[Double]] = []
    private var lastFrame: FaceFrame?
    private let targetSamples = 8
    private let statusLabel = AppStyle.text("Look at the camera and move your head slightly.", size: 13, color: .secondaryLabelColor)
    private let progressLabel = AppStyle.text("0/8 samples", size: 18, weight: .semibold, color: .controlAccentColor)

    init() {
        super.init(window: AppStyle.window(title: "Enroll Face", size: NSSize(width: 560, height: 380)))
        window?.contentView = makeContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        camera.start { [weak self] frame in
            self?.process(frame)
        }
    }

    override func close() {
        camera.stop()
        super.close()
    }

    private func makeContent() -> NSView {
        let root = AppStyle.root()
        root.addArrangedSubview(AppStyle.header(
            symbol: "faceid",
            title: "Enroll Face",
            subtitle: "Capture a few natural angles for local recognition.",
            status: "Camera",
            statusKind: .neutral
        ))
        root.addArrangedSubview(AppStyle.section(
            title: "Capture",
            subtitle: "Move your head slightly and blink naturally.",
            views: [
                AppStyle.valueRow(title: "Target samples", value: "\(targetSamples)", status: .neutral),
                progressLabel,
                statusLabel
            ]
        ))
        return root
    }

    private func process(_ frame: FaceFrame) {
        guard liveness.add(frame) else { return }
        guard distinct(frame) else { return }
        vectors.append(frame.vector)
        lastFrame = frame
        let count = vectors.count
        DispatchQueue.main.async {
            self.progressLabel.stringValue = "\(count)/\(self.targetSamples) samples"
            self.statusLabel.stringValue = "Sample \(count) captured."
            self.statusLabel.textColor = .secondaryLabelColor
        }
        if count >= targetSamples {
            finish()
        }
    }

    private func distinct(_ frame: FaceFrame) -> Bool {
        guard let lastFrame else { return true }
        let similarity = FaceAnalyzer.similarity(lastFrame.vector, frame.vector)
        let centerDelta = hypot(frame.center.x - lastFrame.center.x, frame.center.y - lastFrame.center.y)
        let sizeDelta = abs(frame.size.width - lastFrame.size.width) + abs(frame.size.height - lastFrame.size.height)
        return similarity < 0.992 || centerDelta > 0.012 || sizeDelta > 0.018
    }

    private func finish() {
        let template = FaceTemplate(createdAt: Date(), samples: vectors.count, vector: FaceAnalyzer.average(vectors))
        do {
            try store.save(template)
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "Enrollment complete."
                self.statusLabel.textColor = .systemGreen
                self.progressLabel.stringValue = "\(self.targetSamples)/\(self.targetSamples) samples"
                self.camera.stop()
            }
        } catch {
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "Enrollment failed: \(error.localizedDescription)"
                self.statusLabel.textColor = .systemRed
                self.camera.stop()
            }
        }
    }
}

@MainActor
final class AppFaceTestController: NSWindowController, @unchecked Sendable {
    private let camera = CameraManager()
    private let liveness = LivenessDetector()
    private let template = try? TemplateStore().load()
    private let statusLabel = AppStyle.text("Look at the camera.", size: 13, color: .secondaryLabelColor)
    private let resultLabel = AppStyle.text("Waiting for liveness", size: 18, weight: .semibold, color: .controlAccentColor)
    private let onMatch: @MainActor () -> Void
    private var finished = false

    init(onMatch: @escaping @MainActor () -> Void) {
        self.onMatch = onMatch
        super.init(window: AppStyle.window(title: "Test Face Recognition", size: NSSize(width: 560, height: 340)))
        window?.contentView = makeContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard template != nil else {
            statusLabel.stringValue = "No enrollment template found."
            statusLabel.textColor = .systemOrange
            resultLabel.stringValue = "Enrollment missing"
            resultLabel.textColor = .systemOrange
            return
        }
        camera.start { [weak self] frame in
            self?.process(frame)
        }
    }

    override func close() {
        camera.stop()
        super.close()
    }

    private func makeContent() -> NSView {
        let root = AppStyle.root()
        root.addArrangedSubview(AppStyle.header(
            symbol: "viewfinder",
            title: "Test Face Recognition",
            subtitle: "Runs liveness and matching without unlocking the Mac.",
            status: "Dry Run",
            statusKind: .neutral
        ))
        root.addArrangedSubview(AppStyle.section(
            title: "Result",
            subtitle: "No keyboard events are sent from this test.",
            views: [
                resultLabel,
                statusLabel
            ]
        ))
        return root
    }

    private func process(_ frame: FaceFrame) {
        guard !finished, liveness.add(frame), let template else { return }
        let similarity = FaceAnalyzer.similarity(template.vector, frame.vector)
        let matched = similarity >= AppPreferences.recognitionThreshold
        finished = true
        DispatchQueue.main.async {
            self.resultLabel.stringValue = matched ? "Identity Match" : "No Match"
            self.resultLabel.textColor = matched ? .systemGreen : .systemOrange
            self.statusLabel.stringValue = String(format: "Liveness passed. Similarity %.2f.", similarity)
            self.camera.stop()
            if matched {
                self.onMatch()
            }
        }
    }
}

@MainActor
func showError(_ title: String, detail: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

@MainActor
func runFaceUnlockApp() {
    let app = NSApplication.shared
    let delegate = FaceUnlockApplication()
    app.delegate = delegate
    app.run()
}
