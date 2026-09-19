import AppKit
import AVFoundation

private enum FaceUnlockSettingsPane: Int, CaseIterable {
    case general
    case identity
    case appearance
    case permissions
    case runtime

    var title: String {
        switch self {
        case .general: "General"
        case .identity: "Face & Password"
        case .appearance: "Appearance"
        case .permissions: "Privacy & Security"
        case .runtime: "Runtime"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Behavior and recognition settings"
        case .identity: "Face enrollment and Keychain password"
        case .appearance: "Unlock animation and color"
        case .permissions: "Camera and Accessibility access"
        case .runtime: "Live engine diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .identity: "faceid"
        case .appearance: "paintpalette.fill"
        case .permissions: "lock.shield.fill"
        case .runtime: "waveform.path.ecg"
        }
    }

    var color: NSColor {
        switch self {
        case .general: .systemGray
        case .identity: .systemBlue
        case .appearance: .systemPurple
        case .permissions: .systemGreen
        case .runtime: .systemOrange
        }
    }

    var keywords: String {
        switch self {
        case .general: "enable launch login attempts threshold recognition"
        case .identity: "face enroll password keychain delete update"
        case .appearance: "animation color preview face id"
        case .permissions: "camera accessibility privacy security"
        case .runtime: "session monitor engine status logs diagnostics error"
        }
    }
}

private enum SettingsIndicator {
    case good
    case warning
    case error
    case neutral

    var color: NSColor {
        switch self {
        case .good: .systemGreen
        case .warning: .systemOrange
        case .error: .systemRed
        case .neutral: .secondaryLabelColor
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var app: FaceUnlockApplication?
    private let engine: FaceUnlockEngine
    private let splitView = NSSplitView()
    private let sidebarTable = NSTableView()
    private let searchField = NSSearchField()
    private let contentStack = FlippedSettingsStackView()
    private let contentScrollView = NSScrollView()
    private let brandStatus = NSTextField(labelWithString: "")
    private var selectedPane: FaceUnlockSettingsPane = .general
    private var visiblePanes = FaceUnlockSettingsPane.allCases
    private var animationPreviewImage: NSImageView?
    private var animationSuccessImage: NSImageView?
    private var colorWell: NSColorWell?
    private var colorSwatches: [SettingsColorSwatchButton] = []

    private let colorPresets: [(name: String, color: NSColor)] = [
        ("Blue", .systemBlue),
        ("Cyan", .systemCyan),
        ("Green", .systemGreen),
        ("Purple", .systemPurple),
        ("Pink", .systemPink),
        ("Orange", .systemOrange)
    ]

    init(app: FaceUnlockApplication, engine: FaceUnlockEngine) {
        self.app = app
        self.engine = engine

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 960, height: 720)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FaceUnlock Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 820, height: 600)
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("FaceUnlockSettingsWindow")

        super.init(window: window)
        configureSidebar()
        configureContentArea()
        configureSplitView()
        sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.initialFirstResponder = sidebarTable
        window.makeFirstResponder(sidebarTable)
        rebuildPage()
        window.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func refresh() {
        updateBrandStatus()
        rebuildPage()
    }

    private func configureSplitView() {
        guard let window else { return }

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = splitView

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active

        let detail = NSVisualEffectView()
        detail.material = .windowBackground
        detail.blendingMode = .behindWindow
        detail.state = .active

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(detail)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        NSLayoutConstraint.activate([
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 280)
        ])

        configureSidebar(in: sidebar)
        configureContentArea(in: detail)
        splitView.setPosition(248, ofDividerAt: 0)
    }

    private func configureSidebar() {
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
    }

