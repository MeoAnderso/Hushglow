import AppKit

/// A floating glass panel, used for Settings and the notices: the whole window is one sheet of
/// Liquid Glass with the controls laid directly on it. On macOS before 26 a blurred material
/// stands in.
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
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let material = NSVisualEffectView(frame: content.frame)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        content.setFrameOrigin(.zero)
        material.addSubview(content)
        return material
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
