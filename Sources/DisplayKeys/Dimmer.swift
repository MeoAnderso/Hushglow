import AppKit
import DisplayKeysCore

/// Dims screens below their displays' lowest brightness, with a black window over each that
/// lets every click through. The window is left out of screenshots and recordings, which
/// show the screen as it is, and it goes with the app.
@MainActor
final class Dimmer {
    /// One overlay per dimmed screen, by the screen's display number.
    private var overlays: [CGDirectDisplayID: NSWindow] = [:]
    private static let fadeKey = "fade"

    /// How dark a number of dimming steps makes the screen.
    static func opacity(for dimming: Int) -> Float {
        Float(min(max(dimming, 0), Level.dimSteps)) * Float(Level.dimPerStep)
    }

    /// Dims each of these screens by its number of steps, and lets every other screen go.
    func dim(_ screens: [(screen: NSScreen, dimming: Int)]) {
        let wanted = Dictionary(
            screens.compactMap { item in item.screen.number.map { ($0, item) } },
            uniquingKeysWith: { first, _ in first })
        for (number, overlay) in overlays where (wanted[number]?.dimming ?? 0) == 0 {
            fade(overlay, to: 0)
            overlays[number] = nil
            // Taken away once it has faded.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { overlay.orderOut(nil) }
        }
        for (number, item) in wanted where item.dimming > 0 {
            let overlay = overlays[number] ?? makeOverlay()
            overlays[number] = overlay
            overlay.setFrame(item.screen.frame, display: false)
            if !overlay.isVisible { overlay.orderFrontRegardless() }
            fade(overlay, to: Self.opacity(for: item.dimming))
        }
    }

    /// Whether a screen is dimmed, for tests.
    func isDimming(_ screen: NSScreen) -> Bool {
        screen.number.map { overlays[$0] != nil } ?? false
    }

    private func makeOverlay() -> NSWindow {
        let overlay = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        // Over everything but the indicator, which shows how far the screen is dimmed.
        overlay.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        overlay.sharingType = .none
        overlay.animationBehavior = .none
        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.cgColor
        shade.layer?.opacity = 0
        overlay.contentView = shade
        return overlay
    }

    /// Changes how dark the overlay is with a short fade, which Core Animation plays.
    private func fade(_ overlay: NSWindow, to opacity: Float) {
        guard let layer = overlay.contentView?.layer else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = opacity
        fade.duration = 0.2
        layer.add(fade, forKey: Self.fadeKey)
        CATransaction.commit()
    }
}
