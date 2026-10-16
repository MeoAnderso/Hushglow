import AppKit

/// A helper that stays under the System Settings window while the user grants access: the
/// app's icon on a round piece of glass, to drag into the list there, with a caption beside
/// it. Dragging an app in adds it to the list, which nothing else does short of macOS's own
/// alert.
///
/// It goes with the Settings window, not with whichever app is in front, and goes away when
/// access is granted, when it is closed, or when the window has been gone for a while. How it
/// follows the window and why it looks as it does is in docs/DESIGN.md, under Liquid Glass.
@MainActor
final class PermissionHelper: NSObject {
    /// The size of what is seen: the arrow, the round glass and the caption.
    static let size = NSSize(width: 460, height: 132)
    /// Room for the glow, which reaches past the round glass on the left and below.
    static let glowMargin = AuraView.spread
    private static let settingsBundleID = "com.apple.systempreferences"
    /// The window is followed closely while it appears or moves, and loosely once it rests.
    private static let closeInterval: TimeInterval = 0.05
    private static let looseInterval: TimeInterval = 0.25
    private static let settleTime: TimeInterval = 1.5
    /// Long enough for System Settings to launch and put its window up.
    private static let launchTime: TimeInterval = 5
    /// How long the helper waits for the window to come back before giving up.
    private static let patience: TimeInterval = 120
    /// While it opens, the Settings window is briefly much smaller than it ends up.
    private static let smallestWindow = NSSize(width: 200, height: 150)
    /// The list fills the Settings window to the right of a sidebar about this wide.
    private static let sidebarWidth: CGFloat = 215
    private static let gap: CGFloat = 10

    private let onAddWithoutDragging: () -> Void
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastSeen = Date()
    private var followCloselyUntil = Date()
    private var settingsFrame: NSRect?

    init(onAddWithoutDragging: @escaping () -> Void) {
        self.onAddWithoutDragging = onAddWithoutDragging
    }

    func show() {
        if panel == nil { panel = makePanel() }
        lastSeen = Date()
        followCloselyUntil = Date().addingTimeInterval(Self.launchTime)
        settingsFrame = nil
        follow()
    }

