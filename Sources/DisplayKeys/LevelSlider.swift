import AppKit
import DisplayKeysCore

/// A slider for a menu row, made of layers, that tracks the mouse itself.
///
/// `NSSlider` is not used because of what a drag costs with it. It redraws on every mouse
/// event, inside a tracking loop that does not return to the app's event loop, so the
/// autorelease pool is not emptied and memory climbs for as long as the drag lasts: about
/// 10 MB a minute was measured. Two things are different here. Nothing is drawn: the track, the
/// filled part and the knob are layers, and a drag only moves them. And the tracking loop is
/// the slider's own, with an autorelease pool around each event.
final class LevelSlider: NSView {
    private static let knobSize = NSSize(width: 20, height: 15)
    private static let trackHeight: CGFloat = 6
    /// Nothing about the layers animates by itself: the knob has to stay under the mouse.
    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(),
        "borderWidth": NSNull(), "hidden": NSNull(),
    ]

    /// From 0 to 100.
    private(set) var value: Double = 0
    /// What the slider controls, read by VoiceOver.
    var name = ""
    /// Called with each new value that the mouse, the keyboard or VoiceOver produces.
    var onChange: ((Double) -> Void)?
    /// Whether the mouse has hold of the knob.
    private(set) var isDragging = false

    /// Shows the filled part without its colour, for a volume that is muted.
    var isDimmed = false {
        didSet { if isDimmed != oldValue { colour() } }
    }

    /// Outlines the track and the knob, for the Increase Contrast setting.
    var isHighContrast = false {
        didSet { if isHighContrast != oldValue { colour() } }
    }

    private let track = CALayer()
    private let filled = CALayer()
    private let knob = CALayer()
    /// The focus ring, which is a layer too so that showing it draws nothing.
    private let ring = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The view hosts its layers: AppKit then never asks it to draw.
        layer = CALayer()
        wantsLayer = true
        focusRingType = .none
        for part in [track, filled, ring, knob] {
            part.actions = Self.noActions
            layer?.addSublayer(part)
        }
        track.cornerRadius = Self.trackHeight / 2
        filled.cornerRadius = Self.trackHeight / 2
        knob.cornerRadius = Self.knobSize.height / 2
        knob.bounds = CGRect(origin: .zero, size: Self.knobSize)
        knob.shadowPath = CGPath(
            roundedRect: knob.bounds, cornerWidth: knob.cornerRadius, cornerHeight: knob.cornerRadius, transform: nil)
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        knob.shadowRadius = 1.5
        ring.bounds = knob.bounds.insetBy(dx: -3, dy: -3)
        ring.cornerRadius = ring.bounds.height / 2
        ring.borderWidth = 3
        ring.isHidden = true
        colour()
        place()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LevelSlider is created in code")
    }

    /// Moves the knob without telling anyone, for a value that comes from the display.
    func show(_ value: Double) {
        self.value = min(max(value, 0), 100)
        place()
    }

    // MARK: Layers

    /// How far the knob's centre stays from either end, so the whole knob stays inside.
    private var inset: CGFloat { Self.knobSize.width / 2 }
    private var travel: CGFloat { max(bounds.width - inset * 2, 1) }
    private var knobCentre: CGFloat { inset + CGFloat(value / 100) * travel }

    private func place() {
        let middle = bounds.midY
        track.frame = CGRect(
            x: 0, y: middle - Self.trackHeight / 2, width: bounds.width, height: Self.trackHeight)
        filled.frame = CGRect(x: 0, y: track.frame.minY, width: knobCentre, height: Self.trackHeight)
        knob.position = CGPoint(x: knobCentre, y: middle)
        ring.position = knob.position
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func viewDidChangeEffectiveAppearance() {
        colour()
    }

    /// Layers hold fixed colours, so the system's are read again whenever the appearance changes.
    private func colour() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            track.borderColor = NSColor.secondaryLabelColor.cgColor
            filled.backgroundColor = (isDimmed ? NSColor.tertiaryLabelColor : .controlAccentColor).cgColor
            knob.borderColor = (isHighContrast ? NSColor.labelColor : NSColor(white: 0, alpha: 0.12)).cgColor
            ring.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        }
        track.borderWidth = isHighContrast ? 1 : 0
        knob.backgroundColor = NSColor(white: isDark ? 0.86 : 1, alpha: 1).cgColor
        knob.borderWidth = isHighContrast ? 1 : isDark ? 0 : 0.5
        knob.shadowOpacity = isDark ? 0.5 : 0.25
    }

    // MARK: The mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        drag(from: event) {
            window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking,
                dequeue: true)
        }
    }

    /// Follows the mouse from a press until the button is let go. `next` waits for the mouse
    /// event that comes after, and it is where the window draws and the display is written to.
    func drag(from press: NSEvent, next: () -> NSEvent?) {
        let start = convert(press.locationInWindow, from: nil).x
        // A press on the knob takes it where it is; a press on the track brings the knob there.
        let grip = abs(start - knobCentre) <= Self.knobSize.width / 2 ? start - knobCentre : 0
        isDragging = true
        follow(start - grip)
        var isDown = true
        while isDown {
            // The pool is why this loop is here and not NSSlider's: what an event leaves
            // behind, in the handler and in the window's display pass, goes when it is done.
            autoreleasepool {
                guard let event = next(), event.type == .leftMouseDragged else {
                    isDown = false
                    return
                }
                follow(convert(event.locationInWindow, from: nil).x - grip)
            }
        }
        isDragging = false
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func follow(_ x: CGFloat) {
        change(to: Double((x - inset) / travel) * 100)
    }

    /// Takes a value from the user; one that changes nothing is not passed on.
    private func change(to newValue: Double) {
        let newValue = min(max(newValue, 0), 100)
        guard newValue != value else { return }
        value = newValue
        place()
        onChange?(newValue)
    }

    // MARK: Scrolling

    /// A scroll over the slider moves it, as one over macOS's own sliders does: a trackpad by
    /// the distance the fingers travel, sideways or up and down, and a mouse's wheel one step a
    /// notch. The glide that follows a swipe on a trackpad is left out, so that the knob stops
    /// where the fingers do.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        let points = Self.scrolled(
            x: event.scrollingDeltaX, y: event.scrollingDeltaY, isInverted: event.isDirectionInvertedFromDevice)
        guard points != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            change(to: value + Double(points / travel) * 100)
            if event.phase == .ended { NSAccessibility.post(element: self, notification: .valueChanged) }
        } else {
            step(up: points > 0)
        }
    }

    /// How far a scroll moves the slider, in points, more to the right or up: the larger of its
    /// two directions, as the fingers or the wheel went. The scrolling setting in System
    /// Settings turns the deltas round, and `isInverted` says when it has.
    static func scrolled(x: CGFloat, y: CGFloat, isInverted: Bool) -> CGFloat {
        let right = isInverted ? x : -x
        let up = isInverted ? -y : y
        return abs(right) > abs(up) ? right : up
    }

    // MARK: The keyboard

    /// As with the system's own controls, only with Full Keyboard Access. A menu gives the
    /// focus to the first view that takes it as soon as it opens.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }

    override func becomeFirstResponder() -> Bool {
        ring.isHidden = false
        return true
    }

    override func resignFirstResponder() -> Bool {
        ring.isHidden = true
        return true
    }

    /// Left and right step the level. Every other key is passed on: in a menu, up and down
    /// move between the items.
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow: step(up: false)
        case .rightArrow: step(up: true)
        default: super.keyDown(with: event)
        }
    }

    /// One step as the keys take it, on the same grid of sixteen.
    private func step(up: Bool) {
        let current = DDC.Value(current: Int(value.rounded()), maximum: 100)
        change(to: Double(Level.stepped(current, up: up, fine: false)))
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityOrientation() -> NSAccessibilityOrientation { .horizontal }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 100) }
    override func accessibilityValueDescription() -> String? {
        String(localized: "\(Int(value.rounded())) percent")
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let number = accessibilityValue as? NSNumber else { return }
        change(to: number.doubleValue)
    }

    override func accessibilityPerformIncrement() -> Bool {
        step(up: true)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        step(up: false)
        return true
    }
}
