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
///
/// It grows into place and fades in as it appears, and shrinks a little and fades as it
/// leaves. Both are Core Animation, played outside the app's process; with Reduce Motion it
/// only fades. The capsule's shadow is a layer of its own for that reason: the window's
/// shadow would stay at full strength while what casts it faded.
@MainActor
final class OSD: NSObject {
    static let size = NSSize(width: 250, height: 44)
    private static let margin: CGFloat = 12
    /// Room around the capsule, inside the window, for its shadow.
    static let shadowRoom: CGFloat = 24
    private static let visibleDuration: TimeInterval = 1.5
    private static let appearDuration: TimeInterval = 0.15
    private static let fadeDuration: TimeInterval = 0.25
    /// How large the capsule starts as it appears, and ends as it leaves.
    static let appearScale: CGFloat = 0.9
    static let leaveScale: CGFloat = 0.96
    static let motionKey = "motion"
    static let fadeKey = "fade"
    static let nudgeKey = "nudge"
    static let shakeKey = "shake"
    /// The strength of the glass in the see-through style.
    private static let seeThroughOpacity: CGFloat = 0.55

    /// The menu bar item's frame on screen, for placing the indicator beneath it.
    var anchor: (() -> NSRect?)?

    private var panel: NSPanel?
    /// The panel's content: the capsule and its shadow, which appear and leave together.
    private(set) var stage: NSView?
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

        let opacity = stage?.layer.map { $0.presentation()?.opacity ?? $0.opacity } ?? 0
        let wasVisible = panel.isVisible && opacity > 0
        let moves = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        indicator.showsPercentage = IndicatorSettings.showsPercentage
        indicator.show(indication, animated: wasVisible && moves)

        let origin = restingOrigin()
        panel.setFrameOrigin(NSPoint(x: origin.x - Self.shadowRoom, y: origin.y - Self.shadowRoom))
        if !panel.isVisible { panel.orderFrontRegardless() }
        // From wherever a leaving that is under way has got to.
        appear(from: wasVisible ? opacity : 0, moves: moves)
        if moves { react(to: indication) }
        // Whatever was due for what was shown before is off, the end of its fade included.
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        if indication != held { leave(#selector(timeIsUp), after: Self.visibleDuration) }
    }

    /// Schedules a step of the indicator's leaving. It is scheduled for every mode of the
    /// run loop: an open menu keeps the run loop out of the default one, and an indicator
    /// that a key brought up meanwhile would otherwise stay until the menu closed.
    private func leave(_ step: Selector, after delay: TimeInterval) {
        perform(step, with: nil, afterDelay: delay, inModes: [.common])
    }

    /// The indication has been on screen long enough.
    @objc func timeIsUp() {
        if let held { show(held) } else { fadeOut() }
    }

    private func fadeOut() {
        guard let layer = stage?.layer else { return }
        let moves = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.add(Self.fade(from: from, to: 0, duration: Self.fadeDuration), forKey: Self.fadeKey)
        if moves {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = layer.presentation()?.transform ?? CATransform3DIdentity
            shrink.toValue = scaledAboutCentre(Self.leaveScale)
            shrink.duration = Self.fadeDuration
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Held at the end, until the panel goes; the model's transform stays the identity.
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: Self.motionKey)
        }
        CATransaction.commit()
        // The panel is taken away when the fade is over, unless something is shown before
        // then, which calls this off. The animation's own completion handler would do, but
        // with a menu open it is not called until the menu closes.
        leave(#selector(fadeIsOver), after: Self.fadeDuration)
    }

    /// Fades the capsule in and, unless motion is reduced, lets it grow into place on a spring.
    /// What is already fully there stays as it is.
    private func appear(from opacity: Float, moves: Bool) {
        guard let layer = stage?.layer else { return }
        let transform = layer.presentation()?.transform ?? CATransform3DIdentity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.removeAnimation(forKey: Self.fadeKey)
        layer.removeAnimation(forKey: Self.motionKey)
        // The presentation's opacity can stop a hair short of 1 at the end of a fade.
        if opacity < 0.99 {
            layer.add(Self.fade(from: opacity, to: 1, duration: Self.appearDuration), forKey: Self.fadeKey)
        }
        let start = opacity > 0 ? transform : scaledAboutCentre(Self.appearScale)
        if moves, !CATransform3DIsIdentity(start) {
            let grow = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.2)
            grow.keyPath = "transform"
            grow.fromValue = start
            grow.toValue = CATransform3DIdentity
            grow.duration = grow.settlingDuration
            layer.add(grow, forKey: Self.motionKey)
        }
        CATransaction.commit()
    }

