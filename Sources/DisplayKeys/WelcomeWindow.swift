import AppKit
import DisplayKeysCore

/// A short notice shown on first launch, and again when an update leaves the keyboard's own
/// keys switched off. It comes before any permission step and says why the app asks.
///
/// It is a glass panel like Settings, with everything centred under the app's icon, and looks
/// the same on both occasions. Each part is placed below the one before it at its measured
/// height, so no two can overlap.
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
    private var dontAskBox: NSButton?

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

    /// The window's content, also used on its own to check the layout in tests.
    func makeContentView(_ occasion: Occasion, keysAreActive: Bool) -> NSView {
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        let inner = Self.width - Self.margin * 2
        var y = GlassPanel.titleBarHeight + 6

        /// Places a view below the ones before it, centred, and leaves a gap under it.
        func add(_ view: NSView, gap: CGFloat) {
            view.setFrameOrigin(NSPoint(x: ((Self.width - view.frame.width) / 2).rounded(), y: y))
            content.addSubview(view)
            y += view.frame.height + gap
        }
        func text(
            _ string: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
        ) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: string)
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = color
            label.alignment = .center
            label.isSelectable = false
            let bounds = NSRect(x: 0, y: 0, width: inner, height: .greatestFiniteMagnitude)
            label.frame.size = NSSize(width: inner, height: ceil(label.cell?.cellSize(forBounds: bounds).height ?? 0))
            return label
        }

        let icon = NSImageView(frame: NSRect(x: 0, y: 0, width: Self.iconSide, height: Self.iconSide))
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
            add(
                text(
                    "You can also change them, if you want. Choose Settings… from the sun’s menu.", size: 12,
                    color: .secondaryLabelColor), gap: 14)
        } else {
            add(text("Look for the sun in the menu bar."), gap: 12)
        }
        add(text(Self.keysText(occasion, keysAreActive: keysAreActive), size: 12, color: .secondaryLabelColor), gap: 22)

        add(buttons(keysAreActive: keysAreActive), gap: 14)
        if occasion == .update, !keysAreActive {
            let box = NSButton(checkboxWithTitle: "Don’t ask again after updates", target: nil, action: nil)
            box.sizeToFit()
            dontAskBox = box
            add(box, gap: 6)
        }
        content.setFrameSize(NSSize(width: Self.width, height: y + 14))
        return content
    }

    /// What to say about the keyboard's own keys.
    private static func keysText(_ occasion: Occasion, keysAreActive: Bool) -> String {
        let list = AccessibilityAccess.listName
        switch (occasion, keysAreActive) {
        case (.firstLaunch, true):
            return "The volume keys on your keyboard control the display too."
        case (.firstLaunch, false):
            return "The volume keys on your keyboard work too once \(AppInfo.name) is switched on under \(list) "
                + "in System Settings. It uses that only to receive those keys."
        case (.update, true):
            return "The volume keys on your keyboard control the display, as before."
        case (.update, false):
            return "The volume keys on your keyboard are off until \(AppInfo.name) is added to \(list) again in "
                + "System Settings. macOS grants that to one build of an app at a time."
        }
    }

    /// The buttons side by side, the one that acts on the right.
    private func buttons(keysAreActive: Bool) -> NSView {
        func button(_ title: String, _ action: Selector, key: String, minimumWidth: CGFloat) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.controlSize = .large
            button.keyEquivalent = key
            button.sizeToFit()
            button.frame.size.width = max(button.frame.width, minimumWidth)
            return button
        }
        let row: [NSButton] =
            keysAreActive
            ? [button("OK", #selector(dismiss), key: "\r", minimumWidth: 110)]
            : [
                button("Not Now", #selector(dismiss), key: "\u{1b}", minimumWidth: 110),
                button("Turn On Keyboard Keys…", #selector(turnOn), key: "\r", minimumWidth: 0),
            ]
        let holder = NSView()
        var x: CGFloat = 0
        for button in row {
            button.setFrameOrigin(NSPoint(x: x, y: 0))
            holder.addSubview(button)
            x = button.frame.maxX + 10
        }
        holder.setFrameSize(NSSize(width: x - 10, height: row.map(\.frame.height).max() ?? 0))
        return holder
    }

    /// The current shortcuts as rows on a faint panel, one row per control; nil when none is set.
    private static func shortcutList(width: CGFloat) -> NSView? {
        let controls: [(name: String, symbol: String, actions: [Shortcut.Action])] = [
            ("Brightness", "sun.max.fill", [.brightnessDown, .brightnessUp]),
            ("Volume", "speaker.wave.2.fill", [.volumeDown, .volumeUp]),
            ("Mute", "speaker.slash.fill", [.mute]),
        ]
        let rowHeight: CGFloat = 30
        let holder = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        var y: CGFloat = 8
        for control in controls {
            let shortcuts = control.actions.compactMap(ShortcutSettings.shortcut)
            guard !shortcuts.isEmpty else { continue }

            let glyph = NSImageView(frame: NSRect(x: 12, y: y + 4, width: 20, height: 20))
            glyph.image = NSImage(systemSymbolName: control.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            glyph.contentTintColor = .secondaryLabelColor
            holder.addSubview(glyph)

            let name = NSTextField(labelWithString: control.name)
            name.frame = NSRect(x: 40, y: y + 6, width: 120, height: 18)
            holder.addSubview(name)

            var x = width - 12
            for shortcut in shortcuts.reversed() {
                let cap = KeyCap(shortcut)
                x -= cap.frame.width
                cap.setFrameOrigin(NSPoint(x: x, y: y + 4))
                holder.addSubview(cap)
                x -= 6
            }
            y += rowHeight
        }
        guard y > 8 else { return nil }
        holder.setFrameSize(NSSize(width: width, height: y + 8))
        holder.addSubview(WellView(frame: holder.bounds), positioned: .below, relativeTo: nil)
        return holder
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
        if dontAskBox?.state == .on { onDontAsk() }
        dontAskBox = nil
    }
}

/// A shortcut drawn as a key cap, such as ⌃⌥↑.
private final class KeyCap: NSView {
    private let shortcut: Shortcut
    private let text: NSAttributedString

    init(_ shortcut: Shortcut) {
        self.shortcut = shortcut
        text = NSAttributedString(
            string: shortcut.symbols,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(text.size().width) + 16, height: 22))
    }

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