    @objc func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Keeps the helper with the Settings window. Access itself is not read here: this runs
    /// many times a second, and the change notifications already say when it is granted.
    @objc private func follow() {
        guard let panel else { return }
        guard let settings = settingsWindow(),
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings.frame) })
        else {
            panel.orderOut(nil)
            settingsFrame = nil
            if Date().timeIntervalSince(lastSeen) > Self.patience { return dismiss() }
            return followAgain()
        }
        lastSeen = Date()
        if settings.frame != settingsFrame {
            settingsFrame = settings.frame
            followCloselyUntil = max(followCloselyUntil, Date().addingTimeInterval(Self.settleTime))
        }
        let frame = Self.panelFrame(around: Self.frame(under: settings.frame, visible: screen.visibleFrame))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible {
            log.notice("Showing the helper under the System Settings window")
            appear(panel, above: settings.number)
        } else if !settings.helperIsInFront {
            panel.order(.above, relativeTo: settings.number)
        }
        followAgain()
    }

    private func followAgain() {
        timer?.invalidate()
        let interval = Date() < followCloselyUntil ? Self.closeInterval : Self.looseInterval
        let timer = Timer(
            timeInterval: interval, target: self, selector: #selector(follow), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func appear(_ panel: NSPanel, above window: Int) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            return panel.order(.above, relativeTo: window)
        }
        panel.alphaValue = 0
        panel.order(.above, relativeTo: window)
        // A window that was off screen comes back with its animations stopped.
        for view in panel.contentView?.subviews ?? [] { (view as? Moving)?.startMoving() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    // MARK: The Settings window

    private struct SettingsWindow {
        let number: Int
        let frame: NSRect
        /// Whether the helper is already in front of it.
        let helperIsInFront: Bool
    }

    /// The largest ordinary window System Settings has on screen. Window frames and their
    /// order are readable without any permission.
    private func settingsWindow() -> SettingsWindow? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID)
        let pids = Set(apps.map(\.processIdentifier))
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard !pids.isEmpty, let primaryHeight = NSScreen.screens.first?.frame.height,
            let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        var helperSeen = false
        var found: SettingsWindow?
        // The list runs from the frontmost window to the one furthest back.
        for window in windows {
            let number = window[kCGWindowNumber as String] as? Int ?? 0
            if number == panel?.windowNumber {
                helperSeen = true
                continue
            }
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                window[kCGWindowLayer as String] as? Int == 0,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds),
                frame.width >= Self.smallestWindow.width, frame.height >= Self.smallestWindow.height,
                frame.width * frame.height > (found?.frame.width ?? 0) * (found?.frame.height ?? 0)
            else { continue }
            found = SettingsWindow(
                number: number, frame: Self.appKitFrame(frame, primaryHeight: primaryHeight),
                helperIsInFront: helperSeen)
        }
        return found
    }

    /// Where the helper goes: centred under the list, or over the window's lower edge when
    /// there is no room below it, and always within the screen.
    static func frame(under settings: NSRect, visible: NSRect) -> NSRect {
        let listWidth = max(settings.width - sidebarWidth, 0)
        var origin = NSPoint(
            x: settings.maxX - listWidth / 2 - size.width / 2, y: settings.minY - gap - size.height)
        if origin.y < visible.minY + gap { origin.y = max(settings.minY, visible.minY) + gap }
        origin.x = max(min(origin.x, visible.maxX - size.width - gap), visible.minX + gap)
        return NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    /// The panel's frame for a place found by `frame(under:visible:)`: larger by the room the
    /// glow needs on the left and below.
    static func panelFrame(around frame: NSRect) -> NSRect {
        NSRect(
            x: frame.minX - glowMargin, y: frame.minY - glowMargin, width: frame.width + glowMargin,
            height: frame.height + glowMargin)
    }

    /// Window lists measure from the top of the primary screen, AppKit from its bottom.
    static func appKitFrame(_ frame: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: Layout

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: Self.panelFrame(around: NSRect(origin: .zero, size: Self.size)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window shadow: it would be cast by the glow as well, and darken it.
        panel.hasShadow = false
        // An ordinary window, kept just above the Settings window: it then goes behind other
        // apps together with Settings. It never takes Settings' place in front, since the
        // drag has to end there.
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = makeContentView()
        return panel
    }

    /// The panel's content, also used on its own to check the layout in tests: the glow, an
    /// arrow, the icon on its round glass, and the caption on a capsule beside it. The rest is
    /// clear.
    func makeContentView() -> NSView {
        let discSide: CGFloat = 96
        let iconInset: CGFloat = 17
        let captionSize = NSSize(width: 348, height: 60)
        let left = Self.glowMargin
        let holder = FlippedView(frame: Self.panelFrame(around: NSRect(origin: .zero, size: Self.size)))
        let discOrigin = NSPoint(x: left, y: Self.size.height - discSide - 2)

        let aura = AuraView(discRadius: discSide / 2)
        aura.setFrameOrigin(NSPoint(x: discOrigin.x - AuraView.spread, y: discOrigin.y - AuraView.spread))
        holder.addSubview(aura)

        let arrow = ArrowView(frame: NSRect(x: left + discSide / 2 - 15, y: 0, width: 30, height: 30))
        holder.addSubview(arrow)

        let icon = AppIconDragView(frame: NSRect(x: 0, y: 0, width: discSide, height: discSide))
        icon.inset = iconInset
        let disc = GlassPanel.backing(for: icon, cornerRadius: discSide / 2)
        disc.setFrameOrigin(discOrigin)
        holder.addSubview(disc)

        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil) ?? NSImage(),
            target: self, action: #selector(dismiss))
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        close.setAccessibilityLabel("Close")
        Layout.size(close, NSSize(width: 20, height: 20))

        let other = NSButton(title: "", target: self, action: #selector(showOtherWays))
        other.bezelStyle = .helpButton
        other.controlSize = .small
        other.setAccessibilityLabel("Other ways to add \(AppInfo.name)")
        other.toolTip = "Other ways to add \(AppInfo.name)"

        func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
            let label = NSTextField(labelWithString: string)
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            // The capsule keeps its size; a longer caption is cut short, not the buttons.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
        }
        let lines = Layout.column(
            [
                text("Drag \(AppInfo.name) into the list above", size: 13, weight: .semibold, color: .labelColor),
                text("If it is already listed, switch it on.", size: 11, weight: .regular, color: .secondaryLabelColor),
            ], spacing: 2)
        let row = Layout.row([lines, other, close], spacing: 8)
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 12)
        let caption = Layout.holder(row, size: captionSize)

        let capsule = GlassPanel.backing(for: caption, cornerRadius: captionSize.height / 2)
        capsule.setFrameOrigin(NSPoint(x: left + discSide + 12, y: disc.frame.midY - captionSize.height / 2))
        holder.addSubview(capsule)
        return holder
    }

    @objc private func showOtherWays(_ sender: NSButton) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Add Without Dragging", action: #selector(addWithoutDragging), keyEquivalent: "")
        item.target = self
        item.toolTip = "macOS asks once and adds \(AppInfo.name) to the list, switched off."
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc func addWithoutDragging() {
        dismiss()
        onAddWithoutDragging()
    }
}
