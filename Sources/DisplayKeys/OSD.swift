import AppKit
import DisplayKeysCore

/// The on-screen indicator: a small non-activating panel in the top-right corner, drawn by
/// the app itself because the system indicator is private and changes between macOS releases.
/// It is created on first use and uses a one-shot delay to hide, so it costs nothing while idle.
@MainActor
final class OSD: NSObject {
    static let size = NSSize(width: 250, height: 44)
    private static let margin: CGFloat = 12
    private static let visibleDuration: TimeInterval = 1.5
    private static let fadeDuration: TimeInterval = 0.25

    private var panel: NSPanel?
    private var indicator: OSDView?

    func show(_ indication: Indication) {
        let panel = panel ?? makePanel()
        indicator?.indication = indication
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: area.maxX - Self.size.width - Self.margin,
                    y: area.maxY - Self.size.height - Self.margin))
        }
        // Replaces a fade that may be in flight.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fadeOut), object: nil)
        perform(#selector(fadeOut), with: nil, afterDelay: Self.visibleDuration)
    }

    @objc private func fadeOut() {
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

    private func makePanel() -> NSPanel {
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

        let background = NSVisualEffectView(frame: frame)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.maskImage = Self.capsuleMask(height: frame.height)

        let indicator = OSDView(frame: frame)
        background.addSubview(indicator)
        panel.contentView = background
        self.panel = panel
        self.indicator = indicator
        return panel
    }

    private static func capsuleMask(height: CGFloat) -> NSImage {
        let radius = height / 2
        let image = NSImage(size: NSSize(width: height + 1, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: 0, left: radius, bottom: 0, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Draws an icon with either a segmented level bar, one segment per coarse key step, or a
/// short message when there is no level to show.
final class OSDView: NSView {
    private static let segmentCount = Level.coarseSteps
    private static let iconLeft: CGFloat = 16
    private static let barLeft: CGFloat = 50
    private static let barRight: CGFloat = 18
    private static let barHeight: CGFloat = 8
    private static let segmentGap: CGFloat = 2

    var indication = Indication.level(Feedback(kind: .brightness, fraction: 0)) {
        didSet { if indication != oldValue { needsDisplay = true } }
    }

    private var symbols: [String: NSImage] = [:]

    override func draw(_ dirtyRect: NSRect) {
        if let image = symbol(named: symbolName) {
            let origin = NSPoint(x: Self.iconLeft, y: ((bounds.height - image.size.height) / 2).rounded())
            image.draw(in: NSRect(origin: origin, size: image.size))
        }
        switch indication {
        case .level(let feedback): drawBar(feedback)
        case .refused(let control): drawMessage("\(control.rawValue.capitalized) is locked")
        case .unsupported(let control): drawMessage("No \(control.rawValue) control")
        case .noDisplay: drawMessage("No display to control")
        }
    }

    private func drawBar(_ feedback: Feedback) {
        let barWidth = bounds.width - Self.barLeft - Self.barRight
        let gaps = Self.segmentGap * CGFloat(Self.segmentCount - 1)
        let segmentWidth = (barWidth - gaps) / CGFloat(Self.segmentCount)
        let filled = min(max(feedback.fraction, 0), 1) * Double(Self.segmentCount)
        let fillColor = NSColor.white.withAlphaComponent(feedback.kind == .muted ? 0.4 : 0.95)

        for index in 0..<Self.segmentCount {
            let segment = NSRect(
                x: Self.barLeft + CGFloat(index) * (segmentWidth + Self.segmentGap),
                y: (bounds.height - Self.barHeight) / 2,
                width: segmentWidth,
                height: Self.barHeight)
            let path = NSBezierPath(roundedRect: segment, xRadius: 2, yRadius: 2)
            NSColor.white.withAlphaComponent(0.22).setFill()
            path.fill()

            // Quarter steps fill a segment partially.
            let amount = min(max(filled - Double(index), 0), 1)
            guard amount > 0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            fillColor.setFill()
            NSRect(x: segment.minX, y: segment.minY, width: segment.width * amount, height: segment.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawMessage(_ text: String) {
        let message = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            ])
        let size = message.size()
        message.draw(at: NSPoint(x: Self.barLeft, y: ((bounds.height - size.height) / 2).rounded()))
    }

    private var symbolName: String {
        switch indication {
        case .refused: return "lock.fill"
        case .noDisplay: return "display.trianglebadge.exclamationmark"
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
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbols[name] = image
        return image
    }
}
