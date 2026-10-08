import AppKit
import DisplayKeysCore
import ServiceManagement

/// What the menu needs from the app.
@MainActor
protocol StatusMenuHost: AnyObject {
    var displayState: DisplayState? { get }
    var displayControlIsAvailable: Bool { get }
    var keyboardKeysAreActive: Bool { get }
    var keyboardAskingIsDisabled: Bool { get }
    func run(_ command: Command, showOSD: Bool)
    func refreshDisplays()
    func enableKeyboardKeys()
    func disableKeyboardAsking()
    func showShortcuts()
}

/// The menu bar item: sliders for mouse control, plus status, permission and settings.
/// The menu's contents are built the first time it opens and refreshed each time after;
/// a menu that is never opened costs nothing beyond its icon.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    /// The parts of the menu that change, created together on first open.
    @MainActor
    private struct Contents {
        let brightnessRow = SliderRow(symbol: "sun.max.fill")
        let volumeRow = SliderRow(symbol: "speaker.wave.2.fill")
        let brightnessItem = NSMenuItem()
        let volumeItem = NSMenuItem()
        let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let accessItem = NSMenuItem(title: "Enable Keyboard Volume Keys…", action: nil, keyEquivalent: "")
        let dontAskItem = NSMenuItem(title: "Don’t Ask Again", action: nil, keyEquivalent: "")
        let loginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    }

    private unowned let host: any StatusMenuHost
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var contents: Contents?

    init(host: any StatusMenuHost) {
        self.host = host
        super.init()
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: AppInfo.name)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Values changed with the display's own buttons are picked up here.
        host.refreshDisplays()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let contents = contents ?? build(menu)
        updateControls(contents)
        contents.accessItem.isHidden = host.keyboardKeysAreActive
        contents.dontAskItem.isHidden = host.keyboardKeysAreActive || host.keyboardAskingIsDisabled

        // Login items point at the app's location, so only offer it once the app is installed.
        let isInstalled = Bundle.main.bundlePath.contains("/Applications/")
        contents.loginItem.isEnabled = isInstalled
        contents.loginItem.title = isInstalled ? "Launch at Login" : "Launch at Login (move to Applications first)"
        contents.loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Called when the displays were re-read; a slider that is being dragged is left alone.
    func displaysChanged() {
        if let contents, NSEvent.pressedMouseButtons == 0 { updateControls(contents) }
    }

    private func build(_ menu: NSMenu) -> Contents {
        let contents = Contents()
        contents.brightnessRow.slider.target = self
        contents.brightnessRow.slider.action = #selector(brightnessChanged)
        contents.brightnessItem.view = contents.brightnessRow
        contents.volumeRow.slider.target = self
        contents.volumeRow.slider.action = #selector(volumeChanged)
        contents.volumeItem.view = contents.volumeRow
        contents.statusLine.isEnabled = false

        let shortcutsItem = NSMenuItem(title: "Shortcuts…", action: #selector(showShortcuts), keyEquivalent: ",")
        let quitItem = NSMenuItem(
            title: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        for (menuItem, action) in [
            (contents.accessItem, #selector(enableKeyboardKeys)), (contents.dontAskItem, #selector(dontAskAgain)),
            (contents.loginItem, #selector(toggleLaunchAtLogin)), (shortcutsItem, #selector(showShortcuts)),
        ] {
            menuItem.target = self
            menuItem.action = action
        }
        menu.items = [
            contents.brightnessItem, contents.volumeItem, .separator(),
            contents.statusLine, contents.accessItem, contents.dontAskItem, .separator(),
            shortcutsItem, contents.loginItem, quitItem,
        ]
        self.contents = contents
        return contents
    }

    private func updateControls(_ contents: Contents) {
        let state = host.displayState
        contents.brightnessItem.isHidden = state?.brightness == nil
        contents.volumeItem.isHidden = state?.volume == nil
        if let brightness = state?.brightness { contents.brightnessRow.slider.doubleValue = brightness.fraction * 100 }
        if let volume = state?.volume {
            contents.volumeRow.slider.doubleValue = state?.isMuted == true ? 0 : volume.fraction * 100
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

    @objc private func brightnessChanged(_ sender: NSSlider) {
        host.run(.set(.brightness, percent: Int(sender.doubleValue.rounded())), showOSD: false)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        host.run(.set(.volume, percent: Int(sender.doubleValue.rounded())), showOSD: false)
    }

    @objc private func enableKeyboardKeys() {
        host.enableKeyboardKeys()
    }

    @objc private func dontAskAgain() {
        host.disableKeyboardAsking()
    }

    @objc private func showShortcuts() {
        host.showShortcuts()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
            log.error("Launch at login could not be changed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return CGDisplayIsBuiltin(number) != 0
    }
}

/// A menu row with an icon and a continuous slider.
private final class SliderRow: NSView {
    let slider = NSSlider()

    init(symbol: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let icon = NSImageView(frame: NSRect(x: 16, y: 6, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        slider.frame = NSRect(x: 44, y: 4, width: 180, height: 22)
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        addSubview(icon)
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SliderRow is created in code")
    }
}
