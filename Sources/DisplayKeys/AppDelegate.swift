import AppKit
import ApplicationServices
import DisplayKeysCore
import os

/// Wires the pieces together and owns the app's lifecycle. Everything is event-driven: in the
/// steady state there are no timers and no polling.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let log = Logger(subsystem: AppInfo.bundleID, category: "app")

    /// Posted system-wide when Accessibility access is granted to or withdrawn from any app.
    private static let accessibilityChangedNotification = Notification.Name("com.apple.accessibility.api")
    private static let promptedKey = "didPromptForAccessibility"
    private static let wakeSettleDelay: TimeInterval = 3
    private static let reconfigurationSettleDelay: TimeInterval = 2
    private static let permissionPollInterval: TimeInterval = 3

    private var displays: Displays?
    private let audio = AudioRoute()
    private let osd = OSD()
    private var keyTap: MediaKeyTap?
    private var hotkeys: Hotkeys?
    private var statusMenu: StatusMenu?
    private var permissionTimer: Timer?
    private var shortcutsAreRegistered = false

    var displayState: DisplayState? { displays?.primary }
    var displayControlIsAvailable: Bool { displays != nil }
    var keyTapIsRunning: Bool { keyTap?.isRunning ?? false }

    // MARK: Launch and termination

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let io = IOAV.shared {
            let displays = Displays(io: io) {
                // A failed write means the display went away; look again once things settle.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.scheduleRefresh(after: 1) }
                }
            }
            displays.onChange = { [unowned self] in displaysChanged() }
            self.displays = displays
        } else {
            Self.log.error("The private IOAVService functions are missing; display control is unavailable")
        }

        keyTap = MediaKeyTap(
            handler: { [unowned self] event, fine in handle(event, fine: fine) },
            onDisabled: { [unowned self] in updateKeyTap() }
        )
        hotkeys = Hotkeys { [unowned self] action, fine in run(action.command(fine: fine), showOSD: true) }
        statusMenu = StatusMenu(app: self)
        audio.startListening()
        observeSystemEvents()
        displays?.refresh()

        if !AXIsProcessTrusted(), !AppInfo.defaults.bool(forKey: Self.promptedKey) {
            AppInfo.defaults.set(true, forKey: Self.promptedKey)
            requestAccessibility(openSettings: false)
        }
        updateKeyTap()
        let menuBarItemIsVisible = statusMenu?.isVisible ?? false
        Self.log.notice("Launched, version \(AppInfo.version, privacy: .public), menu bar item visible: \(menuBarItemIsVisible, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyTap?.stop()
        hotkeys?.unregisterAll()
    }

    // MARK: Commands

    /// Applies a command to the displays and optionally shows the on-screen indicator.
    func run(_ command: Command, showOSD: Bool) {
        guard let feedback = displays?.apply(command) else { return }
        if showOSD { osd.show(feedback) }
    }

    /// Handles a media key; returns false to leave it to macOS.
    private func handle(_ event: MediaKeyEvent, fine: Bool) -> Bool {
        guard let displays else { return false }
        let context = KeyRouting.Context(
            hasBrightness: displays.hasBrightness,
            hasVolume: displays.hasVolume,
            soundGoesToDisplay: audio.outputIsDisplay,
            mainDisplayIsBuiltIn: CGDisplayIsBuiltin(CGMainDisplayID()) != 0
        )
        switch KeyRouting.decide(event, fine: fine, in: context) {
        case .passThrough:
            return false
        case .swallow:
            return true
        case let .run(command):
            run(command, showOSD: true)
            return true
        }
    }

    // MARK: Accessibility access

    func requestAccessibility(openSettings: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options), openSettings,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Starts the key tap when access is granted and removes it when access is withdrawn.
    /// Only while access is missing does a slow timer check for it.
    @objc private func updateKeyTap() {
        guard let keyTap else { return }
        let wasRunning = keyTap.isRunning
        if AXIsProcessTrusted(), keyTap.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else {
            keyTap.stop()
            if permissionTimer == nil {
                let timer = Timer(
                    timeInterval: Self.permissionPollInterval, target: self, selector: #selector(updateKeyTap),
                    userInfo: nil, repeats: true
                )
                timer.tolerance = 1
                RunLoop.main.add(timer, forMode: .common)
                permissionTimer = timer
            }
        }
        if keyTap.isRunning != wasRunning {
            Self.log.notice("Keyboard key tap \(keyTap.isRunning ? "started" : "stopped", privacy: .public)")
        }
    }

    // MARK: System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            self, selector: #selector(accessibilityChanged), name: Self.accessibilityChangedNotification, object: nil
        )
        distributed.addObserver(
            self, selector: #selector(remoteCommand), name: AppInfo.commandNotification, object: nil,
            suspensionBehavior: .deliverImmediately
        )
        distributed.addObserver(
            self, selector: #selector(shortcutsChanged), name: AppInfo.shortcutsChangedNotification, object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func screensDidWake() {
        // A display needs a moment after waking before it answers DDC again.
        scheduleRefresh(after: Self.wakeSettleDelay)
        updateKeyTap()
    }

    @objc private func screensDidSleep() {
        displays?.suspend()
        hotkeys?.stopRepeating()
    }

    @objc private func screenParametersChanged() {
        // Plugging a display in produces a burst of these; act once it is over.
        scheduleRefresh(after: Self.reconfigurationSettleDelay)
    }

    @objc private func accessibilityChanged() {
        // The notification can arrive slightly before the new setting is readable.
        perform(#selector(updateKeyTap), with: nil, afterDelay: 0.5)
    }

    @objc private func remoteCommand(_ notification: Notification) {
        guard let text = notification.object as? String,
              let command = Command(words: text.split(separator: " ").map(String.init))
        else { return }
        run(command, showOSD: true)
    }

    @objc private func shortcutsChanged() {
        shortcutsAreRegistered = false
        displaysChanged()
    }

    // MARK: Displays

    private func scheduleRefresh(after delay: TimeInterval) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshDisplays), object: nil)
        perform(#selector(refreshDisplays), with: nil, afterDelay: delay)
    }

    /// Re-reads the displays, picking up changes made with a display's own buttons.
    @objc func refreshDisplays() {
        displays?.refresh()
    }

    /// Shortcuts are held only while there is a display to control, so they stay free otherwise.
    private func displaysChanged() {
        let state = displays?.primary
        statusMenu?.displaysChanged()
        guard (state != nil) != shortcutsAreRegistered else { return }
        shortcutsAreRegistered = state != nil
        let shortcutCount = state != nil ? hotkeys?.reload() ?? 0 : 0
        if state == nil { hotkeys?.unregisterAll() }
        Self.log.notice("Displays: brightness \(state?.brightness != nil, privacy: .public), volume \(state?.volume != nil, privacy: .public), shortcuts registered: \(shortcutCount, privacy: .public)")
    }
}
