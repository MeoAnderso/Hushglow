import AppKit
import DisplayKeysCore
import ServiceManagement

/// What the Settings window needs from the app.
@MainActor
protocol SettingsHost: AnyObject {
    var keyboardKeysAreActive: Bool { get }
    var keyboardAskingIsDisabled: Bool { get set }
    func enableKeyboardKeys()
    /// Releases the shortcuts while one is being recorded: one that is still registered would
    /// act instead of being recorded.
    func pauseShortcuts()
    /// Registers the shortcuts as the settings now have them.
    func resumeShortcuts()
    /// Whether macOS accepts the shortcut.
    func canRegister(_ shortcut: Shortcut) -> Bool
    /// The shortcuts macOS has switched on for itself, such as Mission Control on Ctrl-Up.
    var shortcutsUsedByMacOS: [Shortcut] { get }
    /// Shows the indicator, so a change to its look can be seen at once.
    func previewIndicator()
}

/// The Settings window: the indicator's look, the shortcuts, the keyboard's own keys and
/// launch at login. It is built the first time it is shown, and changes are saved as they
/// are made.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 460
    /// From the window's edges to the faint panels, and from a panel's edges to its rows.
    private static let wellMargin: CGFloat = 14
    private static let wellPadding: CGFloat = 18
    /// The least width of the column of labels beside the controls.
    private static let labelWidth: CGFloat = 136

    /// Called once the window has closed. Whoever holds this object can then let it go: the
    /// window and its controls are not kept for a Settings that may never be opened again.
    var onClose: (() -> Void)?

    private unowned let host: any SettingsHost
    private var window: NSWindow?
    private var content: FittedView?
    private var fields: [Shortcut.Action: ShortcutField] = [:]
    private var message: NSTextField?
    /// Why the last recorded shortcut was turned down; shown until the next attempt.
    private var rejectionText: String?
    private var quarterStepsBox: NSButton?
    private var keysStatus: NSTextField?
    private var keysButton: NSButton?
    private var askBox: NSButton?
    private var loginBox: NSButton?
    private var stylePopup: NSPopUpButton?
    private var positionPopup: NSPopUpButton?
    private var percentageBox: NSButton?
    /// Asks whether the defaults should really be restored and passes the answer on. Tests
    /// answer in its place.
    lazy var confirmRestore: (@escaping @MainActor (Bool) -> Void) -> Void = { [unowned self] in askInASheet($0) }

    init(host: any SettingsHost) {
        self.host = host
    }

    func show() {
        let window = window ?? makeWindow()
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isOpen: Bool { window != nil }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        window = nil
        // Said a moment later, so that this object is not let go from inside the closing.
        perform(#selector(didClose), with: nil, afterDelay: 0)
    }

    @objc private func didClose() {
        if !isOpen { onClose?() }
    }

    /// A recording left waiting in a window that is no longer in front would keep the
    /// shortcuts switched off for as long as the window stays open.
    func windowDidResignKey(_ notification: Notification) {
        stopRecording()
    }

    private func stopRecording() {
        for field in fields.values { field.stopRecording() }
    }

    /// Access may have been granted in System Settings while this window was in the background.
    func windowDidBecomeKey(_ notification: Notification) {
        reload()
    }

    // MARK: Layout

    /// The window's content, also used on its own to check the layout in tests. Each group of
    /// rows is a grid or a stack, so that it takes the room its text needs.
    func makeContentView() -> NSView {
        let wellWidth = Self.width - Self.wellMargin * 2
        let rowWidth = wellWidth - Self.wellPadding * 2

        /// A titled group of rows on its own faint panel.
        func section(_ title: String, _ rows: [NSView]) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: 13)
            let well = WellView(
                around: Layout.column(rows, spacing: 8),
                insets: NSEdgeInsets(top: 12, left: Self.wellPadding, bottom: 12, right: Self.wellPadding))
            well.widthAnchor.constraint(equalToConstant: wellWidth).isActive = true
            let section = NSView()
            for part in [label, well] {
                part.translatesAutoresizingMaskIntoConstraints = false
                section.addSubview(part)
            }
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: section.topAnchor),
                label.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 12),
                well.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
                well.leadingAnchor.constraint(equalTo: section.leadingAnchor),
                well.trailingAnchor.constraint(equalTo: section.trailingAnchor),
                well.bottomAnchor.constraint(equalTo: section.bottomAnchor),
            ])
            return section
        }
        /// Rows of a label and its controls. The labels share a column at least as wide as the
        /// one in the other groups, so that the controls line up from one group to the next.
        func form(_ rows: [(String, [NSView])], spacing: CGFloat) -> NSGridView {
            let grid = NSGridView(
                views: rows.map { title, controls in
                    let label = NSTextField(labelWithString: title)
                    label.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.labelWidth).isActive = true
                    return [label] + controls
                })
            grid.columnSpacing = 8
            grid.rowSpacing = spacing
            grid.yPlacement = .center
            grid.rowAlignment = .none
            return grid
        }
        func checkbox(_ title: String, _ action: Selector) -> NSButton {
            NSButton(checkboxWithTitle: title, target: self, action: action)
        }
        func popup(_ title: String, _ titles: [String], _ action: Selector) -> NSPopUpButton {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: titles)
            popup.target = self
            popup.action = action
            popup.setAccessibilityLabel(title)
            popup.widthAnchor.constraint(equalToConstant: 240).isActive = true
            return popup
        }
        func note() -> NSTextField {
            let label = Layout.wrappingLabel("", width: rowWidth)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            return label
        }

        let stylePopup = popup("Style", IndicatorSettings.Style.allCases.map(\.title), #selector(indicatorChanged))
        let positionPopup = popup(
            "Position", IndicatorSettings.Position.allCases.map(\.title), #selector(indicatorChanged))
        let percentageBox = checkbox("Show the level as a percentage", #selector(indicatorChanged))
        self.stylePopup = stylePopup
        self.positionPopup = positionPopup
        self.percentageBox = percentageBox
        let indicator = section(
            "Indicator", [form([("Style", [stylePopup]), ("Position", [positionPopup])], spacing: 8), percentageBox])

        var shortcutRows: [(String, [NSView])] = []
        for (index, action) in Shortcut.Action.allCases.enumerated() {
            let field = Layout.size(ShortcutField(frame: .zero), NSSize(width: 200, height: 26))
            field.title = "\(action.title) shortcut"
            field.validate = { [unowned self] in rejection(of: $0, for: action) }
            field.onMessage = { [unowned self] in show(message: $0) }
            field.onChange = { [unowned self] shortcut in
                ShortcutSettings.set(shortcut?.text ?? "", for: action)
                reload()
                applyShortcuts()
            }
            field.onRecordingChange = { [unowned self] isRecording in
                if isRecording { host.pauseShortcuts() } else { host.resumeShortcuts() }
            }
            fields[action] = field

            let clear = NSButton(
                image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!, target: self,
                action: #selector(clearShortcut))
            clear.isBordered = false
            clear.contentTintColor = .tertiaryLabelColor
            clear.tag = index
            clear.setAccessibilityLabel("Remove the \(action.title) shortcut")
            shortcutRows.append((action.title, [field, Layout.size(clear, NSSize(width: 24, height: 24))]))
        }
        let quarterStepsBox = checkbox(
            "Also register each with Shift, for quarter steps", #selector(quarterStepsChanged))
        self.quarterStepsBox = quarterStepsBox
        let message = note()
        // Room for two lines, so that a message coming or going moves nothing.
        message.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        self.message = message
        let shortcuts = section("Shortcuts", [form(shortcutRows, spacing: 6), quarterStepsBox, message])

        let keysStatus = note()
        self.keysStatus = keysStatus
        let keysButton = NSButton(title: "Turn On…", target: self, action: #selector(turnOnKeys))
        self.keysButton = keysButton
        let askBox = checkbox(KeyboardKeys.askAgain, #selector(askChanged))
        self.askBox = askBox
        let keys = section(KeyboardKeys.phrase.capitalizedFirst, [keysStatus, keysButton, askBox])

        let loginBox = checkbox("Launch at login", #selector(loginChanged))
        self.loginBox = loginBox
        let general = section("General", [loginBox])

        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(askToRestoreDefaults))
        let restoreRow = NSStackView()
        restoreRow.setViews([restore], in: .trailing)
        restoreRow.widthAnchor.constraint(equalToConstant: wellWidth).isActive = true

        let body = Layout.column([indicator, shortcuts, keys, general, restoreRow], spacing: 20)
        body.setCustomSpacing(14, after: general)
        body.edgeInsets = NSEdgeInsets(
            top: GlassPanel.titleBarHeight + 14, left: Self.wellMargin, bottom: 20, right: Self.wellMargin)
        let content = GlassPanel.content(body, width: Self.width)
        self.content = content
        reload()
        return content
    }

    /// The window, also used on its own to photograph it in tests.
    func makeWindow() -> NSWindow {
        let window = GlassPanel.makeWindow(title: "\(AppInfo.name) Settings", content: makeContentView())
        window.delegate = self
        self.window = window
        return window
    }

    private func reload() {
        stylePopup?.selectItem(at: IndicatorSettings.Style.allCases.firstIndex(of: IndicatorSettings.style) ?? 0)
        positionPopup?.selectItem(
            at: IndicatorSettings.Position.allCases.firstIndex(of: IndicatorSettings.position) ?? 0)
        percentageBox?.state = IndicatorSettings.showsPercentage ? .on : .off

        for (action, field) in fields {
            field.shortcut = ShortcutSettings.shortcut(for: action)
        }
        quarterStepsBox?.state = ShortcutSettings.quarterSteps ? .on : .off

        let isActive = host.keyboardKeysAreActive
        keysStatus?.stringValue =
            isActive
            ? "On. The \(KeyboardKeys.phrase) on the keyboard control the display."
            : "Off. Turning them on adds \(AppInfo.name) to \(AccessibilityAccess.listName) in System Settings, "
                + "which it uses only to receive those keys. The shortcuts above work without it."
        keysButton?.isHidden = isActive
        askBox?.state = host.keyboardAskingIsDisabled ? .off : .on
        askBox?.isHidden = isActive

        // Login items point at the app's location, so only offer it once the app is installed.
        let isInstalled = Bundle.main.bundlePath.contains("/Applications/")
        loginBox?.isEnabled = isInstalled
        loginBox?.title = isInstalled ? "Launch at login" : "Launch at login (move the app to Applications first)"
        loginBox?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        refreshMessage()
        // A line of text or a button that came or went changes the height the window needs.
        if let content { GlassPanel.fit(window, to: content) }
    }

    private func show(message text: String?) {
        rejectionText = text
        refreshMessage()
    }

    /// The line under the shortcuts: why the last attempt was turned down, or else which of the
    /// current shortcuts macOS uses itself.
    private func refreshMessage() {
        let clash = rejectionText == nil ? clashNote() : nil
        message?.stringValue = rejectionText ?? clash ?? ""
        message?.textColor = rejectionText == nil ? .systemOrange : .systemRed
    }

    /// Names the current shortcuts, quarter steps included, that macOS has a shortcut of its
    /// own on; nil when there are none. A shortcut can end up here when it was chosen before
    /// macOS's one was switched on, or through its Shift variant.
    private func clashNote() -> String? {
        let system = host.shortcutsUsedByMacOS
        var clashing: [Shortcut] = []
        for action in Shortcut.Action.allCases {
            guard let shortcut = ShortcutSettings.shortcut(for: action) else { continue }
            clashing += shortcut.claimed(for: action, quarterSteps: ShortcutSettings.quarterSteps)
                .filter(system.contains)
        }
        guard !clashing.isEmpty else { return nil }
        let names = clashing.map(\.symbols).joined(separator: ", ")
        return "macOS uses \(names) for shortcuts of its own, so \(clashing.count == 1 ? "it" : "they") may not "
            + "work here."
    }

    // MARK: Shortcuts

    /// Why a recorded shortcut cannot be used for an action, in words; nil when it can.
    private func rejection(of shortcut: Shortcut?, for action: Shortcut.Action) -> String? {
        switch Shortcut.check(
            shortcut, for: action, others: ShortcutSettings.shortcuts, quarterSteps: ShortcutSettings.quarterSteps,
            isUsedBySystem: host.shortcutsUsedByMacOS.contains)
        {
        case .usedBySystem:
            return "macOS uses \(shortcut?.symbols ?? "those keys") itself. Choose other keys, or switch its "
                + "shortcut off in System Settings › Keyboard."
        case .unsupportedKey:
            return "That key can’t be used. Choose an arrow, page, Home, End or function key."
        case .needsModifier:
            return "Add Ctrl, Alt, Shift or Cmd. On its own, that key would stop working in every app."
        case .usedBy(let other):
            return "\(other.title) already uses those keys."
        case nil:
            guard let shortcut, !host.canRegister(shortcut) else { return nil }
            return "macOS did not accept \(shortcut.symbols); another app may be using it."
        }
    }

    /// Has the app register the shortcuts as they now are. While a field is recording they
    /// stay out of the way; the end of the recording registers them.
    private func applyShortcuts() {
        if !fields.values.contains(where: \.isRecording) { host.resumeShortcuts() }
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        ShortcutSettings.set("", for: Shortcut.Action.allCases[sender.tag])
        show(message: nil)
        reload()
        applyShortcuts()
    }

    @objc private func quarterStepsChanged(_ sender: NSButton) {
        ShortcutSettings.quarterSteps = sender.state == .on
        show(message: nil)
        applyShortcuts()
    }

    // MARK: Other settings

    @objc private func indicatorChanged() {
        if let index = stylePopup?.indexOfSelectedItem {
            IndicatorSettings.style = IndicatorSettings.Style.allCases[index]
        }
        if let index = positionPopup?.indexOfSelectedItem {
            IndicatorSettings.position = IndicatorSettings.Position.allCases[index]
        }
        IndicatorSettings.showsPercentage = percentageBox?.state == .on
        host.previewIndicator()
    }

    @objc private func turnOnKeys() {
        host.enableKeyboardKeys()
    }

    @objc private func askChanged(_ sender: NSButton) {
        host.keyboardAskingIsDisabled = sender.state == .off
    }

    @objc private func loginChanged(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch at login could not be changed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Launch at login could not be changed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        reload()
    }

    /// Shortcuts someone has chosen are not thrown away on one click.
    @objc private func askToRestoreDefaults() {
        confirmRestore { [weak self] confirmed in
            if confirmed { self?.restoreDefaults() }
        }
    }

    private func askInASheet(_ answer: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Restore the default settings?"
        alert.informativeText =
            "The shortcuts and the indicator go back to how they were at first. The \(KeyboardKeys.phrase) "
            + "and launch at login stay as they are."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return answer(alert.runModal() == .alertFirstButtonReturn) }
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }

    private func restoreDefaults() {
        for action in Shortcut.Action.allCases { ShortcutSettings.set(nil, for: action) }
        ShortcutSettings.quarterSteps = false
        IndicatorSettings.style = .glass
        IndicatorSettings.position = .underMenuBarIcon
        IndicatorSettings.showsPercentage = false
        show(message: nil)
        reload()
        applyShortcuts()
    }
}

/// Lays its subviews out from the top, like the rows of a form.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
