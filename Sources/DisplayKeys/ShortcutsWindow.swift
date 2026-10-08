import AppKit
import DisplayKeysCore

/// The Shortcuts window: one recordable field per action, plus the quarter-steps option.
/// It is built the first time it is shown. Changes are saved as they are made.
@MainActor
final class ShortcutsWindow: NSObject, NSWindowDelegate {
    private static let contentSize = NSSize(width: 420, height: 322)
    private static let rowHeight: CGFloat = 32

    /// Called when the window opens, so the app can release its shortcuts: a shortcut that is
    /// still registered would act instead of being recorded.
    private let onOpen: () -> Void
    private let onClose: () -> Void
    private var window: NSWindow?
    private var fields: [Shortcut.Action: ShortcutField] = [:]
    private var quarterStepsBox: NSButton?

    init(onOpen: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onClose = onClose
    }

    func show() {
        let window = window ?? makeWindow()
        reload()
        onOpen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    /// The window's content, also used on its own to check the layout in tests.
    func makeContentView() -> NSView {
        let content = FlippedView(frame: NSRect(origin: .zero, size: Self.contentSize))
        for (index, action) in Shortcut.Action.allCases.enumerated() {
            let top = 20 + CGFloat(index) * Self.rowHeight
            let label = NSTextField(labelWithString: action.title)
            label.frame = NSRect(x: 20, y: top + 5, width: 150, height: 18)
            content.addSubview(label)

            let field = ShortcutField(frame: NSRect(x: 176, y: top + 1, width: 190, height: 26))
            field.onChange = { [unowned self] shortcut in
                ShortcutSettings.set(shortcut?.text ?? "", for: action)
                reload()
            }
            content.addSubview(field)
            fields[action] = field

            let clear = NSButton(
                image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove shortcut")!,
                target: self, action: #selector(clearShortcut))
            clear.isBordered = false
            clear.contentTintColor = .tertiaryLabelColor
            clear.tag = index
            clear.frame = NSRect(x: 374, y: top + 2, width: 24, height: 24)
            content.addSubview(clear)
        }

        let rowsBottom = 20 + CGFloat(Shortcut.Action.allCases.count) * Self.rowHeight
        let box = NSButton(
            checkboxWithTitle: "Also register each with Shift, for quarter steps", target: self,
            action: #selector(quarterStepsChanged))
        box.frame = NSRect(x: 18, y: rowsBottom + 8, width: 384, height: 20)
        content.addSubview(box)
        quarterStepsBox = box

        let help = NSTextField(
            wrappingLabelWithString: "Click a field, then press the keys: Ctrl, Alt, Shift or Cmd with an arrow, page, "
                + "Home, End or function key. Esc cancels. Shortcuts are paused while this window is open.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 20, y: rowsBottom + 38, width: 380, height: 44)
        content.addSubview(help)

        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restore.frame = NSRect(x: 14, y: rowsBottom + 90, width: 150, height: 30)
        content.addSubview(restore)
        reload()
        return content
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "\(AppInfo.name) Shortcuts"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContentView()
        window.center()
        self.window = window
        return window
    }

    private func reload() {
        for (action, field) in fields {
            field.shortcut = ShortcutSettings.text(for: action).flatMap(Shortcut.init)
        }
        quarterStepsBox?.state = ShortcutSettings.quarterSteps ? .on : .off
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        ShortcutSettings.set("", for: Shortcut.Action.allCases[sender.tag])
        reload()
    }

    @objc private func quarterStepsChanged(_ sender: NSButton) {
        ShortcutSettings.quarterSteps = sender.state == .on
    }

    @objc private func restoreDefaults() {
        for action in Shortcut.Action.allCases { ShortcutSettings.set(nil, for: action) }
        ShortcutSettings.quarterSteps = false
        reload()
    }
}

/// Lays its subviews out from the top, like the rows of a form.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Shows a shortcut and records a new one: click it, then press the keys.
final class ShortcutField: NSView {
    private static let escapeKeyCode: UInt16 = 53

    var shortcut: Shortcut? {
        didSet { needsDisplay = true }
    }

    /// Called with the shortcut the user recorded.
    var onChange: ((Shortcut?) -> Void)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !record(event) { super.keyDown(with: event) }
    }

    /// Shortcuts with Cmd arrive as key equivalents instead of key presses.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        record(event)
    }

    /// Takes a key press while recording; false when the field is not recording.
    private func record(_ event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return false }
        if event.keyCode == Self.escapeKeyCode {
            isRecording = false
            return true
        }
        var modifiers: Shortcut.Modifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        guard let recorded = Shortcut(keyCode: Int(event.keyCode), modifiers: modifiers), recorded.isUsable else {
            NSSound.beep()
            return true
        }
        isRecording = false
        shortcut = recorded
        onChange?(recorded)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        frame.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        frame.lineWidth = isRecording ? 2 : 1
        frame.stroke()

        let text = isRecording ? "Press keys…" : shortcut?.symbols ?? "None"
        let label = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: isRecording || shortcut == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ])
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
