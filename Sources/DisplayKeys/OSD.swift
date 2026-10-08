import AppKit
import DisplayKeysCore

/// What decides how the indicator's capsule is built: the user's choice of style and the
/// system's accessibility options. It is evaluated each time the indicator is shown.
struct IndicatorLook: Equatable {
    var style: IndicatorSettings.Style
    var reducesTransparency: Bool
    var increasesContrast: Bool

    @MainActor static var current: IndicatorLook {
        IndicatorLook(
            style: IndicatorSettings.style,
            reducesTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increasesContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }
}

/// The on-screen indicator: a small non-activating capsule, drawn by the app itself because
/// the system indicator is private and changes between macOS releases. It is created on first
/// use and uses one-shot delays, so it costs nothing while idle.
@MainActor
final class OSD: NSObject {
    static let size = NSSize(width: 250, height: 44)
    private static let margin: CGFloat = 12
    private static let visibleDuration: TimeInterval = 1.5
    private static let appearDuration: TimeInterval = 0.15
    private static let fadeDuration: TimeInterval = 0.25
    /// How far the capsule travels as it appears.
    private static let slide: CGFloat = 6
    /// The strength of the glass in the see-through style.
    private static let seeThroughOpacity: CGFloat = 0.55

    /// The menu bar item's frame on screen, for placing the indicator beneath it.
    var anchor: (() -> NSRect?)?

    private var panel: NSPanel?
    private var indicator: OSDView?
    private var look: IndicatorLook?
    /// What stays on screen for as long as its cause lasts, whenever nothing newer is shown.
    private var held: Indication?

    /// What the indicator shows, or showed last.
    var shown: Indication? { indicator?.indication }
    var isOnScreen: Bool { panel?.isVisible == true }

    /// Shows an indication and keeps it there until it is released. Anything shown in the
    /// meantime takes its place for a moment and then gives it back.
    func hold(_ indication: Indication) {
        held = indication
        show(indication)
    }

    func release(_ indication: Indication) {
        guard held == indication else { return }
        held = nil
        // Something newer keeps the time it has left; what was held goes at once.
        guard shown == indication else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(timeIsUp), object: nil)
        fadeOut()
    }

