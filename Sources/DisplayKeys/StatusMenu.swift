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
    /// The parts of the menu that change, created together on first open.
    @MainActor
    private struct Contents {
        let brightnessRow = SliderRow(name: "Brightness", symbol: "sun.max.fill", hasButton: false)
        let volumeRow = SliderRow(name: "Volume", symbol: "speaker.wave.2.fill", hasButton: true)
        let brightnessItem = NSMenuItem()
        let volumeItem = NSMenuItem()
        let hintItem = NSMenuItem()
        let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let accessItem = NSMenuItem(title: "Turn On Keyboard Volume Keys…", action: nil, keyEquivalent: "")
    }

    private unowned let host: any StatusMenuHost
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var contents: Contents?
    /// Whether the volume row shows the display as muted; kept here because a mute sent from
    /// the menu may not have reached the cached state yet.
    private var showsMuted = false

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
        let contents = contents ?? build(menu)
        updateControls(contents)
        contents.accessItem.isHidden = host.keyboardKeysAreActive
        contents.hintItem.attributedTitle = Self.hint()
        contents.hintItem.isHidden = contents.hintItem.attributedTitle?.length == 0
    }

    /// Called when the displays were re-read; a slider that is being dragged is left alone.
    func displaysChanged() {
        // The icon dims while there is nothing to control.
        item.button?.appearsDisabled = host.displayState == nil
        if let contents, NSEvent.pressedMouseButtons == 0 { updateControls(contents) }
    }

    private func build(_ menu: NSMenu) -> Contents {
        let contents = Contents()
        contents.brightnessRow.slider.target = self
        contents.brightnessRow.slider.action = #selector(brightnessChanged)
        contents.brightnessItem.view = contents.brightnessRow
        contents.volumeRow.slider.target = self
        contents.volumeRow.slider.action = #selector(volumeChanged)
        contents.volumeRow.button?.target = self
        contents.volumeRow.button?.action = #selector(toggleMute)
        contents.volumeItem.view = contents.volumeRow
        contents.hintItem.isEnabled = false
        contents.statusLine.isEnabled = false
        contents.accessItem.target = self
        contents.accessItem.action = #selector(enableKeyboardKeys)
        if #available(macOS 14.4, *) { contents.accessItem.subtitle = "Needs \(AccessibilityAccess.listName)" }

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        let quitItem = NSMenuItem(
            title: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        menu.items = [
            contents.brightnessItem, contents.volumeItem, contents.hintItem, .separator(),
            contents.statusLine, contents.accessItem, .separator(),
            settingsItem, quitItem,
        ]
        self.contents = contents
        return contents
    }

    private func updateControls(_ contents: Contents) {
        let state = host.displayState
        contents.brightnessItem.isHidden = state?.brightness == nil
        contents.volumeItem.isHidden = state?.volume == nil
        if let brightness = state?.brightness { contents.brightnessRow.show(percent: brightness.fraction * 100) }
        if let volume = state?.volume {
            showsMuted = state?.isMuted == true
            contents.volumeRow.show(percent: volume.fraction * 100)
            updateMuteButton(contents)
        }

        if !host.displayControlIsAvailable {
            contents.statusLine.title = "Display control is unavailable on this macOS"
        } else if state == nil {
            contents.statusLine.title = "No controllable display found"
        } else {
            let name = NSScreen.screens.first { !Self.isBuiltIn($0) }?.localizedName ?? "Display"
            contents.statusLine.title = "\(name) connected"
        }
    }

    private func updateMuteButton(_ contents: Contents) {
        let symbol = showsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        contents.volumeRow.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        contents.volumeRow.button?.setAccessibilityLabel(showsMuted ? "Unmute" : "Mute")
        contents.volumeRow.slider.isEnabled = !showsMuted
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

    @objc private func brightnessChanged(_ sender: NSSlider) {
        contents?.brightnessRow.show(percent: sender.doubleValue)
        host.run(.set(.brightness, percent: Int(sender.doubleValue.rounded())), showOSD: false)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        contents?.volumeRow.show(percent: sender.doubleValue)
        host.run(.set(.volume, percent: Int(sender.doubleValue.rounded())), showOSD: false)
    }

    @objc private func toggleMute() {
        showsMuted.toggle()
        host.run(.mute(showsMuted ? .on : .off), showOSD: false)
        if let contents { updateMuteButton(contents) }
    }

    @objc private func enableKeyboardKeys() {
        host.enableKeyboardKeys()
    }

    @objc private func showSettings() {
        host.showSettings()
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return CGDisplayIsBuiltin(number) != 0
    }
}

/// A menu row: an icon or a button, a continuous slider, and the value as a percentage.
final class SliderRow: NSView {
    let slider = NSSlider()
    /// The control at the start of the row when it is one that can be pressed.
    let button: NSButton?
    private let valueLabel = NSTextField(labelWithString: "")

    init(name: String, symbol: String, hasButton: Bool) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button = hasButton ? NSButton(image: image ?? NSImage(), target: nil, action: nil) : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 284, height: 30))

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
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.setAccessibilityLabel(name)
        addSubview(slider)

        valueLabel.frame = NSRect(x: 228, y: 6, width: 42, height: 17)
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
        slider.doubleValue = percent
        valueLabel.stringValue = "\(Int(percent.rounded()))%"
        slider.setAccessibilityValueDescription("\(Int(percent.rounded())) percent")
    }
}
