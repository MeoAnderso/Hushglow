import AppKit
import DisplayKeysCore
import ServiceManagement

/// What the menu needs from the app.
@MainActor
protocol StatusMenuHost: AnyObject {
    var displayState: DisplayState? { get }
    var displayControlIsAvailable: Bool { get }
    var keyboardKeysAreActive: Bool { get }
    func run(_ command: Command, showOSD: Bool)
    func refreshDisplays()
    func enableKeyboardKeys()
}

/// The menu bar item: sliders for mouse control, plus status, permission and login settings.
/// The menu's contents are refreshed only when it opens.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private unowned let host: any StatusMenuHost
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let brightnessRow = SliderRow(symbol: "sun.max.fill")
    private let volumeRow = SliderRow(symbol: "speaker.wave.2.fill")
    private let brightnessItem = NSMenuItem()
    private let volumeItem = NSMenuItem()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessItem = NSMenuItem(
        title: "Enable Keyboard Volume Keys…", action: #selector(enableKeyboardKeys), keyEquivalent: "")
    private let loginItem = NSMenuItem(
        title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    init(host: any StatusMenuHost) {
        self.host = host
        super.init()
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: AppInfo.name)

        brightnessRow.slider.target = self
        brightnessRow.slider.action = #selector(brightnessChanged)
        brightnessItem.view = brightnessRow
        volumeRow.slider.target = self
        volumeRow.slider.action = #selector(volumeChanged)
        volumeItem.view = volumeRow

        let quitItem = NSMenuItem(
            title: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        accessItem.target = self
        loginItem.target = self
        statusLine.isEnabled = false

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.items = [
            brightnessItem, volumeItem, .separator(), statusLine, accessItem, .separator(), loginItem, quitItem,
        ]
        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Values changed with the display's own buttons are picked up here.
        host.refreshDisplays()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateControls()
        accessItem.isHidden = host.keyboardKeysAreActive

        // Login items point at the app's location, so only offer it once the app is installed.
        let isInstalled = Bundle.main.bundlePath.contains("/Applications/")
        loginItem.isEnabled = isInstalled
        loginItem.title = isInstalled ? "Launch at Login" : "Launch at Login (move to Applications first)"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Called when the displays were re-read; a slider that is being dragged is left alone.
    func displaysChanged() {
        if NSEvent.pressedMouseButtons == 0 { updateControls() }
    }

    private func updateControls() {
        let state = host.displayState
        brightnessItem.isHidden = state?.brightness == nil
        volumeItem.isHidden = state?.volume == nil
        if let brightness = state?.brightness { brightnessRow.slider.doubleValue = brightness.fraction * 100 }
        if let volume = state?.volume {
            volumeRow.slider.doubleValue = state?.isMuted == true ? 0 : volume.fraction * 100
        }

        if !host.displayControlIsAvailable {
            statusLine.title = "Display control is unavailable on this macOS"
        } else if state == nil {
            statusLine.title = "No controllable display found"
        } else {
            let name = NSScreen.screens.first { !Self.isBuiltIn($0) }?.localizedName ?? "Display"
            statusLine.title = "\(name) connected"
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
