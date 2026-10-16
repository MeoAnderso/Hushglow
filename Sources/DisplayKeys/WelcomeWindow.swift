import AppKit
import DisplayKeysCore

/// A short notice shown on first launch, and again when an update leaves the keyboard's own
/// keys switched off. It comes before any permission step and says why the app asks.
///
/// It is a glass panel like Settings, with everything centred under the app's icon, and looks
/// the same on both occasions. The parts are stacked in one column, so each takes the height
/// its text needs and no two can overlap.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    enum Occasion {
        case firstLaunch
        /// A new build is running without the Accessibility access an earlier one had.
        case update
    }

    private static let width: CGFloat = 440
    private static let margin: CGFloat = 36
    private static let iconSide: CGFloat = 84

    private let onTurnOn: () -> Void
    private let onDontAsk: () -> Void
    private var window: NSWindow?
    private var askAgainBox: NSButton?

    init(onTurnOn: @escaping () -> Void, onDontAsk: @escaping () -> Void) {
        self.onTurnOn = onTurnOn
        self.onDontAsk = onDontAsk
    }

    func show(_ occasion: Occasion, keysAreActive: Bool) {
        let window = makeWindow(occasion, keysAreActive: keysAreActive)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The window, also used on its own to photograph it in tests.
    func makeWindow(_ occasion: Occasion, keysAreActive: Bool) -> NSWindow {
        let content = makeContentView(occasion, keysAreActive: keysAreActive)
        let window = GlassPanel.makeWindow(title: AppInfo.name, content: content)
        window.titleVisibility = .hidden
        // Only closing makes sense for a notice, so the two buttons that would sit there
        // disabled are left out.
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.delegate = self
        self.window = window
        return window
    }

    // MARK: Layout

    /// The window's content, also used on its own to check the layout in tests: one column,
    /// centred, in which each part takes the height its text needs.
    func makeContentView(_ occasion: Occasion, keysAreActive: Bool) -> NSView {
        let inner = Self.width - Self.margin * 2
        var parts: [(view: NSView, gap: CGFloat)] = []

        /// Places a view below the ones before it, centred, and leaves a gap under it.
        func add(_ view: NSView, gap: CGFloat) {
            parts.append((view, gap))
        }
        func text(
            _ string: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
        ) -> NSTextField {
            let label = Layout.wrappingLabel(string, width: inner)
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = color
            label.alignment = .center
            label.isSelectable = false
            return label
        }

        let icon = Layout.size(NSImageView(), NSSize(width: Self.iconSide, height: Self.iconSide))
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        add(icon, gap: 12)

        // Both occasions share one design; only the title and the last paragraph differ.
        add(
            text("\(AppInfo.name) \(occasion == .firstLaunch ? "is running" : "was updated")", size: 20, weight: .bold),
            gap: 8)
        if let shortcuts = Self.shortcutList(width: inner) {
            add(text("Look for the sun in the menu bar. These shortcuts control your display:"), gap: 12)
            add(shortcuts, gap: 8)
            let change = "You can also change them, if you want. Choose Settings… from the sun’s menu."
            let why = occasion == .firstLaunch ? Self.whyFunctionKeys() : nil
            add(
                text([why, change].compactMap { $0 }.joined(separator: " "), size: 12, color: .secondaryLabelColor),
                gap: 14)
        } else {
            add(text("Look for the sun in the menu bar."), gap: 12)
        }
        add(text(Self.keysText(occasion, keysAreActive: keysAreActive), size: 12, color: .secondaryLabelColor), gap: 22)

        add(buttons(keysAreActive: keysAreActive), gap: 14)
        if occasion == .update, !keysAreActive {
            let box = NSButton(checkboxWithTitle: KeyboardKeys.askAgain, target: nil, action: nil)
            box.state = .on
            askAgainBox = box
            add(box, gap: 6)
        }

        let body = Layout.column(parts.map(\.view), spacing: 0, alignment: .centerX)
        for part in parts { body.setCustomSpacing(part.gap, after: part.view) }
        // A stack leaves no room after its last part, so its gap goes into the margin.
        body.edgeInsets = NSEdgeInsets(
            top: GlassPanel.titleBarHeight + 6, left: 0, bottom: 14 + (parts.last?.gap ?? 0), right: 0)
        return GlassPanel.content(body, width: Self.width)
    }

    /// Why the shortcuts are on the function keys, when a window manager is the reason; nil
    /// when they are not. Only the first launch says it, since that is when they were chosen.
    static func whyFunctionKeys(
        set: Shortcut.DefaultSet = ShortcutSettings.defaultSet, managers: [String] = WindowManagers.installed,
        functionKeysAreStandard: Bool = UserDefaults.standard.bool(forKey: "com.apple.keyboard.fnState")
    ) -> String? {
        guard set == .functionKeys, !managers.isEmpty else { return nil }
        let names = managers.joined(separator: " and ")
        let uses = managers.count == 1 ? "uses" : "use"
        // On an Apple keyboard the top row sends brightness and volume unless set otherwise.
        let fn = functionKeysAreStandard ? "" : " On an Apple keyboard, hold fn with them."
        return "\(names) \(uses) Ctrl+Alt with the arrow keys, so these are on the function keys.\(fn)"
    }

    /// What to say about the keyboard's own keys.
    private static func keysText(_ occasion: Occasion, keysAreActive: Bool) -> String {
        let list = AccessibilityAccess.listName
        switch (occasion, keysAreActive) {
        case (.firstLaunch, true):
            return "The \(KeyboardKeys.phrase) on your keyboard control the display too."
        case (.firstLaunch, false):
            return "The \(KeyboardKeys.phrase) on your keyboard work too once \(AppInfo.name) is switched on "
                + "under \(list) in System Settings. It uses that only for those keys."
        case (.update, true):
            return "The \(KeyboardKeys.phrase) on your keyboard control the display, as before."
        case (.update, false):
            return "The \(KeyboardKeys.phrase) on your keyboard are off until \(AppInfo.name) is added to "
                + "\(list) again in System Settings. macOS grants that to one build at a time."
        }
    }

    /// The buttons side by side, the one that acts on the right.
    private func buttons(keysAreActive: Bool) -> NSView {
        func button(_ title: String, _ action: Selector, key: String, minimumWidth: CGFloat) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.controlSize = .large
            button.keyEquivalent = key
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
            return button
        }
        let row: [NSButton] =
            keysAreActive
            ? [button("OK", #selector(dismiss), key: "\r", minimumWidth: 110)]
            : [
                button("Not Now", #selector(dismiss), key: "\u{1b}", minimumWidth: 110),
                button("Turn On \(KeyboardKeys.name)…", #selector(turnOn), key: "\r", minimumWidth: 0),
            ]
        return Layout.row(row, spacing: 10)
    }

    /// The current shortcuts as rows on a faint panel, one row per control; nil when none is set.
    private static func shortcutList(width: CGFloat) -> NSView? {
        let controls: [(name: String, symbol: String, actions: [Shortcut.Action])] = [
            ("Brightness", "sun.max.fill", [.brightnessDown, .brightnessUp]),
            ("Volume", "speaker.wave.2.fill", [.volumeDown, .volumeUp]),
            ("Mute", "speaker.slash.fill", [.mute]),
        ]
        var rows: [[NSView]] = []
        for control in controls {
            let shortcuts = control.actions.compactMap(ShortcutSettings.shortcut)
            guard !shortcuts.isEmpty else { continue }

            let glyph = Layout.size(NSImageView(), NSSize(width: 20, height: 20))
            glyph.image = NSImage(systemSymbolName: control.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            glyph.contentTintColor = .secondaryLabelColor
            let name = NSTextField(labelWithString: control.name)
            // The name takes the room the key caps leave.
            name.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            rows.append([glyph, name, Layout.row(shortcuts.map(KeyCap.init), spacing: 6)])
        }
        guard !rows.isEmpty else { return nil }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        grid.yPlacement = .center
        grid.rowAlignment = .none
        grid.column(at: 0).width = 20
        grid.column(at: 2).xPlacement = .trailing
        let well = WellView(around: grid, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        well.widthAnchor.constraint(equalToConstant: width).isActive = true
        return well
    }

    // MARK: Actions

    @objc private func turnOn() {
        // Asking for access turns asking back on, so the checkbox is applied after it.
        onTurnOn()
        dismiss()
    }

    @objc private func dismiss() {
        applyCheckbox()
        window?.close()
    }

    /// Closing by any route, the close button included, honours the checkbox.
    func windowWillClose(_ notification: Notification) {
        applyCheckbox()
        window = nil
    }

    private func applyCheckbox() {
        if askAgainBox?.state == .off { onDontAsk() }
        askAgainBox = nil
    }
}

/// A shortcut drawn as a key cap, such as ⌃⌥↑.
private final class KeyCap: NSView {
    private let shortcut: Shortcut
    private let text: NSAttributedString
    private let size: NSSize

    init(_ shortcut: Shortcut) {
        self.shortcut = shortcut
        text = NSAttributedString(
            string: shortcut.symbols,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
        size = NSSize(width: ceil(text.size().width) + 16, height: 22)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    override var intrinsicContentSize: NSSize { size }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.tertiarySystemFill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { shortcut.spoken }
}
