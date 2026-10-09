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

/// The indicator's marks: an icon with either a segmented level bar, one segment per coarse
/// key step, or a short message when there is no level to show. The marks are light on a dark
/// capsule and dark on a light one, with a soft halo so they read over anything.
///
/// Every mark is a layer and the view draws nothing. The bar's glide between steps is one
/// layer changing its width, which Core Animation plays outside the app's process; drawn by
/// hand, each frame of it was sixteen clipped segments, a shadow and the text again.
final class OSDView: NSView {
    private static let segmentCount = Level.coarseSteps
    private static let iconLeft: CGFloat = 16
    private static let barLeft: CGFloat = 50
    private static let rightInset: CGFloat = 18
    private static let percentageWidth: CGFloat = 40
    private static let barHeight: CGFloat = 8
    private static let segmentGap: CGFloat = 2
    private static let segmentRadius: CGFloat = 2
    static let glideDuration: TimeInterval = 0.12
    static let glideKey = "glide"

    private(set) var indication = Indication.level(Feedback(kind: .brightness, fraction: 0))

    var showsPercentage = false {
        didSet { if showsPercentage != oldValue { update(glides: false) } }
    }

    /// Shows the unlit part of the bar more strongly, for the Increase Contrast setting.
    var isHighContrast = false {
        didSet { if isHighContrast != oldValue { update(glides: false) } }
    }

    private let icon = CALayer()
    /// The whole bar, unlit. It changes only with the room the bar has.
    private let track = CAShapeLayer()
    /// Cuts the lit layer down to the segments.
    private let bar = CALayer()
    private let segments = CAShapeLayer()
    /// The lit part: a plain rectangle that reaches from the bar's left end to the level.
    let lit = CALayer()
    private let percentage = TextMark()
    private let message = TextMark()

    private var symbols: [String: NSImage] = [:]
    private var shownSymbol: String?
    /// The width the segments were last laid out for.
    private var barWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The view hosts its layers: AppKit then never asks it to draw.
        layer = CALayer()
        wantsLayer = true
        bar.mask = segments
        bar.addSublayer(lit)
        lit.anchorPoint = .zero
        percentage.alignsRight = true
        for part in [icon, track, bar, percentage, message] { layer?.addSublayer(part) }
        update(glides: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OSDView is created in code")
    }