    /// A step that met an end of the range nudges the capsule towards that end, where nothing
    /// happened at all before; one held there nudges it again each time the last nudge is
    /// over. A change the display refused shakes it, as macOS shakes a password it refuses.
    /// Both move it sideways on top of whatever else it is doing.
    private func react(to indication: Indication) {
        guard let layer = stage?.layer else { return }
        switch indication {
        case .level(let feedback):
            guard let end = feedback.pushedAgainst, layer.animation(forKey: Self.nudgeKey) == nil else { return }
            let toward: CGFloat = end == .top ? 1 : -1
            layer.add(Self.sideways([0, 5 * toward, 0], keyTimes: [0, 0.3, 1], duration: 0.32), forKey: Self.nudgeKey)
        case .refused:
            layer.add(
                Self.sideways(
                    [0, -9, 8, -6, 4, -2, 0], keyTimes: [0, 0.15, 0.32, 0.5, 0.67, 0.84, 1], duration: 0.45),
                forKey: Self.shakeKey)
        default:
            break
        }
    }

    static func sideways(_ offsets: [CGFloat], keyTimes: [NSNumber], duration: TimeInterval) -> CAKeyframeAnimation {
        let move = CAKeyframeAnimation(keyPath: "transform.translation.x")
        move.values = offsets
        move.keyTimes = keyTimes
        move.duration = duration
        move.isAdditive = true
        move.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(offsets.count - 1, 1))
        return move
    }

    private static func fade(from: Float, to: Float, duration: TimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: to > from ? .easeOut : .easeIn)
        return fade
    }

    /// A view's layer turns about its corner; the capsule is to grow and shrink about its middle.
    private func scaledAboutCentre(_ scale: CGFloat) -> CATransform3D {
        let middle = stage.map { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY) } ?? .zero
        var transform = CATransform3DMakeTranslation(middle.x, middle.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -middle.x, -middle.y, 0)
    }

    @objc private func fadeIsOver() {
        panel?.orderOut(nil)
        stage?.layer?.removeAnimation(forKey: Self.motionKey)
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
        let room = Self.shadowRoom
        let panelFrame = frame.insetBy(dx: -room, dy: -room).offsetBy(dx: room, dy: room)
        let panel = NSPanel(
            contentRect: panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The capsule casts a shadow of its own, which fades with it.
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let indicator = OSDView(frame: frame)
        indicator.isHighContrast = look.increasesContrast
        let stage = NSView(frame: panelFrame)
        stage.wantsLayer = true
        let capsuleFrame = frame.offsetBy(dx: room, dy: room)
        stage.addSubview(CapsuleShadow(frame: capsuleFrame))
        let capsule = Self.capsule(around: indicator, look: look)
        capsule.setFrameOrigin(capsuleFrame.origin)
        stage.addSubview(capsule)
        panel.contentView = stage
        self.panel = panel
        self.stage = stage
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

/// The shadow under the capsule, as the window's own would have cast it: soft and faint all
/// round and a little lower than the capsule, with a fine darker edge. It is cut away under
/// the capsule, which glass and the tints let show through.
final class CapsuleShadow: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let capsule = CGPath(
            roundedRect: bounds, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil)
        func shadow(radius: CGFloat, opacity: Float, offset: CGFloat) -> CALayer {
            let layer = CALayer()
            layer.frame = bounds
            layer.shadowPath = capsule
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = opacity
            layer.shadowRadius = radius
            layer.shadowOffset = CGSize(width: 0, height: -offset)
            return layer
        }
        let host = CALayer()
        host.frame = bounds
        host.addSublayer(shadow(radius: 8, opacity: 0.22, offset: 2))
        // The edge: a ring whose outer half shows, the inner one being cut away below.
        let edge = CAShapeLayer()
        edge.frame = bounds
        edge.path = capsule
        edge.fillColor = nil
        edge.strokeColor = NSColor(white: 0, alpha: 0.5).cgColor
        edge.lineWidth = 2
        host.addSublayer(edge)
        // Everything around the capsule, and nothing inside it. A mask counts only what lies
        // within its own frame, so it is given room for the whole shadow.
        let room = OSD.shadowRoom
        let outside = CAShapeLayer()
        outside.frame = bounds.insetBy(dx: -room, dy: -room)
        let around = CGMutablePath()
        around.addRect(outside.bounds)
        around.addPath(capsule, transform: CGAffineTransform(translationX: room, y: room))
        outside.path = around
        outside.fillRule = .evenOdd
        host.mask = outside
        // The view hosts its layers: AppKit then never asks it to draw.
        layer = host
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CapsuleShadow is created in code")
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
    static let glideKey = "glide"
    /// Core Animation files a transition under this key, whatever key it is added with.
    static let replaceKey = kCATransition
    static let popKey = "pop"

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
    /// The symbol on show, with the level its waves stand for when it has them.
    private(set) var shownSymbol: String?
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
        showSymbol(scale: scale, animated: glides)

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

    /// Puts up the symbol for what is shown. Muting and unmuting, while the indicator is on
    /// screen and things may move, trade the one speaker for the other with a crossfade and a
    /// small pop, as macOS replaces one symbol with another.
    private func showSymbol(scale: CGFloat, animated: Bool) {
        let (name, waves) = symbolName
        let key = waves.map { "\(name)@\($0)" } ?? name
        guard key != shownSymbol else { return }
        let previous = shownSymbol
        shownSymbol = key
        guard let image = symbol(named: name, waves: waves, key: key) else {
            icon.contents = nil
            return
        }
        icon.contentsScale = scale
        icon.contents = image.layerContents(forContentsScale: scale)
        icon.frame = CGRect(
            origin: CGPoint(x: Self.iconLeft, y: ((bounds.height - image.size.height) / 2).rounded()), size: image.size)
        guard animated, let previous, Self.isSpeaker(previous), Self.isSpeaker(key),
            previous.hasPrefix(Self.mutedSpeaker) != key.hasPrefix(Self.mutedSpeaker)
        else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        icon.add(fade, forKey: Self.replaceKey)
        let pop = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.35)
        pop.keyPath = "transform.scale"
        pop.fromValue = 0.6
        pop.toValue = 1
        pop.duration = pop.settlingDuration
        icon.add(pop, forKey: Self.popKey)
    }

    private static let mutedSpeaker = "speaker.slash"

    private static func isSpeaker(_ key: String) -> Bool {
        key.hasPrefix("speaker.")
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
        let isGliding = lit.animation(forKey: Self.glideKey) != nil
        lit.bounds = CGRect(x: 0, y: 0, width: width, height: Self.barHeight)
        guard glides else { return lit.removeAnimation(forKey: Self.glideKey) }
        guard from != width else { return }
        lit.add(Self.glide(from: from, to: width, interrupting: isGliding), forKey: Self.glideKey)
    }

    /// The spring a step glides on: brisk, with a little give at the end. One that cuts into a
    /// glide still under way has none, so that a held key moves the bar along steadily rather
    /// than in a row of bounces.
    static func glide(from: CGFloat, to: CGFloat, interrupting: Bool) -> CASpringAnimation {
        let glide = CASpringAnimation(perceptualDuration: 0.25, bounce: interrupting ? 0 : 0.2)
        glide.keyPath = "bounds.size.width"
        glide.fromValue = from
        glide.toValue = to
        glide.duration = glide.settlingDuration
        return glide
    }

    // MARK: Symbols

    /// The symbol for what is shown, and for the volume how many of its three waves are lit.
    /// The speaker keeps its width at every level: the waves it does not light are there,
    /// faint, as in macOS's own volume indicator.
    private var symbolName: (name: String, waves: Int?) {
        switch indication {
        case .refused: return ("lock.fill", nil)
        case .noDisplay: return ("display.trianglebadge.exclamationmark", nil)
        case .watchingKeys: return ("keyboard", nil)
        case .unsupported(.brightness): return ("sun.max", nil)
        case .unsupported(.volume): return ("speaker.slash", nil)
        case .level(let feedback):
            switch feedback.kind {
            case .brightness: return ("sun.max.fill", nil)
            case .muted: return ("speaker.slash.fill", nil)
            case .volume: return ("speaker.wave.3.fill", Self.litWaves(for: feedback.fraction))
            }
        }
    }

    /// How many waves a volume lights: none when silent, all three from two thirds up.
    static func litWaves(for fraction: Double) -> Int {
        switch fraction {
        case ...0: 0
        case ..<0.34: 1
        case ..<0.67: 2
        default: 3
        }
    }

    private func symbol(named name: String, waves: Int?, key: String) -> NSImage? {
        if let cached = symbols[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        let image: NSImage? =
            if let waves {
                // The symbol lights a wave above 0, a second above a third and the last above
                // two thirds; these values keep clear of those edges.
                NSImage(
                    systemSymbolName: name, variableValue: [0, 0.2, 0.5, 1][waves], accessibilityDescription: nil)
            } else {
                NSImage(systemSymbolName: name, accessibilityDescription: nil)
            }
        symbols[key] = image?.withSymbolConfiguration(configuration)
        return symbols[key]
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