    func show(_ indication: Indication) {
        let look = IndicatorLook.current
        if look != self.look { rebuild(for: look) }
        guard let panel, let indicator else { return }

        let wasVisible = panel.isVisible && panel.alphaValue > 0
        let moves = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        indicator.showsPercentage = IndicatorSettings.showsPercentage
        indicator.show(indication, animated: wasVisible && moves)

        let frame = NSRect(origin: restingOrigin(), size: Self.size)
        if wasVisible {
            panel.setFrame(frame, display: true)
            // Replaces a fade that may be in flight.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 0
            panel.setFrame(moves ? frame.offsetBy(dx: 0, dy: Self.slide) : frame, display: true)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.appearDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }
        }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(timeIsUp), object: nil)
        if indication != held { perform(#selector(timeIsUp), with: nil, afterDelay: Self.visibleDuration) }
    }

    /// The indication has been on screen long enough.
    @objc func timeIsUp() {
        if let held { show(held) } else { fadeOut() }
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            },
            completionHandler: {
                MainActor.assumeIsolated {
                    // A key press during the fade brings the panel back; leave it on screen then.
                    if panel.alphaValue == 0 { panel.orderOut(nil) }
                }
            })
    }

    /// Under the menu bar item when that is asked for and its position is known, as macOS does
    /// with its own indicators; otherwise the top-right corner of the screen in use.
    private func restingOrigin() -> NSPoint {
        if IndicatorSettings.position == .underMenuBarIcon, let anchor = anchor?(),
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
        {
            let area = screen.visibleFrame
            let x = anchor.midX - Self.size.width / 2
            return NSPoint(
                x: min(max(x, area.minX + Self.margin), area.maxX - Self.size.width - Self.margin),
                y: area.maxY - Self.size.height - Self.margin)
        }
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(x: area.maxX - Self.size.width - Self.margin, y: area.maxY - Self.size.height - Self.margin)
    }

    private func rebuild(for look: IndicatorLook) {
        panel?.orderOut(nil)
        let frame = NSRect(origin: .zero, size: Self.size)
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let indicator = OSDView(frame: frame)
        indicator.isHighContrast = look.increasesContrast
        panel.contentView = Self.capsule(around: indicator, look: look)
        self.panel = panel
        self.indicator = indicator
        self.look = look
    }

    // MARK: The capsule

    /// Builds the capsule behind the indicator's marks.
    static func capsule(around indicator: OSDView, look: IndicatorLook) -> NSView {
        let frame = indicator.frame
        let holder = NSView(frame: frame)
        var rim: (width: CGFloat, alpha: CGFloat)?

        if look.reducesTransparency {
            holder.addSubview(fill(frame, NSColor(white: 0.12, alpha: 1)))
            holder.appearance = NSAppearance(named: .darkAqua)
            rim = (1, 0.25)
        } else {
            switch look.style {
            case .glass:
                // The marks go inside the glass, where AppKit expects content to be.
                let glass = glassCapsule(frame)
                glass.contentView = indicator
                holder.addSubview(glass)
            case .seeThrough:
                let glass = glassCapsule(frame)
                glass.alphaValue = seeThroughOpacity
                holder.addSubview(glass)
            case .plain:
                holder.addSubview(fill(frame, NSColor(white: 0, alpha: 0.38)))
                holder.appearance = NSAppearance(named: .darkAqua)
                rim = (1, 0.28)
            }
        }
        if look.increasesContrast { rim = (1.5, 0.75) }

        if indicator.superview == nil { holder.addSubview(indicator) }
        if let rim {
            let outline = NSView(frame: frame)
            outline.wantsLayer = true
            outline.layer?.cornerRadius = frame.height / 2
            outline.layer?.borderWidth = rim.width
            outline.layer?.borderColor = NSColor(white: 1, alpha: rim.alpha).cgColor
            holder.addSubview(outline)
        }
        return holder
    }

    private static func glassCapsule(_ frame: NSRect) -> NSGlassEffectView {
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = frame.height / 2
        return glass
    }

    private static func fill(_ frame: NSRect, _ color: NSColor) -> NSView {
        let view = NSView(frame: frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = frame.height / 2
        return view
    }
}

/// Draws the indicator's marks: an icon with either a segmented level bar, one segment per
/// coarse key step, or a short message when there is no level to show. The marks are light on
/// a dark capsule and dark on a light one, with a soft halo so they read over anything.
final class OSDView: NSView {
    private static let segmentCount = Level.coarseSteps
    private static let iconLeft: CGFloat = 16
    private static let barLeft: CGFloat = 50
    private static let rightInset: CGFloat = 18
    private static let percentageWidth: CGFloat = 40
    private static let barHeight: CGFloat = 8
    private static let segmentGap: CGFloat = 2
    private static let glideDuration: TimeInterval = 0.12

    private(set) var indication = Indication.level(Feedback(kind: .brightness, fraction: 0))
    var showsPercentage = false
    /// Draws the unlit part of the bar more strongly, for the Increase Contrast setting.
    var isHighContrast = false

