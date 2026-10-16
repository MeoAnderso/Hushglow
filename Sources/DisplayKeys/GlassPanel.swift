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

    /// A panel's content: `body` laid out inside it with Auto Layout, the given width, and as
    /// tall as `body` needs. When what it shows may have changed height, `fit(_:to:)` makes
    /// the window follow.
    static func content(_ body: NSView, width: CGFloat) -> FittedView {
        let content = FittedView(body: body, width: width)
        content.fit()
        return content
    }

    /// Makes a panel's window as tall as its content now needs, keeping its top edge in place.
    /// In a window the content takes its size from the glass around it, so the window is what
    /// is resized; without one, the content is.
    static func fit(_ window: NSWindow?, to content: FittedView) {
        guard let window, content.window == window else { return content.fit() }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittedSize))
        if frame.size != window.frame.size {
            let top = window.frame.maxY
            window.setFrame(
                NSRect(x: window.frame.minX, y: top - frame.height, width: frame.width, height: frame.height),
                display: true)
        }
        content.layoutSubtreeIfNeeded()
    }
}

/// A view that holds a body laid out with Auto Layout and knows the size the body asks for.
/// The glass around it gives it its frame, as it does any content view, so in a window it is
/// the window that is made to fit.
final class FittedView: NSView {
    private let width: CGFloat

    init(body: NSView, width: CGFloat) {
        self.width = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        // Just below required: for the moment between a change and the window taking the new
        // height, the frame and the body may disagree without that being an error.
        let bottom = body.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,
            body.widthAnchor.constraint(equalToConstant: width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FittedView is created in code")
    }

    override var isFlipped: Bool { true }

    /// The size the body needs as it now is.
    var fittedSize: NSSize {
        // A stack lets go of a view that was just hidden only when its constraints are next
        // brought up to date, so that comes first.
        updateConstraintsForSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        return NSSize(width: width, height: ceil(fittingSize.height))
    }

    /// Takes the size the body needs, and lays it out at once, so the frames of the parts are
    /// right as soon as this returns. For content that is in no window yet.
    func fit() {
        setFrameSize(fittedSize)
        layoutSubtreeIfNeeded()
    }
}

/// A faint rounded panel behind a group of rows. On glass, groups are set apart with a fill
/// like this one and not with more glass.
final class WellView: NSView {
    /// A panel with `content` laid inside it, `insets` from its edges.
    convenience init(around content: NSView, insets: NSEdgeInsets) {
        self.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: insets.right),
            bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: insets.bottom),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}

/// Stack and grid views as the panels use them.
@MainActor
enum Layout {
    static func column(
        _ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .leading
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    static func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    /// Text that wraps at the given width and is as tall as it needs.
    static func wrappingLabel(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    /// A view of a fixed size with `body` laid out to fill it.
    static func holder(_ body: NSView, size: NSSize) -> NSView {
        let holder = NSView(frame: NSRect(origin: .zero, size: size))
        body.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: holder.topAnchor),
            body.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        holder.layoutSubtreeIfNeeded()
        return holder
    }

    /// Gives a view a fixed size, for views that do not say how large they are.
    @discardableResult
    static func size<View: NSView>(_ view: View, _ size: NSSize) -> View {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size.width),
            view.heightAnchor.constraint(equalToConstant: size.height),
        ])
        return view
    }
}
