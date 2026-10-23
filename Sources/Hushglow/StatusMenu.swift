import AppKit
import HushglowCore

/// A display under control, as the menu shows it.
struct MenuDisplay: Equatable {
    typealias ID = ObjectIdentifier
    var id: ID
    /// The name macOS shows for it.
    var name: String
    var state: DisplayState
}

/// What the menu needs from the app.
@MainActor
protocol StatusMenuHost: AnyObject {
    /// The displays under control, in the order they were found.
    var menuDisplays: [MenuDisplay] { get }
    /// The display the menu bar icon speaks for: the one sound plays through, else the first.
    var displayState: DisplayState? { get }
    var displayControlIsAvailable: Bool { get }
    var keyboardKeysAreActive: Bool { get }
    /// Applies a command to one display, or to all of them when none is given.
    func run(_ command: Command, showOSD: Bool, on display: MenuDisplay.ID?)
    /// A scroll over the menu bar icon asked for a brightness step, in the menu bar of this screen.
    func stepBrightness(up: Bool, fromMenuBarOf screen: NSScreen?)
    /// Reads the displays' values again, without looking for the displays afresh.
    func readDisplays()
    /// Reads again whether the keyboard's own keys are allowed.
    func refreshKeyboardAccess()
    func enableKeyboardKeys()
    func showSettings()
    /// Whether this build can update itself, which puts "Check for Updates…" in the menu.
    var updatesAreAvailable: Bool { get }
    func checkForUpdates()
    /// The menu has opened or closed.
    func menuDidChange(isOpen: Bool)
}