    /// The level the bar is drawn at; animated so the bar glides between steps.
    @objc private dynamic var shownFraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    private var symbols: [String: NSImage] = [:]

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "shownFraction" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    func show(_ indication: Indication, animated: Bool) {
        let wasLevel: Bool
        if case .level = self.indication { wasLevel = true } else { wasLevel = false }
        self.indication = indication
        needsDisplay = true
        guard case .level(let feedback) = indication else { return }

        let target = CGFloat(min(max(feedback.barPosition, 0), 1))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && wasLevel ? Self.glideDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().shownFraction = target
        }
        if !(animated && wasLevel) { shownFraction = target }
    }

    override func viewDidChangeEffectiveAppearance() {
        symbols.removeAll()
        needsDisplay = true
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var ink: NSColor {
        isDark ? .white : NSColor(white: 0.08, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let halo = NSShadow()
        halo.shadowColor = isDark ? NSColor(white: 0, alpha: 0.55) : NSColor(white: 1, alpha: 0.7)
        halo.shadowBlurRadius = 3
        halo.shadowOffset = NSSize(width: 0, height: -0.5)
        halo.set()

        if let image = symbol(named: symbolName) {
            let origin = NSPoint(x: Self.iconLeft, y: ((bounds.height - image.size.height) / 2).rounded())
            image.draw(in: NSRect(origin: origin, size: image.size))
        }
        if case .level(let feedback) = indication {
            drawBar(isMuted: feedback.kind == .muted)
            if showsPercentage { drawPercentage(feedback.kind == .muted ? 0 : feedback.percent) }
        } else if let message = indication.message {
            drawMessage(message)
        }
    }

    private func drawBar(isMuted: Bool) {
        let right = Self.rightInset + (showsPercentage ? Self.percentageWidth : 0)
        let barWidth = bounds.width - Self.barLeft - right
        let gaps = Self.segmentGap * CGFloat(Self.segmentCount - 1)
        let segmentWidth = (barWidth - gaps) / CGFloat(Self.segmentCount)
        let filled = shownFraction * CGFloat(Self.segmentCount)
        let litColor = ink.withAlphaComponent(isMuted ? 0.4 : 1)
        let unlitColor = ink.withAlphaComponent(isHighContrast ? 0.5 : 0.3)

        for index in 0..<Self.segmentCount {
            let segment = NSRect(
                x: Self.barLeft + CGFloat(index) * (segmentWidth + Self.segmentGap),
                y: (bounds.height - Self.barHeight) / 2,
                width: segmentWidth,
                height: Self.barHeight)
            let path = NSBezierPath(roundedRect: segment, xRadius: 2, yRadius: 2)
            unlitColor.setFill()
            path.fill()

            // Quarter steps, and the glide between steps, fill a segment partially.
            let amount = min(max(filled - CGFloat(index), 0), 1)
            guard amount > 0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            litColor.setFill()
            NSRect(x: segment.minX, y: segment.minY, width: segment.width * amount, height: segment.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawPercentage(_ percent: Int) {
        let text = NSAttributedString(
            string: "\(percent)%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: ink,
            ])
        let size = text.size()
        text.draw(
            at: NSPoint(
                x: bounds.width - Self.rightInset + 4 - size.width, y: ((bounds.height - size.height) / 2).rounded()))
    }

    private func drawMessage(_ text: String) {
        let message = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink])
        let size = message.size()
        message.draw(at: NSPoint(x: Self.barLeft, y: ((bounds.height - size.height) / 2).rounded()))
    }

    private var symbolName: String {
        switch indication {
        case .refused: return "lock.fill"
        case .noDisplay: return "display.trianglebadge.exclamationmark"
        case .watchingKeys: return "keyboard"
        case .unsupported(.brightness): return "sun.max"
        case .unsupported(.volume): return "speaker.slash"
        case .level(let feedback):
            switch feedback.kind {
            case .brightness: return "sun.max.fill"
            case .muted: return "speaker.slash.fill"
            case .volume:
                switch feedback.fraction {
                case ...0: return "speaker.fill"
                case ..<0.34: return "speaker.wave.1.fill"
                case ..<0.67: return "speaker.wave.2.fill"
                default: return "speaker.wave.3.fill"
                }
            }
        }
    }

    private func symbol(named name: String) -> NSImage? {
        if let cached = symbols[name] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbols[name] = image
        return image
    }
}
