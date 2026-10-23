import AppKit
import HushglowCore

/// Shows a shortcut and records a new one: click it, or focus it and press Space, then press
/// the keys. Delete removes the shortcut and Esc cancels. While it waits for keys it shows the
/// modifiers that are held, as they are pressed.
final class ShortcutField: ContrastAwareView {
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
    /// Called when the field takes the focus and when it gives it up.
    var onFocusChange: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            heldModifiers = []
            needsDisplay = true
            if isRecording != oldValue { onRecordingChange?(isRecording) }
        }
    }

    /// The modifiers held down while the field waits for keys.
    private(set) var heldModifiers: Shortcut.Modifiers = [] {
        didSet { if heldModifiers != oldValue { needsDisplay = true } }
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
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        onFocusChange?(false)
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

    override func flagsChanged(with event: NSEvent) {
        if isRecording { heldModifiers = Shortcut.modifiers(of: event) }
        super.flagsChanged(with: event)
    }

    /// Shortcuts with Cmd arrive as key equivalents instead of key presses.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        isRecording && handle(event)
    }

    /// Takes a key press; false when the field has no use for it.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let isBare = Shortcut.modifiers(of: event).isEmpty

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

        let recorded = Shortcut(keyPress: event)
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

    // MARK: Drawing

    /// What the field shows: the shortcut, or while it waits for keys the modifiers held so far.
    var shownText: String {
        guard isRecording else { return shortcut?.symbols ?? String(localized: "None", comment: "No shortcut") }
        return heldModifiers.isEmpty
            ? String(localized: "Press keys…")
            : String(localized: "\(heldModifiers.symbols)…", comment: "Keys held so far")
    }

    private var outline: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = outline
        // A translucent fill, so the field sits on the panel's glass and not as a slab over it.
        NSColor.tertiarySystemFill.setFill()
        frame.fill()
        let edge: NSColor = increasesContrast ? .secondaryLabelColor : .separatorColor
        (isRecording ? NSColor.controlAccentColor : edge).setStroke()
        frame.lineWidth = isRecording ? 2 : 1
        frame.stroke()

        let label = NSAttributedString(
            string: shownText,
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
    override func accessibilityHelp() -> String? {
        String(localized: "Press Space, then the keys for the shortcut. Delete removes it.")
    }

    override func accessibilityValue() -> Any? {
        isRecording
            ? String(localized: "Recording", comment: "A shortcut field waiting for keys")
            : shortcut?.spoken ?? String(localized: "None", comment: "No shortcut")
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        startRecording()
        return true
    }
}

/// A shortcut field with two buttons beside it: one removes the shortcut, the other puts the
/// action's default shortcut back. They show while the pointer is over the field or them, or
/// while the field or one of them has the focus, and only when pressing them would change
/// something. To VoiceOver they are there whenever they would change something.
final class ShortcutControl: NSView {
    let field = Layout.size(ShortcutField(frame: .zero), NSSize(width: 196, height: 26))
    let resetButton: FocusButton
    let removeButton: FocusButton
    /// Called when one of the buttons is pressed.
    var onReset: (() -> Void)?
    var onRemove: (() -> Void)?

    /// The shortcut the field shows; set it here, so that the buttons follow.
    var shortcut: Shortcut? {
        get { field.shortcut }
        set {
            field.shortcut = newValue
            updateButtons()
        }
    }

    /// The action's default shortcut, which the reset button puts back.
    var defaultShortcut: Shortcut? {
        didSet { updateButtons() }
    }

    /// Whether the pointer is over the field or its buttons.
    private(set) var isHovered = false {
        didSet { if isHovered != oldValue { updateButtons() } }
    }
    private var fieldHasFocus = false
    /// With Full Keyboard Access, Tab moves on from the field to the buttons; one that has the
    /// focus must stay in sight.
    private var buttonHasFocus = false

    /// `title` is the action's, such as "Brightness up".
    init(title: String) {
        func button(_ symbol: String, _ action: Selector) -> FocusButton {
            let button = FocusButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: nil,
                action: action)
            button.isBordered = false
            button.contentTintColor = .tertiaryLabelColor
            return Layout.size(button, NSSize(width: 22, height: 22))
        }
        resetButton = button("arrow.counterclockwise.circle.fill", #selector(reset))
        removeButton = button("xmark.circle.fill", #selector(remove))
        super.init(frame: .zero)
        field.title = String(localized: "\(title) shortcut", comment: "An action, such as Volume up")
        removeButton.setAccessibilityLabel(String(localized: "Remove the \(title) shortcut"))
        removeButton.toolTip = String(localized: "Remove", comment: "Removes a shortcut")
        for button in [resetButton, removeButton] {
            button.target = self
            button.onFocusChange = { [unowned self] in
                buttonHasFocus = $0
                updateButtons()
            }
        }
        field.onFocusChange = { [unowned self] in
            fieldHasFocus = $0
            updateButtons()
        }

        let row = Layout.row([field, removeButton, resetButton], spacing: 2)
        row.setCustomSpacing(6, after: field)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutControl is created in code")
    }

    /// Whether each button would change something.
    var canReset: Bool { defaultShortcut != nil && shortcut != defaultShortcut }
    var canRemove: Bool { shortcut != nil }

    private func updateButtons() {
        let isShown = isHovered || fieldHasFocus || buttonHasFocus
        for (button, applies) in [(resetButton, canReset), (removeButton, canRemove)] {
            // Faded out rather than hidden, so that the field does not move.
            button.alphaValue = applies && isShown ? 1 : 0
            button.isEnabled = applies
            button.setAccessibilityElement(applies)
        }
        if let defaultShortcut {
            resetButton.setAccessibilityLabel(
                String(localized: "Put back the default shortcut, \(defaultShortcut.spoken)"))
            resetButton.toolTip = String(localized: "Put back \(defaultShortcut.symbols)", comment: "A shortcut")
        }
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    @objc private func reset() {
        onReset?()
    }

    @objc private func remove() {
        onRemove?()
    }
}

/// A button that says when it takes the keyboard's focus and when it gives it up.
final class FocusButton: NSButton {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

extension Shortcut {
    /// The shortcut a key press amounts to; nil when the key is not one a shortcut can use.
    init?(keyPress event: NSEvent) {
        self.init(keyCode: Int(event.keyCode), modifiers: Self.modifiers(of: event))
    }

    static func modifiers(of event: NSEvent) -> Modifiers {
        var modifiers: Modifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}
