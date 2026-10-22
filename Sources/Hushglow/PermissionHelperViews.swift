import AppKit

// The parts the permission helper is made of; see `PermissionHelper`.

/// A part of the helper that moves, and can be set moving again.
@MainActor
protocol Moving {
    func startMoving()
}

private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// The arrow above the icon, which moves gently up and down, towards the list.
final class ArrowView: NSImageView, Moving {
    override init(frame: NSRect) {
        super.init(frame: frame)
        image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
                    .applying(.init(paletteColors: [.white, .controlAccentColor])))
        setAccessibilityElement(false)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startMoving() }
    }

    func startMoving() {
        guard !reducesMotion, let layer else { return }
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -2
        bob.toValue = 3
        bob.duration = 0.7
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bob, forKey: "bob")
    }
}

/// The glow around the round glass, in the colours of the app's icon: it turns slowly and
/// breathes, and a ring spreads from it now and then. It is drawn by Core Animation, which
/// costs the app nothing while it runs.
final class AuraView: NSView, Moving {
    /// How far the glow reaches past the edge of the round glass.
    static let spread: CGFloat = 30
    private static let colours: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.52, blue: 0.24, alpha: 1),
        NSColor(srgbRed: 0.96, green: 0.34, blue: 0.56, alpha: 1),
        NSColor(srgbRed: 0.56, green: 0.38, blue: 0.94, alpha: 1),
    ]

    private let glow = CAGradientLayer()
    private let ring = CAShapeLayer()

    init(discRadius: CGFloat) {
        let radius = discRadius + Self.spread
        super.init(frame: NSRect(x: 0, y: 0, width: radius * 2, height: radius * 2))
        layer = CALayer()
        wantsLayer = true

        // The colours run around the centre; a second gradient lets them show only as a soft
        // band that is strongest at the edge of the glass and fades outwards.
        glow.type = .conic
        glow.frame = bounds
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 0.5, y: 0)
        glow.colors = (Self.colours + [Self.colours[0]]).map(\.cgColor)
        let band = CAGradientLayer()
        band.type = .radial
        band.frame = bounds
        band.startPoint = CGPoint(x: 0.5, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 1)
        let edge = discRadius / radius
        band.colors = [NSColor.clear, .clear, .black, .clear].map(\.cgColor)
        band.locations = [0, NSNumber(value: edge - 0.12), NSNumber(value: edge), 1]
        glow.mask = band
        layer?.addSublayer(glow)

        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: Self.spread, dy: Self.spread), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = Self.colours[0].cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { nil }

    /// The glow is for the eye only; clicks go to whatever is under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startMoving() }
    }

    func startMoving() {
        guard !reducesMotion else { return }
        func animation(_ keyPath: String, from: Double, to: Double, duration: Double, back: Bool) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.autoreverses = back
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: back ? .easeInEaseOut : .linear)
            return animation
        }
        glow.add(animation("transform.rotation.z", from: 0, to: 2 * .pi, duration: 7, back: false), forKey: "turn")
        glow.add(animation("opacity", from: 0.7, to: 1, duration: 1.3, back: true), forKey: "breathe")

        let spread = CAAnimationGroup()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1 + Self.spread / (bounds.width / 2 - Self.spread)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.8, 0]
        fade.keyTimes = [0, 0.12, 1]
        spread.animations = [grow, fade]
        spread.duration = 2.4
        spread.repeatCount = .infinity
        spread.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(spread, forKey: "spread")
    }
}

/// The app's icon, which can be dragged into the list in System Settings like the app itself
/// from the Finder.
final class AppIconDragView: NSView, NSDraggingSource {
    /// Room around the icon, which the round glass behind it shows through.
    var inset: CGFloat = 0
    private let icon = NSApplication.shared.applicationIconImage

    private var iconFrame: NSRect { bounds.insetBy(dx: inset, dy: inset) }

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: iconFrame)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(iconFrame, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? {
        String(localized: "\(AppInfo.name), to drag into the list in System Settings")
    }
}