    func show(_ indication: Indication, animated: Bool) {
        let wasLevel: Bool
        if case .level = self.indication { wasLevel = true } else { wasLevel = false }
        self.indication = indication
        update(glides: animated && wasLevel)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        shownSymbol = nil
        update(glides: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        // Layers hold fixed colours, and so do the symbols made for them.
        symbols.removeAll()
        shownSymbol = nil
        update(glides: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        shownSymbol = nil
        update(glides: false)
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var ink: NSColor {
        isDark ? .white : NSColor(white: 0.08, alpha: 1)
    }

    /// Layers do not take their sharpness from the window by themselves.
    private var scale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: Layers

    /// Brings every layer in line with what is to be shown. Only the lit layer's width ever
    /// moves; everything else changes at once, where a layer left to itself would ease into
    /// each new value over a quarter of a second.
    private func update(glides: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let scale = scale
        for part in [track, segments] { part.contentsScale = scale }
        for part in [icon, track, lit, percentage, message] {
            part.shadowColor = (isDark ? NSColor.black : .white).cgColor
            part.shadowOpacity = isDark ? 0.55 : 0.7
            // Half the blur of 3 points the marks were drawn with: a layer counts it that way.
            part.shadowRadius = 1.5
            part.shadowOffset = CGSize(width: 0, height: -0.5)
        }
        showSymbol(scale: scale)

        guard case .level(let feedback) = indication else {
            for part in [track, bar, percentage] { part.isHidden = true }
            message.isHidden = false
            show(indication.message ?? "", in: message, size: 13, from: Self.barLeft, to: bounds.width, scale: scale)
            return
        }
        let isMuted = feedback.kind == .muted
        message.isHidden = true
        for part in [track, bar] { part.isHidden = false }
        percentage.isHidden = !showsPercentage
        if showsPercentage {
            let right = bounds.width - Self.rightInset + 4
            show(
                "\(isMuted ? 0 : feedback.percent)%", in: percentage, size: 12, digitsAlign: true,
                from: right - Self.percentageWidth - 4, to: right, scale: scale)
        }
        layOutBar()
        track.fillColor = ink.withAlphaComponent(isHighContrast ? 0.5 : 0.3).cgColor
        lit.backgroundColor = ink.withAlphaComponent(isMuted ? 0.4 : 1).cgColor
        fill(to: CGFloat(min(max(feedback.barPosition, 0), 1)), glides: glides)
    }

    private func showSymbol(scale: CGFloat) {
        let name = symbolName
        guard name != shownSymbol else { return }
        shownSymbol = name
        guard let image = symbol(named: name) else {
            icon.contents = nil
            return
        }
        icon.contentsScale = scale
        icon.contents = image.layerContents(forContentsScale: scale)
        icon.frame = CGRect(
            origin: CGPoint(x: Self.iconLeft, y: ((bounds.height - image.size.height) / 2).rounded()), size: image.size)
    }

    private func show(
        _ string: String, in mark: TextMark, size: CGFloat, digitsAlign: Bool = false, from left: CGFloat,
        to right: CGFloat, scale: CGFloat
    ) {
        let font =
            digitsAlign
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
            : NSFont.systemFont(ofSize: size, weight: .medium)
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: ink])
        // Where the text was drawn before, with whole points for the layer to lie on.
        let frame = CGRect(
            x: left, y: ((bounds.height - text.size().height) / 2).rounded(), width: right - left,
            height: text.size().height.rounded(.up))
        mark.show(text, in: frame, scale: scale)
    }

    /// The room the bar has: less when the percentage stands beside it.
    private var roomForBar: CGFloat {
        bounds.width - Self.barLeft - Self.rightInset - (showsPercentage ? Self.percentageWidth : 0)
    }

    private var segmentWidth: CGFloat {
        (roomForBar - Self.segmentGap * CGFloat(Self.segmentCount - 1)) / CGFloat(Self.segmentCount)
    }

    private func layOutBar() {
        let width = roomForBar
        let frame = CGRect(
            x: Self.barLeft, y: (bounds.height - Self.barHeight) / 2, width: max(width, 0), height: Self.barHeight)
        guard width != barWidth || bar.frame != frame else { return }
        barWidth = width
        let path = CGMutablePath()
        for index in 0..<Self.segmentCount {
            let segment = CGRect(
                x: CGFloat(index) * (segmentWidth + Self.segmentGap), y: 0, width: max(segmentWidth, 0),
                height: Self.barHeight)
            let radius = min(Self.segmentRadius, segment.width / 2)
            path.addRoundedRect(in: segment, cornerWidth: radius, cornerHeight: radius)
        }
        track.frame = frame
        bar.frame = frame
        segments.frame = bar.bounds
        track.path = path
        segments.path = path
    }

    /// How far the lit layer reaches for a level. Each segment is filled by its own share, so
    /// that a quarter step lights a quarter of a segment, and the gaps count for nothing. A
    /// whole number of segments ends with the last of them: the lit layer's halo would
    /// otherwise fall on the segment after it.
    private func litWidth(for fraction: CGFloat) -> CGFloat {
        let filled = fraction * CGFloat(Self.segmentCount)
        let whole = filled.rounded(.down)
        let pitch = segmentWidth + Self.segmentGap
        if filled > whole { return whole * pitch + (filled - whole) * segmentWidth }
        return max(whole * pitch - Self.segmentGap, 0)
    }

    private func fill(to fraction: CGFloat, glides: Bool) {
        let width = litWidth(for: fraction)
        // A glide that is cut short goes on from where it had got to.
        let from = lit.presentation()?.bounds.width ?? lit.bounds.width
        lit.bounds = CGRect(x: 0, y: 0, width: width, height: Self.barHeight)
        guard glides else { return lit.removeAnimation(forKey: Self.glideKey) }
        guard from != width else { return }
        let glide = CABasicAnimation(keyPath: "bounds.size.width")
        glide.fromValue = from
        glide.toValue = width
        glide.duration = Self.glideDuration
        glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        lit.add(glide, forKey: Self.glideKey)
    }

    // MARK: Symbols

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

/// A line of text as a layer. The text is drawn once, when it changes, into a picture that the
/// layer then holds. A text layer would write it too, but thinner than AppKit writes text in
/// a view, and the indicator is meant to look as it did when it was drawn.
private final class TextMark: CALayer {
    /// Whether the text ends at the layer's right edge instead of starting at its left one.
    var alignsRight = false
    private var shown: NSAttributedString?

    func show(_ text: NSAttributedString, in frame: CGRect, scale: CGFloat) {
        let isSamePicture = text == shown && scale == contentsScale && frame.size == bounds.size
        self.frame = frame
        guard !isSamePicture else { return }
        shown = text
        contentsScale = scale
        let alignsRight = alignsRight
        let picture = NSImage(size: frame.size, flipped: false) { box in
            text.draw(at: NSPoint(x: alignsRight ? box.maxX - text.size().width : 0, y: 0))
            return true
        }
        contents = picture.layerContents(forContentsScale: scale)
    }
}
