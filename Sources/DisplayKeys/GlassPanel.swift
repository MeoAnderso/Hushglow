import AppKit

/// A floating glass panel, used for Settings and the notices: the whole window is one sheet of
/// Liquid Glass with the controls laid directly on it.
@MainActor
enum GlassPanel {
    /// Room to leave at the top of a panel's content for the title bar, which sits over it.
    static let titleBarHeight: CGFloat = 28
    private static let cornerRadius: CGFloat = 16

    static func makeWindow(title: String, content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: content.frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = backing(for: content)
        window.center()
        return window
    }

    /// The sheet of glass, with the content inside it where AppKit expects content to be.
    static func backing(for content: NSView, cornerRadius: CGFloat = cornerRadius) -> NSView {
        let glass = NSGlassEffectView(frame: content.frame)
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }
}

/// A faint rounded panel behind a group of rows. On glass, groups are set apart with a fill
/// like this one and not with more glass.
final class WellView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}