    private func configureSidebar(in sidebar: NSView) {
        let brand = makeBrandView()
        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SettingsPane"))
        sidebarTable.addTableColumn(column)
        sidebarTable.headerView = nil
        sidebarTable.rowHeight = 38
        sidebarTable.intercellSpacing = NSSize(width: 0, height: 3)
        sidebarTable.backgroundColor = .clear
        sidebarTable.style = .sourceList
        sidebarTable.focusRingType = .none

        let tableScroll = NSScrollView()
        tableScroll.documentView = sidebarTable
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = false

        let version = label("FaceUnlock 0.1", size: 11, color: .tertiaryLabelColor)
        version.alignment = .center

        [brand, searchField, tableScroll, version].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview($0)
        }

        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            brand.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 45),

            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 16),

            tableScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            tableScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            tableScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            tableScroll.bottomAnchor.constraint(equalTo: version.topAnchor, constant: -10),

            version.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            version.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            version.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -14)
        ])
    }

    private func configureContentArea() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.edgeInsets = NSEdgeInsets(top: 34, left: 36, bottom: 40, right: 36)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        contentScrollView.drawsBackground = false
        contentScrollView.hasVerticalScroller = true
        contentScrollView.automaticallyAdjustsContentInsets = false
        contentScrollView.documentView = contentStack
    }

    private func configureContentArea(in detail: NSView) {
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(contentScrollView)
        NSLayoutConstraint.activate([
            contentScrollView.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            contentScrollView.topAnchor.constraint(equalTo: detail.topAnchor, constant: 28),
            contentScrollView.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: contentScrollView.contentView.widthAnchor),
            contentStack.bottomAnchor.constraint(greaterThanOrEqualTo: contentScrollView.contentView.bottomAnchor)
        ])
    }

    private func makeBrandView() -> NSView {
        let row = horizontalStack(spacing: 11)
        let icon = NSImageView(image: NSImage(named: "FaceUnlock") ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 42),
            icon.heightAnchor.constraint(equalToConstant: 42)
        ])
        row.addArrangedSubview(icon)

        let textStack = verticalStack(spacing: 2)
        textStack.addArrangedSubview(label("FaceUnlock", size: 15, weight: .semibold))
        brandStatus.font = .systemFont(ofSize: 11)
        textStack.addArrangedSubview(brandStatus)
        row.addArrangedSubview(textStack)
        updateBrandStatus()
        return row
    }

    private func updateBrandStatus() {
        let enabled = AppPreferences.enableFaceUnlock
        brandStatus.stringValue = enabled ? "Active" : "Paused"
        brandStatus.textColor = enabled ? .systemGreen : .secondaryLabelColor
    }

    @objc
    private func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            visiblePanes = FaceUnlockSettingsPane.allCases
        } else {
            visiblePanes = FaceUnlockSettingsPane.allCases.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.subtitle.localizedCaseInsensitiveContains(query)
                    || $0.keywords.localizedCaseInsensitiveContains(query)
            }
        }
        sidebarTable.reloadData()

        if let row = visiblePanes.firstIndex(of: selectedPane) {
            sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if let first = visiblePanes.first {
            selectedPane = first
            sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            rebuildPage()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visiblePanes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visiblePanes.indices.contains(row) else { return nil }
        return SettingsSidebarCell(pane: visiblePanes[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarTable.selectedRow
        guard visiblePanes.indices.contains(row) else { return }
        selectedPane = visiblePanes[row]
        rebuildPage()
    }

    private func rebuildPage() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        animationPreviewImage = nil
        animationSuccessImage = nil
        colorWell = nil
        colorSwatches.removeAll()

        addContent(pageHeader(for: selectedPane))
        switch selectedPane {
        case .general:
            buildGeneralPage()
        case .identity:
            buildIdentityPage()
        case .appearance:
            buildAppearancePage()
        case .permissions:
            buildPermissionsPage()
        case .runtime:
            buildRuntimePage()
        }
    }

    private func buildGeneralPage() {
        addSectionTitle("FaceUnlock")
        addContent(settingsGroup(rows: [
            settingRow(
                symbol: "faceid",
                color: .systemBlue,
                title: "Enable Face Unlock",
                detail: "Recognize your face only while the Mac is locked.",
                trailing: switchControl(
                    checked: AppPreferences.enableFaceUnlock,
                    action: #selector(toggleFaceUnlock(_:))
                )
            ),
            settingRow(
                symbol: "arrow.clockwise",
                color: .systemGreen,
                title: "Launch at Login",
                detail: "Keep FaceUnlock available after signing in.",
                trailing: switchControl(
                    checked: AppPreferences.launchAtLogin,
                    action: #selector(toggleLaunchAtLogin(_:))
                )
            )
        ]))

        addSectionTitle("Recognition")
        addContent(settingsGroup(rows: [
            settingRow(
                symbol: "number",
                color: .systemOrange,
                title: "Maximum Attempts",
                detail: "Recognition attempts allowed for each lock.",
                trailing: attemptsControl()
            ),
            settingRow(
                symbol: "dial.medium",
                color: .systemPurple,
                title: "Recognition Threshold",
                detail: "Higher values require a closer facial match.",
                trailing: thresholdControl()
            )
        ]))

        let snapshot = engine.snapshot()
        addSectionTitle("Status")
        addContent(settingsGroup(rows: [
            valueSettingRow(title: "Unlock Engine", value: snapshot.unlockEngineEnabled ? "Enabled" : "Disabled", indicator: snapshot.unlockEngineEnabled ? .good : .warning),
            valueSettingRow(title: "Current Session", value: snapshot.currentSession.rawValue.capitalized, indicator: .neutral),
            valueSettingRow(title: "Camera While Unlocked", value: snapshot.cameraOn ? "On" : "Off", indicator: snapshot.cameraOn ? .warning : .good)
        ]))
    }

    private func buildIdentityPage() {
        let enrolled = faceEnrolled()
        let samples = (try? TemplateStore().load())?.samples
        addSectionTitle("Face")
        addContent(settingsGroup(rows: [
            settingRow(
                symbol: "faceid",
                color: .systemBlue,
                title: "Face Enrollment",
                detail: samples.map { "Stored locally from \($0) samples." } ?? "No face template is currently available.",
                trailing: actionButton("Re-enroll...", action: #selector(startEnrollment), symbol: nil)
            ),
            valueSettingRow(title: "Enrollment Status", value: enrolled ? "Enrolled" : "Missing", indicator: enrolled ? .good : .warning)
        ]))

        let passwordStored = LoginPasswordKeychain.passwordAvailable()
        addSectionTitle("Mac Password")
        addContent(settingsGroup(rows: [
            settingRow(
                symbol: "key.fill",
                color: .systemYellow,
                title: "Keychain Password",
                detail: "Stored only in the macOS Keychain and never written to logs.",
                trailing: actionButton("Update...", action: #selector(updatePassword), symbol: nil)
            ),
            valueSettingRow(title: "Password Status", value: passwordStored ? "Stored" : "Missing", indicator: passwordStored ? .good : .warning),
            settingRow(
                symbol: "trash.fill",
                color: .systemRed,
                title: "Delete Stored Password",
                detail: "Automatic unlock remains disabled until a password is stored again.",
                trailing: actionButton("Delete...", action: #selector(deletePassword), symbol: nil, destructive: true)
            )
        ]))
    }

    private func buildAppearancePage() {
        addSectionTitle("Unlock Animation")
        addContent(settingsGroup(rows: [
            animationPreviewRow(),
            settingRow(
                symbol: "paintpalette.fill",
                color: AppPreferences.animationColor,
                title: "Animation Color",
                detail: "Applied to both the Face ID scan and success check.",
                trailing: colorControls()
            )
        ]))
    }

    private func buildPermissionsPage() {
        let camera = cameraGranted()
        let accessibility = AXIsProcessTrusted()
        addSectionTitle("Privacy")
        addContent(settingsGroup(rows: [
            settingRow(
                symbol: "camera.fill",
                color: .systemBlue,
                title: "Camera",
                detail: "Used only while locked, testing, or enrolling.",
                trailing: permissionControl(
                    granted: camera,
                    actionTitle: "Open Settings...",
                    action: #selector(openCameraSettings)
                )
            ),
            settingRow(
                symbol: "accessibility",
                color: .systemBlue,
                title: "Accessibility",
                detail: "Allows FaceUnlock to enter credentials on the Lock Screen.",
                trailing: permissionControl(
                    granted: accessibility,
                    actionTitle: "Open Settings...",
                    action: #selector(openAccessibilitySettings)
                )
            )
        ]))

        addSectionTitle("Privacy Summary")
        addContent(settingsGroup(rows: [
            valueSettingRow(title: "Face Processing", value: "On Device", indicator: .good),
            valueSettingRow(title: "Camera During Normal Use", value: "Off", indicator: .good),
            valueSettingRow(title: "Network Required", value: "No", indicator: .good)
        ]))
    }

    private func buildRuntimePage() {
        let snapshot = engine.snapshot()
        addSectionTitle("Engine")
        addContent(settingsGroup(rows: [
            valueSettingRow(title: "App Running", value: yesNo(snapshot.appRunning), indicator: snapshot.appRunning ? .good : .error),
            valueSettingRow(title: "Session Monitor", value: snapshot.sessionMonitorActive ? "Active" : "Inactive", indicator: snapshot.sessionMonitorActive ? .good : .error),
            valueSettingRow(title: "Unlock Engine", value: snapshot.unlockEngineEnabled ? "Enabled" : "Disabled", indicator: snapshot.unlockEngineEnabled ? .good : .warning),
            valueSettingRow(title: "Camera", value: snapshot.cameraOn ? "On" : "Off", indicator: snapshot.cameraOn ? .warning : .neutral)
        ]))

        addSectionTitle("Recent Activity")
        addContent(settingsGroup(rows: [
            valueSettingRow(title: "Last Lock Event", value: snapshot.lastLockEvent, indicator: .neutral),
            valueSettingRow(title: "Last Face Result", value: snapshot.lastFaceResult, indicator: .neutral),
            valueSettingRow(title: "Last Unlock Attempt", value: snapshot.lastUnlockAttempt, indicator: .neutral),
            valueSettingRow(title: "Last Error", value: snapshot.lastError, indicator: snapshot.lastError == "None" ? .good : .error)
        ]))

        addSectionTitle("Diagnostics")
        let actions = horizontalStack(spacing: 10)
        actions.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        actions.addArrangedSubview(actionButton("Run Engine Check", action: #selector(showDiagnostics), symbol: "stethoscope"))
        actions.addArrangedSubview(actionButton("Open Log", action: #selector(openLog), symbol: "doc.text"))
        actions.addArrangedSubview(spacer())
        addContent(settingsGroup(rows: [actions]))
    }

    private func pageHeader(for pane: FaceUnlockSettingsPane) -> NSView {
        let stack = verticalStack(spacing: 7)
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        stack.addArrangedSubview(symbolTile(symbol: pane.symbol, color: pane.color, size: 58, symbolSize: 30, radius: 13))

        let title = label(pane.title, size: 26, weight: .bold)
        title.alignment = .center
        stack.addArrangedSubview(title)

        let subtitle = label(pane.subtitle, size: 13, color: .secondaryLabelColor)
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        stack.addArrangedSubview(subtitle)
        return stack
    }

    private func addSectionTitle(_ title: String) {
        let field = label(title, size: 13, weight: .semibold, color: .secondaryLabelColor)
        addContent(field)
        contentStack.setCustomSpacing(7, after: field)
    }

    private func addContent(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -72).isActive = true
    }

    private func settingsGroup(rows: [NSView]) -> NSView {
        let group = NSVisualEffectView()
        group.material = .contentBackground
        group.blendingMode = .withinWindow
        group.state = .active
        group.wantsLayer = true
        group.layer?.cornerRadius = 11
        group.layer?.cornerCurve = .continuous
        group.layer?.borderWidth = 0.5
        group.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor

        let stack = verticalStack(spacing: 0)
        rows.enumerated().forEach { index, row in
            stack.addArrangedSubview(row)
            if index < rows.count - 1 {
                stack.addArrangedSubview(groupSeparator())
            }
        }
        group.addSubview(stack)
        pin(stack, to: group)
        return group
    }

    private func settingRow(symbol: String, color: NSColor, title: String, detail: String, trailing: NSView) -> NSView {
        let row = horizontalStack(spacing: 12)
        row.edgeInsets = NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)
        row.addArrangedSubview(symbolTile(symbol: symbol, color: color, size: 30, symbolSize: 16, radius: 7))

        let labels = verticalStack(spacing: 2)
        labels.addArrangedSubview(label(title, size: 13, weight: .medium))
        let detailLabel = label(detail, size: 11, color: .secondaryLabelColor)
        detailLabel.maximumNumberOfLines = 2
        labels.addArrangedSubview(detailLabel)
        row.addArrangedSubview(labels)
        row.addArrangedSubview(spacer())
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(trailing)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        return row
    }

    private func valueSettingRow(title: String, value: String, indicator: SettingsIndicator) -> NSView {
        let row = horizontalStack(spacing: 10)
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.addArrangedSubview(label(title, size: 13))
        row.addArrangedSubview(spacer())
        row.addArrangedSubview(statusView(value, indicator: indicator))
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
    }

    private func animationPreviewRow() -> NSView {
        let row = horizontalStack(spacing: 16)
        row.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 14)

        let glyphs = horizontalStack(spacing: 12)
        let face = symbolImage("faceid", pointSize: 44, color: AppPreferences.animationColor)
        let arrow = symbolImage("arrow.right", pointSize: 15, color: .tertiaryLabelColor)
        let success = symbolImage("checkmark.circle", pointSize: 44, color: AppPreferences.animationColor)
        animationPreviewImage = face
        animationSuccessImage = success
        glyphs.addArrangedSubview(face)
        glyphs.addArrangedSubview(arrow)
        glyphs.addArrangedSubview(success)
        row.addArrangedSubview(glyphs)

        let labels = verticalStack(spacing: 3)
        labels.addArrangedSubview(label("Face ID Success", size: 13, weight: .medium))
        labels.addArrangedSubview(label("Animated scan, confirmation, and bounce.", size: 11, color: .secondaryLabelColor))
        row.addArrangedSubview(labels)
        row.addArrangedSubview(spacer())
        row.addArrangedSubview(actionButton("Preview", action: #selector(previewAnimation), symbol: "play.fill"))
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
        return row
    }

    private func colorControls() -> NSView {
        let row = horizontalStack(spacing: 7)
        let selectedColor = AppPreferences.animationColor
        colorSwatches = colorPresets.enumerated().map { index, preset in
            let button = SettingsColorSwatchButton(color: preset.color, name: preset.name)
            button.tag = index
            button.target = self
            button.action = #selector(selectPresetColor(_:))
            button.isSelectedColor = colorsMatch(preset.color, selectedColor)
            row.addArrangedSubview(button)
            return button
        }

        let well = NSColorWell()
        well.colorWellStyle = .minimal
        well.color = selectedColor
        well.toolTip = "Custom color"
        well.target = self
        well.action = #selector(customColorChanged(_:))
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 28),
            well.heightAnchor.constraint(equalToConstant: 28)
        ])
        colorWell = well
        row.addArrangedSubview(well)
        return row
    }

    private func permissionControl(granted: Bool, actionTitle: String, action: Selector) -> NSView {
        let row = horizontalStack(spacing: 10)
        row.addArrangedSubview(statusView(granted ? "Granted" : "Required", indicator: granted ? .good : .error))
        if !granted {
            row.addArrangedSubview(actionButton(actionTitle, action: action, symbol: nil))
        }
        return row
    }

    private func attemptsControl() -> NSView {
        let row = horizontalStack(spacing: 8)
        let value = label("\(AppPreferences.maxAttempts)", size: 13, weight: .medium)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 5
        stepper.increment = 1
        stepper.integerValue = AppPreferences.maxAttempts
        stepper.target = self
        stepper.action = #selector(maxAttemptsChanged(_:))
        row.addArrangedSubview(value)
        row.addArrangedSubview(stepper)
        return row
    }

    private func thresholdControl() -> NSView {
        let row = horizontalStack(spacing: 9)
        let slider = NSSlider(
            value: AppPreferences.recognitionThreshold,
            minValue: 0.70,
            maxValue: 0.95,
            target: self,
            action: #selector(thresholdChanged(_:))
        )
        slider.isContinuous = false
        slider.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let value = label(String(format: "%.2f", AppPreferences.recognitionThreshold), size: 12, weight: .medium, color: .secondaryLabelColor)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 32).isActive = true
        row.addArrangedSubview(slider)
        row.addArrangedSubview(value)
        return row
    }

    private func statusView(_ value: String, indicator: SettingsIndicator) -> NSView {
        let row = horizontalStack(spacing: 6)
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = indicator.color.cgColor
        dot.layer?.cornerRadius = 3.5
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7)
        ])
        row.addArrangedSubview(dot)
        row.addArrangedSubview(label(value, size: 12, weight: .medium, color: indicator.color))
        return row
    }

    private func switchControl(checked: Bool, action: Selector) -> NSSwitch {
        let control = NSSwitch()
        control.target = self
        control.action = action
        control.state = checked ? .on : .off
        return control
    }

    private func actionButton(_ title: String, action: Selector, symbol: String?, destructive: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageLeading
        }
        button.toolTip = title
        if destructive {
            button.contentTintColor = .systemRed
        }
        return button
    }

    private func symbolTile(symbol: String, color: NSColor, size: CGFloat, symbolSize: CGFloat, radius: CGFloat) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = color.cgColor
        tile.layer?.cornerRadius = radius
        tile.layer?.cornerCurve = .continuous
        let image = symbolImage(symbol, pointSize: symbolSize, color: .white)
        tile.addSubview(image)
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size),
            tile.heightAnchor.constraint(equalToConstant: size),
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            image.widthAnchor.constraint(lessThanOrEqualTo: tile.widthAnchor, constant: -6),
            image.heightAnchor.constraint(lessThanOrEqualTo: tile.heightAnchor, constant: -6)
        ])
        return tile
    }

    private func symbolImage(_ symbol: String, pointSize: CGFloat, color: NSColor) -> NSImageView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        image.contentTintColor = color
        image.imageScaling = .scaleProportionallyDown
        return image
    }

    private func groupSeparator() -> NSView {
        let holder = NSView()
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 54),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
            line.centerYAnchor.constraint(equalTo: holder.centerYAnchor)
        ])
        return holder
    }

    private func label(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
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
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.deviceRGB),
              let right = rhs.usingColorSpace(.deviceRGB) else { return false }
        return abs(left.redComponent - right.redComponent) < 0.015
            && abs(left.greenComponent - right.greenComponent) < 0.015
            && abs(left.blueComponent - right.blueComponent) < 0.015
    }

    private func updateColorControls() {
        let color = AppPreferences.animationColor
        animationPreviewImage?.contentTintColor = color
        animationSuccessImage?.contentTintColor = color
        colorWell?.color = color
        colorSwatches.enumerated().forEach { index, swatch in
            swatch.isSelectedColor = colorsMatch(colorPresets[index].color, color)
        }
    }

    @objc private func toggleFaceUnlock(_ sender: NSSwitch) { app?.toggleFaceUnlock() }
    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) { app?.toggleLaunchAtLogin() }
    @objc private func startEnrollment() { app?.startEnrollment() }
    @objc private func updatePassword() { app?.updatePassword() }
    @objc private func deletePassword() { app?.deletePassword() }
    @objc private func openCameraSettings() { app?.openCameraSettings() }
    @objc private func openAccessibilitySettings() { app?.openAccessibilitySettings() }
    @objc private func showDiagnostics() { app?.showDiagnostics() }
    @objc private func openLog() { app?.openLog() }
    @objc private func previewAnimation() { app?.previewUnlockAnimation() }

    @objc
    private func maxAttemptsChanged(_ sender: NSStepper) {
        AppPreferences.maxAttempts = sender.integerValue
        rebuildPage()
    }

    @objc
    private func thresholdChanged(_ sender: NSSlider) {
        AppPreferences.recognitionThreshold = sender.doubleValue
        rebuildPage()
    }

    @objc
    private func selectPresetColor(_ sender: SettingsColorSwatchButton) {
        guard colorPresets.indices.contains(sender.tag) else { return }
        AppPreferences.animationColor = colorPresets[sender.tag].color
        updateColorControls()
    }

    @objc
    private func customColorChanged(_ sender: NSColorWell) {
        AppPreferences.animationColor = sender.color
        updateColorControls()
    }
}

