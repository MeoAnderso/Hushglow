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
    private static let margin: CGFloat = 20
    private static let controlLeft: CGFloat = 176

    /// Called once the window has closed. Whoever holds this object can then let it go: the
    /// window and its controls are not kept for a Settings that may never be opened again.
    var onClose: (() -> Void)?

    private unowned let host: any SettingsHost
    private var window: NSWindow?
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

    /// The window's content, also used on its own to check the layout in tests.
    func makeContentView() -> NSView {
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        var y = GlassPanel.titleBarHeight + 14
        let inner = Self.width - Self.margin * 2

        /// Starts a titled group of rows; call the result when the rows are in, to set the
        /// group apart on its own faint panel.
        func section(_ title: String) -> () -> Void {
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: 13)
            label.frame = NSRect(x: Self.margin + 4, y: y, width: inner, height: 18)
            content.addSubview(label)
            y += 26
            let top = y
            y += 10
            return {
                let well = WellView(frame: NSRect(x: Self.margin - 6, y: top, width: inner + 12, height: y - top + 4))
                content.addSubview(well, positioned: .below, relativeTo: nil)
                y += 22
            }
        }
        func rowLabel(_ title: String) {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: Self.margin + 12, y: y + 5, width: Self.controlLeft - Self.margin - 20, height: 18)
            content.addSubview(label)
        }
        func checkbox(_ title: String, _ action: Selector) -> NSButton {
            let box = NSButton(checkboxWithTitle: title, target: self, action: action)
            box.frame = NSRect(x: Self.margin + 10, y: y, width: inner - 20, height: 20)
            content.addSubview(box)
            y += 26
            return box
        }
        func popup(_ title: String, _ titles: [String], _ action: Selector) -> NSPopUpButton {
            rowLabel(title)
            let popup = NSPopUpButton(
                frame: NSRect(x: Self.controlLeft, y: y, width: 240, height: 26), pullsDown: false)
            popup.addItems(withTitles: titles)
            popup.target = self
            popup.action = action
            popup.setAccessibilityLabel(title)
            content.addSubview(popup)
            y += 32
            return popup
        }
        func note(_ text: String, height: CGFloat) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: Self.margin + 12, y: y, width: inner - 24, height: height)
            content.addSubview(label)
            y += height + 8
            return label
        }

        var close = section("Indicator")
        stylePopup = popup("Style", IndicatorSettings.Style.allCases.map(\.title), #selector(indicatorChanged))
        positionPopup = popup("Position", IndicatorSettings.Position.allCases.map(\.title), #selector(indicatorChanged))
        percentageBox = checkbox("Show the level as a percentage", #selector(indicatorChanged))
        close()

        close = section("Shortcuts")
        for (index, action) in Shortcut.Action.allCases.enumerated() {
            rowLabel(action.title)
            let field = ShortcutField(frame: NSRect(x: Self.controlLeft, y: y, width: 200, height: 26))
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
            content.addSubview(field)
            fields[action] = field

            let clear = NSButton(
                image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!, target: self,
                action: #selector(clearShortcut))
            clear.isBordered = false
            clear.contentTintColor = .tertiaryLabelColor
            clear.tag = index
            clear.setAccessibilityLabel("Remove the \(action.title) shortcut")
            clear.frame = NSRect(x: Self.controlLeft + 208, y: y + 1, width: 24, height: 24)
            content.addSubview(clear)
            y += 32
        }
        quarterStepsBox = checkbox("Also register each with Shift, for quarter steps", #selector(quarterStepsChanged))
        message = note("", height: 28)
        y -= 8
        close()

        close = section("The keyboard’s own volume keys")
        keysStatus = note("", height: 44)
        let button = NSButton(title: "Turn On…", target: self, action: #selector(turnOnKeys))
        button.frame = NSRect(x: Self.margin + 6, y: y, width: 110, height: 30)
        content.addSubview(button)
        keysButton = button
        y += 36
        askBox = checkbox("Ask again after an update", #selector(askChanged))
        close()

        close = section("General")
        loginBox = checkbox("Launch at login", #selector(loginChanged))
        close()

        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(askToRestoreDefaults))
        restore.frame = NSRect(x: Self.width - Self.margin - 150, y: y - 6, width: 156, height: 30)
        content.addSubview(restore)
        y += 40

        content.setFrameSize(NSSize(width: Self.width, height: y))
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
            ? "On. Volume and brightness keys on the keyboard control the display."
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
            "The shortcuts and the indicator go back to how they were at first. The keyboard’s own keys and "
            + "launch at login stay as they are."
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
