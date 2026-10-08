import AppKit
import DisplayKeysCore

/// Shows a shortcut and records a new one: click it, or focus it and press Space, then press
/// the keys. Delete removes the shortcut and Esc cancels.
final class ShortcutField: NSView {
    private enum Key {
        static let escape: UInt16 = 53
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let space: UInt16 = 49
        static let `return`: UInt16 = 36
    }

    var shortcut: Shortcut? {
        didSet { needsDisplay = true }
    }

    /// What the field is for, read by VoiceOver, such as "Brightness up shortcut".
    var title = ""
    /// Returns why a recorded shortcut cannot be used, or nil when it can. The shortcut is nil
    /// when the pressed key is not one a shortcut can use.
    var validate: ((Shortcut?) -> String?)?
    /// Called with the new shortcut, or nil when it was removed.
    var onChange: ((Shortcut?) -> Void)?
    /// Called with a message to show beside the fields, or nil to clear it.
    var onMessage: ((String?) -> Void)?
    /// Called when the field starts waiting for keys and when it stops. While it waits, the
    /// app's own shortcuts have to be out of the way, or pressing one would act.
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            needsDisplay = true
            if isRecording != oldValue { onRecordingChange?(isRecording) }
        }
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        outline.fill()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    // MARK: Recording

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startRecording()
    }

    private func startRecording() {
        isRecording = true
        onMessage?(nil)
    }

    /// Gives up waiting for keys and keeps the shortcut as it was.
    func stopRecording() {
        isRecording = false
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    /// Shortcuts with Cmd arrive as key equivalents instead of key presses.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        isRecording && handle(event)
    }

    /// Takes a key press; false when the field has no use for it.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = Self.modifiers(of: event)
        let isBare = modifiers.isEmpty

        // The change is passed on before the recording ends, so that whoever puts the app's
        // shortcuts back at that point already has the new one.
        if isBare, [Key.delete, Key.forwardDelete].contains(event.keyCode) {
            shortcut = nil
            onMessage?(nil)
            onChange?(nil)
            isRecording = false
            return true
        }
        guard isRecording else {
            guard isBare, [Key.space, Key.return].contains(event.keyCode) else { return false }
            startRecording()
            return true
        }
        if isBare, event.keyCode == Key.escape {
            isRecording = false
            return true
        }

        let recorded = Shortcut(keyCode: Int(event.keyCode), modifiers: modifiers)
        if let reason = validate?(recorded) {
            onMessage?(reason)
            return true
        }
        guard let recorded else { return true }
        shortcut = recorded
        onMessage?(nil)
        onChange?(recorded)
        isRecording = false
        return true
    }

    private static func modifiers(of event: NSEvent) -> Shortcut.Modifiers {
        var modifiers: Shortcut.Modifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    // MARK: Drawing

    private var outline: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = outline
        // A translucent fill, so the field sits on the panel's glass and not as a slab over it.
        NSColor.tertiarySystemFill.setFill()
        frame.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        frame.lineWidth = isRecording ? 2 : 1
        frame.stroke()

        let label = NSAttributedString(
            string: isRecording ? "Press keys…" : shortcut?.symbols ?? "None",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: isRecording || shortcut == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ])
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityHelp() -> String? { "Press Space, then the keys for the shortcut. Delete removes it." }

    override func accessibilityValue() -> Any? {
        isRecording ? "Recording" : shortcut?.spoken ?? "None"
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        startRecording()
        return true
    }
}