@MainActor
private final class SettingsSidebarCell: NSTableCellView {
    init(pane: FaceUnlockSettingsPane) {
        super.init(frame: .zero)

        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = pane.color.cgColor
        tile.layer?.cornerRadius = 6
        tile.layer?.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false

        let image = NSImageView(image: NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)

        let title = NSTextField(labelWithString: pane.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        textField = title

        addSubview(tile)
        addSubview(title)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 25),
            tile.heightAnchor.constraint(equalToConstant: 25),
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private final class SettingsColorSwatchButton: NSButton {
    let swatchColor: NSColor

    var isSelectedColor = false {
        didSet { updateSelectionRing() }
    }

    init(color: NSColor, name: String) {
        swatchColor = color
        super.init(frame: .zero)
        title = ""
        toolTip = name
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func updateSelectionRing() {
        layer?.borderWidth = isSelectedColor ? 2.5 : 0
        layer?.borderColor = NSColor.labelColor.cgColor
        layer?.shadowColor = isSelectedColor ? NSColor.black.cgColor : nil
        layer?.shadowOpacity = isSelectedColor ? 0.22 : 0
        layer?.shadowRadius = 2
        layer?.shadowOffset = .zero
    }
}

private final class FlippedSettingsStackView: NSStackView {
    override var isFlipped: Bool { true }
}