/// The menu bar item: sliders for mouse control, plus status and the way into Settings.
/// The menu's contents are built the first time it opens and refreshed each time after;
/// a menu that is never opened costs nothing beyond its icon.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private unowned let host: any StatusMenuHost
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var controls: MenuControls?

    /// Whether the icon shows the display as muted.
    private var showsMuted = false
    private var scrolling = ScrollSteps()
    private var scrollMonitor: Any?

    init(host: any StatusMenuHost) {
        self.host = host
        super.init()
        item.button?.image = Self.icon(muted: false)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        // The icon's window is the app's own, so scrolls over it come to the app, whichever app
        // is in front, and need no permission. Every other scroll goes on as it was.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Monitors are called on the main thread, with the event the app is handing out.
            nonisolated(unsafe) let event = event
            let isTaken = MainActor.assumeIsolated { self?.take(event) ?? false }
            return isTaken ? nil : event
        }
    }

    /// Takes a scroll over the icon; false for any other.
    private func take(_ event: NSEvent) -> Bool {
        guard let window = item.button?.window, event.window === window else { return false }
        scrolled(event, in: window)
        return true
    }

    /// A scroll over the icon steps the brightness, as one over a slider moves it.
    private func scrolled(_ event: NSEvent, in window: NSWindow) {
        guard event.momentumPhase.isEmpty else { return }
        let points = LevelSlider.scrolled(
            x: event.scrollingDeltaX, y: event.scrollingDeltaY, isInverted: event.isDirectionInvertedFromDevice)
        let steps = scrolling.steps(for: points, isPrecise: event.hasPreciseScrollingDeltas)
        for _ in 0..<abs(steps) { host.stepBrightness(up: steps > 0, fromMenuBarOf: window.screen) }
        if event.phase == .ended { scrolling = ScrollSteps() }
    }

    /// Where the menu bar item is on screen, for placing the indicator beneath it.
    var itemFrame: NSRect? {
        guard let window = item.button?.window, window.frame.width > 0 else { return nil }
        return window.frame
    }

    func menuWillOpen(_ menu: NSMenu) {
        host.menuDidChange(isOpen: true)
        // Values changed with the display's own buttons are picked up here.
        host.readDisplays()
        // So is access granted in System Settings, should its notifications ever go missing.
        host.refreshKeyboardAccess()
    }

    func menuDidClose(_ menu: NSMenu) {
        host.menuDidChange(isOpen: false)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let controls = controls ?? build(menu)
        controls.update()
        // A display came or went since the menu was last open.
        let items = controls.items + fixedItems
        if menu.items != items { menu.items = items }
    }

    /// Called when the displays were re-read.
    func displaysChanged() {
        updateIcon()
        controls?.update()
    }

    /// Called when a key, a shortcut or the command line has changed a level.
    func levelsChanged() {
        controls?.levelsChanged()
    }

    /// The icon dims while there is nothing to control, and shows a muted display.
    func updateIcon() {
        item.button?.appearsDisabled = host.displayState == nil
        let muted = host.displayState?.isMuted == true
        guard muted != showsMuted else { return }
        showsMuted = muted
        item.button?.image = Self.icon(muted: muted)
    }

    /// The moon over the haze, as on the app's icon; for a muted display, with a crossed-out
    /// speaker cut into its lower right corner. A template, so that the menu bar gives it its colour.
    static func icon(muted: Bool) -> NSImage {
        let description = muted ? String(localized: "\(AppInfo.name), display muted") : AppInfo.name
        guard let moon = NSImage(systemSymbolName: "moon.haze.fill", accessibilityDescription: description) else {
            return NSImage(systemSymbolName: "moon.fill", accessibilityDescription: description) ?? NSImage()
        }
        guard muted,
            let speaker = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: (moon.size.height * 0.42).rounded(), weight: .semibold))
        else { return moon }
        let icon = NSImage(size: moon.size, flipped: false) { bounds in
            moon.draw(in: bounds)
            let badge = NSRect(
                x: bounds.maxX - speaker.size.width, y: bounds.minY, width: speaker.size.width,
                height: speaker.size.height)
            // A gap round the speaker, so that it reads apart from the moon.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(roundedRect: badge.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            speaker.draw(in: badge)
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = description
        return icon
    }

    /// The items at the end of the menu, which never change.
    private lazy var fixedItems: [NSMenuItem] = Self.fixedItems(target: self, updates: host.updatesAreAvailable)

    static func fixedItems(target: AnyObject?, updates: Bool) -> [NSMenuItem] {
        let settingsItem = NSMenuItem(
            title: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = target
        let updatesItem = NSMenuItem(
            title: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = target
        let quitItem = NSMenuItem(
            title: String(localized: "Quit \(AppInfo.name)"), action: #selector(NSApplication.terminate),
            keyEquivalent: "q")
        return [.separator(), settingsItem] + (updates ? [updatesItem] : []) + [quitItem]
    }

    private func build(_ menu: NSMenu) -> MenuControls {
        let controls = MenuControls(host: host)
        self.controls = controls
        return controls
    }

    @objc private func showSettings() {
        host.showSettings()
    }

    @objc private func checkForUpdates() {
        host.checkForUpdates()
    }
}

/// The part of the menu that changes: the rows of each display, the reminder of the
/// shortcuts, the status line and the offer to turn the keyboard's keys on. It stands apart
/// from the menu bar item so that it can be tested without putting one in the menu bar.
@MainActor
final class MenuControls: NSObject {
    /// One group of rows per display under control, and always at least one.
    private(set) var groups: [DisplayRows] = []
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let versionLine = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.version)", action: nil, keyEquivalent: "")
    private let hintItem = NSMenuItem()
    private let separator = NSMenuItem.separator()
    private let accessItem = NSMenuItem(
        title: String(localized: "Turn On \(KeyboardKeys.name)…"), action: nil, keyEquivalent: "")

    private unowned let host: any StatusMenuHost

    init(host: any StatusMenuHost) {
        self.host = host
        super.init()
        hintItem.isEnabled = false
        statusLine.isEnabled = false
        versionLine.isEnabled = false
        accessItem.target = self
        accessItem.action = #selector(enableKeyboardKeys)
        accessItem.subtitle = String(
            localized: "Needs \(AccessibilityAccess.listName)", comment: "The list in System Settings the keys need")
        groups = [makeGroup()]
    }

    /// The first display's rows, which are the only ones with a single display.
    var brightnessRow: SliderRow { groups[0].brightnessRow }
    var volumeRow: SliderRow { groups[0].volumeRow }
    var showsMuted: Bool { groups[0].showsMuted }

    /// The items in the order the menu shows them.
    var items: [NSMenuItem] {
        groups.flatMap(\.items) + [hintItem, separator, statusLine, versionLine, accessItem]
    }

    /// Brings everything in line with what the app knows.
    func update() {
        let displays = host.menuDisplays
        let count = max(displays.count, 1)
        while groups.count < count { groups.append(makeGroup()) }
        if groups.count > count { groups.removeLast(groups.count - count) }
        let isHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        for (index, group) in groups.enumerated() {
            // Each display's rows are headed by its name once there is more than one.
            group.show(index < displays.count ? displays[index] : nil, named: displays.count > 1)
            group.isHighContrast = isHighContrast
        }

        if !host.displayControlIsAvailable {
            statusLine.title = String(localized: "Display control is unavailable on this macOS")
        } else if displays.isEmpty {
            statusLine.title = String(localized: "No controllable display found")
        } else {
            // The displays under control, which need not be the first screens: another can be a
            // television or a projector that does not answer DDC.
            let names = ListFormatter.joinedInAppLanguage(displays.map(\.name))
            statusLine.title = String(localized: "Controlling \(names)", comment: "The names of the displays")
        }

        accessItem.isHidden = host.keyboardKeysAreActive
        hintItem.attributedTitle = Self.hint()
        hintItem.isHidden = hintItem.attributedTitle?.length == 0
    }

    /// A level was changed from outside the menu: by a key, a shortcut or the command line.
    /// Rows that are on screen follow at once. With the menu closed they are in no window and
    /// there is nothing to do, since everything is brought up to date when the menu opens.
    func levelsChanged() {
        if groups.contains(where: \.isOnScreen) { update() }
    }

    private func makeGroup() -> DisplayRows {
        let group = DisplayRows()
        group.onCommand = { [unowned self] command, display in host.run(command, showOSD: false, on: display) }
        return group
    }

    /// The shortcuts in one quiet line, as a reminder.
    private static func hint() -> NSAttributedString {
        func keys(_ actions: [Shortcut.Action]) -> String? {
            let symbols = actions.compactMap { ShortcutSettings.shortcut(for: $0)?.symbols }
            return symbols.isEmpty ? nil : symbols.joined(separator: " ")
        }
        let parts = [
            keys([.brightnessDown, .brightnessUp]).map {
                String(localized: "Brightness \($0)", comment: "Its shortcuts")
            },
            keys([.volumeDown, .volumeUp]).map { String(localized: "Volume \($0)", comment: "Its shortcuts") },
            keys([.mute]).map { String(localized: "Mute \($0)", comment: "Its shortcut") },
        ].compactMap { $0 }
        return NSAttributedString(
            string: parts.joined(separator: "    "),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }

    @objc private func enableKeyboardKeys() {
        host.enableKeyboardKeys()
    }
}

/// One display's rows in the menu: its name when there are several displays, then its
/// brightness, its volume and its contrast, and its inputs. Each changes that display alone.
@MainActor
final class DisplayRows: NSObject {
    let brightnessRow = SliderRow(name: String(localized: "Brightness"), symbol: "sun.max.fill", hasButton: false)
    let volumeRow = SliderRow(name: String(localized: "Volume"), symbol: "speaker.wave.2.fill", hasButton: true)
    let contrastRow = SliderRow(
        name: String(localized: "Contrast"), symbol: "circle.lefthalf.filled", hasButton: false)
    let header = NSMenuItem.sectionHeader(title: "")
    /// The display's inputs, the one it shows ticked.
    let inputItem = NSMenuItem(
        title: String(localized: "Input", comment: "The input a display shows, such as HDMI 1"), action: nil,
        keyEquivalent: "")
    private let brightnessItem = NSMenuItem()
    private let volumeItem = NSMenuItem()
    private let contrastItem = NSMenuItem()
    /// Called with a command for the display these rows are for.
    var onCommand: ((Command, MenuDisplay.ID?) -> Void)?
    /// The display the rows are for; nil while there is none.
    private(set) var display: MenuDisplay.ID?
    /// Whether the volume row shows the display as muted; kept here because a mute sent from
    /// the menu may not have reached the cached state yet.
    private(set) var showsMuted = false

    override init() {
        super.init()
        brightnessRow.onChange = { [unowned self] in set(.brightness, to: $0) }
        brightnessItem.view = brightnessRow
        volumeRow.onChange = { [unowned self] in set(.volume, to: $0) }
        volumeRow.button?.target = self
        volumeRow.button?.action = #selector(toggleMute)
        volumeItem.view = volumeRow
        contrastRow.onChange = { [unowned self] in set(.contrast, to: $0) }
        contrastItem.view = contrastRow
        inputItem.submenu = NSMenu(title: Command.Control.input.title)
        for input in DDC.Input.allCases {
            let item = NSMenuItem(title: input.title, action: #selector(chooseInput), keyEquivalent: "")
            item.target = self
            item.tag = input.rawValue
            inputItem.submenu?.addItem(item)
        }
    }

    var items: [NSMenuItem] { [header, brightnessItem, volumeItem, contrastItem, inputItem] }
    var isOnScreen: Bool { [brightnessRow, volumeRow, contrastRow].contains { $0.window != nil } }

    var isHighContrast = false {
        didSet { for row in [brightnessRow, volumeRow, contrastRow] { row.slider.isHighContrast = isHighContrast } }
    }

    /// Shows a display's state, headed by its name when `named` is set.
    func show(_ shown: MenuDisplay?, named: Bool) {
        display = shown?.id
        let state = shown?.state
        header.title = shown?.name ?? ""
        header.isHidden = !named || shown == nil
        // VoiceOver says which display a slider is for when there are several.
        let name = shown?.name ?? ""
        brightnessRow.slider.name =
            named
            ? String(localized: "\(name) brightness", comment: "A display's slider") : Command.Control.brightness.title
        volumeRow.slider.name =
            named ? String(localized: "\(name) volume", comment: "A display's slider") : Command.Control.volume.title
        contrastRow.slider.name =
            named
            ? String(localized: "\(name) contrast", comment: "A display's slider") : Command.Control.contrast.title
        brightnessItem.isHidden = state?.brightness == nil
        volumeItem.isHidden = state?.volume == nil
        contrastItem.isHidden = state?.contrast == nil
        inputItem.isHidden = state?.input == nil
        if let brightness = state?.brightness { brightnessRow.show(percent: brightness.fraction * 100) }
        if let contrast = state?.contrast { contrastRow.show(percent: contrast.fraction * 100) }
        let current = state?.input.flatMap(DDC.Input.init(reported:))
        for item in inputItem.submenu?.items ?? [] { item.state = item.tag == current?.rawValue ? .on : .off }
        inputItem.title =
            current.map { String(localized: "Input: \($0.title)", comment: "The input a display shows") }
            ?? Command.Control.input.title
        if let volume = state?.volume {
            showsMuted = state?.isMuted == true
            volumeRow.show(percent: volume.fraction * 100)
            updateMuteButton()
        }
    }

    private func updateMuteButton() {
        let symbol = showsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        volumeRow.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        volumeRow.button?.setAccessibilityLabel(showsMuted ? String(localized: "Unmute") : String(localized: "Mute"))
        // The slider stays usable while muted: moving it unmutes, as macOS's own does.
        volumeRow.slider.isDimmed = showsMuted
    }

    private func set(_ control: Command.Control, to percent: Double) {
        // Setting the volume unmutes the display, so the row has to show that at once.
        if control == .volume, showsMuted {
            showsMuted = false
            updateMuteButton()
        }
        onCommand?(.set(control, percent: Int(percent.rounded())), display)
    }

    /// Switches the display to another input. The display then shows what is connected there,
    /// and this Mac's picture is gone from it until it is switched back.
    @objc private func chooseInput(_ sender: NSMenuItem) {
        guard let input = DDC.Input(rawValue: sender.tag) else { return }
        onCommand?(.input(input), display)
    }

    @objc private func toggleMute() {
        showsMuted.toggle()
        onCommand?(.mute(showsMuted ? .on : .off), display)
        updateMuteButton()
    }
}

/// A menu row: an icon or a button, a slider, and the value as a percentage.
final class SliderRow: NSView {
    let slider = LevelSlider()
    /// The control at the start of the row when it is one that can be pressed.
    let button: NSButton?
    /// Called with each value the user gives the slider.
    var onChange: ((Double) -> Void)?
    private let valueLabel = NSTextField(labelWithString: "")
    /// The whole percentage the label shows. The label is written only when this changes, so
    /// that a drag across a fraction of a percent redraws nothing.
    private var shownPercent: Int?

    init(name: String, symbol: String, hasButton: Bool) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button = hasButton ? NSButton(image: image ?? NSImage(), target: nil, action: nil) : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 284, height: 30))
        // This width is the least the row needs. The menu can be wider, for the line of
        // shortcuts under the rows, and stretches a row that allows it to its own width.
        autoresizingMask = [.width]

        let leading = NSRect(x: 14, y: 5, width: 22, height: 20)
        if let button {
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.frame = leading
            addSubview(button)
        } else {
            let icon = NSImageView(frame: leading)
            icon.image = image
            icon.contentTintColor = .secondaryLabelColor
            addSubview(icon)
        }

        slider.frame = NSRect(x: 44, y: 4, width: 180, height: 22)
        slider.autoresizingMask = [.width]
        slider.name = name
        slider.onChange = { [unowned self] in
            showValue($0)
            onChange?($0)
        }
        addSubview(slider)

        valueLabel.frame = NSRect(x: 228, y: 6, width: 42, height: 17)
        valueLabel.autoresizingMask = [.minXMargin]
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        addSubview(valueLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SliderRow is created in code")
    }

    /// Shows a value that comes from the display. A slider that is being dragged is left
    /// alone: it is ahead of the display, and must not move under the mouse.
    func show(percent: Double) {
        guard !slider.isDragging else { return }
        slider.show(percent)
        showValue(percent)
    }

    private func showValue(_ percent: Double) {
        let whole = Int(percent.rounded())
        guard whole != shownPercent else { return }
        shownPercent = whole
        valueLabel.stringValue = String(localized: "\(whole)%", comment: "A level in percent")
    }
}

/// Turns a scroll into steps: a mouse's wheel one step a notch, a trackpad one step for every
/// stretch the fingers travel, with what is left over kept for the next part of the scroll.
struct ScrollSteps {
    /// How far the fingers travel on a trackpad for one step, in points.
    static let pointsPerStep: CGFloat = 12
    private var carried: CGFloat = 0

    mutating func steps(for points: CGFloat, isPrecise: Bool) -> Int {
        guard isPrecise else { return points == 0 ? 0 : points > 0 ? 1 : -1 }
        carried += points
        let steps = Int((carried / Self.pointsPerStep).rounded(.towardZero))
        carried -= CGFloat(steps) * Self.pointsPerStep
        return steps
    }
}
