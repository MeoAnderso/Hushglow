import AppKit
import DisplayKeysCore

/// What the menu needs from the app.
@MainActor
protocol StatusMenuHost: AnyObject {
    var displayState: DisplayState? { get }
    var displayControlIsAvailable: Bool { get }
    var keyboardKeysAreActive: Bool { get }
    func run(_ command: Command, showOSD: Bool)
    func refreshDisplays()
    /// Reads again whether the keyboard's own keys are allowed.
    func refreshKeyboardAccess()
    func enableKeyboardKeys()
    func showSettings()
}

/// The menu bar item: sliders for mouse control, plus status and the way into Settings.
/// The menu's contents are built the first time it opens and refreshed each time after;
/// a menu that is never opened costs nothing beyond its icon.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private unowned let host: any StatusMenuHost
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var controls: MenuControls?

    init(host: any StatusMenuHost) {
        self.host = host
        super.init()
        let glyph = NSImage(systemSymbolName: "sun.horizon.fill", accessibilityDescription: AppInfo.name)
        item.button?.image = glyph ?? NSImage(systemSymbolName: "sun.max", accessibilityDescription: AppInfo.name)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
    }

    /// Where the menu bar item is on screen, for placing the indicator beneath it.
    var itemFrame: NSRect? {
        guard let window = item.button?.window, window.frame.width > 0 else { return nil }
        return window.frame
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Values changed with the display's own buttons are picked up here.
        host.refreshDisplays()
        // So is access granted in System Settings, should its notifications ever go missing.
        host.refreshKeyboardAccess()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let controls = controls ?? build(menu)
        controls.update()
    }

    /// Called when the displays were re-read; a slider that is being dragged is left alone.
    func displaysChanged() {
        // The icon dims while there is nothing to control.
        item.button?.appearsDisabled = host.displayState == nil
        if let controls, NSEvent.pressedMouseButtons == 0 { controls.update() }
    }

    private func build(_ menu: NSMenu) -> MenuControls {
        let controls = MenuControls(host: host)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        let quitItem = NSMenuItem(
            title: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        menu.items = controls.items + [.separator(), settingsItem, quitItem]
        self.controls = controls
        return controls
    }

    @objc private func showSettings() {
        host.showSettings()
    }
}

/// The part of the menu that changes: the slider rows, the reminder of the shortcuts, the
/// status line and the offer to turn the keyboard's keys on. It stands apart from the menu bar
/// item so that it can be tested without putting one in the menu bar.
@MainActor
final class MenuControls: NSObject {
    let brightnessRow = SliderRow(name: "Brightness", symbol: "sun.max.fill", hasButton: false)
    let volumeRow = SliderRow(name: "Volume", symbol: "speaker.wave.2.fill", hasButton: true)
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let brightnessItem = NSMenuItem()
    private let volumeItem = NSMenuItem()
    private let hintItem = NSMenuItem()
    private let accessItem = NSMenuItem(title: "Turn On Keyboard Volume Keys…", action: nil, keyEquivalent: "")

    private unowned let host: any StatusMenuHost
    /// Whether the volume row shows the display as muted; kept here because a mute sent from
    /// the menu may not have reached the cached state yet.
    private(set) var showsMuted = false

    init(host: any StatusMenuHost) {
        self.host = host
        super.init()
        brightnessRow.onChange = { [unowned self] in set(.brightness, to: $0) }
        brightnessItem.view = brightnessRow
        volumeRow.onChange = { [unowned self] in set(.volume, to: $0) }
        volumeRow.button?.target = self
        volumeRow.button?.action = #selector(toggleMute)
        volumeItem.view = volumeRow
        hintItem.isEnabled = false
        statusLine.isEnabled = false
        accessItem.target = self
        accessItem.action = #selector(enableKeyboardKeys)
        if #available(macOS 14.4, *) { accessItem.subtitle = "Needs \(AccessibilityAccess.listName)" }
    }

    /// The items in the order the menu shows them.
    var items: [NSMenuItem] {
        [brightnessItem, volumeItem, hintItem, .separator(), statusLine, accessItem]
    }

    /// Brings everything in line with what the app knows.
    func update() {
        let state = host.displayState
        for row in [brightnessRow, volumeRow] {
            row.slider.isHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
        brightnessItem.isHidden = state?.brightness == nil
        volumeItem.isHidden = state?.volume == nil
        if let brightness = state?.brightness { brightnessRow.show(percent: brightness.fraction * 100) }
        if let volume = state?.volume {
            showsMuted = state?.isMuted == true
            volumeRow.show(percent: volume.fraction * 100)
            updateMuteButton()
        }

        if !host.displayControlIsAvailable {
            statusLine.title = "Display control is unavailable on this macOS"
        } else if state == nil {
            statusLine.title = "No controllable display found"
        } else {
            let name = NSScreen.screens.first { !Self.isBuiltIn($0) }?.localizedName ?? "Display"
            statusLine.title = "\(name) connected"
        }

        accessItem.isHidden = host.keyboardKeysAreActive
        hintItem.attributedTitle = Self.hint()
        hintItem.isHidden = hintItem.attributedTitle?.length == 0
    }

    private func updateMuteButton() {
        let symbol = showsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        volumeRow.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        volumeRow.button?.setAccessibilityLabel(showsMuted ? "Unmute" : "Mute")
        // The slider stays usable while muted: moving it unmutes, as macOS's own does.
        volumeRow.slider.isDimmed = showsMuted
    }

    /// The shortcuts in one quiet line, as a reminder.
    private static func hint() -> NSAttributedString {
        func keys(_ actions: [Shortcut.Action]) -> String? {
            let symbols = actions.compactMap { ShortcutSettings.text(for: $0).flatMap(Shortcut.init)?.symbols }
            return symbols.isEmpty ? nil : symbols.joined(separator: " ")
        }
        let parts = [
            keys([.brightnessDown, .brightnessUp]).map { "Brightness \($0)" },
            keys([.volumeDown, .volumeUp]).map { "Volume \($0)" },
            keys([.mute]).map { "Mute \($0)" },
        ].compactMap { $0 }
        return NSAttributedString(
            string: parts.joined(separator: "    "),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }

    private func set(_ control: Command.Control, to percent: Double) {
        // Setting the volume unmutes the display, so the row has to show that at once.
        if control == .volume, showsMuted {
            showsMuted = false
            updateMuteButton()
        }
        host.run(.set(control, percent: Int(percent.rounded())), showOSD: false)
    }

    @objc private func toggleMute() {
        showsMuted.toggle()
        host.run(.mute(showsMuted ? .on : .off), showOSD: false)
        updateMuteButton()
    }

    @objc private func enableKeyboardKeys() {
        host.enableKeyboardKeys()
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return CGDisplayIsBuiltin(number) != 0
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

    func show(percent: Double) {
        slider.show(percent)
        showValue(percent)
    }

    private func showValue(_ percent: Double) {
        let whole = Int(percent.rounded())
        guard whole != shownPercent else { return }
        shownPercent = whole
        valueLabel.stringValue = "\(whole)%"
    }
}
