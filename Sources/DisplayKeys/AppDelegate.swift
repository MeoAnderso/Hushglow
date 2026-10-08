import AppKit
import DisplayKeysCore
import os

/// View lifecycle events with:
/// log stream --level debug --predicate 'subsystem == "local.DisplayKeys"'
let log = Logger(subsystem: AppInfo.bundleID, category: "app")

/// Wires the pieces together and owns the app's lifecycle. Everything is event-driven: in the
/// steady state there are no timers and no polling.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, StatusMenuHost {
    private static let wakeSettleDelay: TimeInterval = 3
    private static let reconfigurationSettleDelay: TimeInterval = 2

    private var displays: Displays<IOAV>?
    private let audio = AudioRoute()
    private let osd = OSD()
    private let access = AccessibilityAccess()
    private var keyTap: MediaKeyTap?
    private var hotkeys: Hotkeys?
    private var statusMenu: StatusMenu?
    private var channel: CommandChannel?
    private var shortcutsAreRegistered = false
    private var input = AppStatus.Input()

    var displayState: DisplayState? { displays?.primary }
    var displayControlIsAvailable: Bool { displays != nil }
    var keyboardKeysAreActive: Bool { keyTap?.isRunning ?? false }

    // MARK: Launch and termination

    func applicationDidFinishLaunching(_ notification: Notification) {
        startDisplays()
        keyTap = MediaKeyTap(
            handler: { [unowned self] event, fine in handle(event, fine: fine) },
            onDisabled: { [unowned self] in updateKeyTap() }
        )
        hotkeys = Hotkeys { [unowned self] action, fine in shortcutPressed(action, fine: fine) }
        statusMenu = StatusMenu(host: self)
        channel = CommandChannel(
            onCommand: { [unowned self] in run($0, showOSD: true) },
            onShortcutsChanged: { [unowned self] in registerShortcuts() },
            status: { [unowned self] in status }
        )
        audio.startListening()
        observeSystemEvents()
        access.onChange = { [unowned self] in updateKeyTap() }
        access.start()
        updateKeyTap()
        log.notice("Launched, version \(AppInfo.version, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyTap?.stop()
        hotkeys?.unregisterAll()
    }

    // MARK: Input

    /// Applies a command to the displays and optionally shows the on-screen indicator.
    func run(_ command: Command, showOSD: Bool) {
        displays?.apply(command) { [osd] feedback in
            if showOSD, let feedback { osd.show(feedback) }
        }
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
        let decision = KeyRouting.decide(event, fine: fine, in: context)
        if event.isDown {
            let handled = decision != .passThrough
            if handled { input.keysHandled += 1 } else { input.keysLeftToSystem += 1 }
            input.record("key \(event.key), \(handled ? "handled" : "left to macOS")")
            log.debug("Key \(String(describing: event.key), privacy: .public), handled: \(handled, privacy: .public)")
        }
        switch decision {
        case .passThrough:
            return false
        case .swallow:
            return true
        case .run(let command):
            run(command, showOSD: true)
            return true
        }
    }

    private func shortcutPressed(_ action: Shortcut.Action, fine: Bool) {
        input.shortcutPresses += 1
        input.record("shortcut \(action.rawValue)")
        log.debug("Shortcut \(action.rawValue, privacy: .public)")
        run(action.command(fine: fine), showOSD: true)
    }

    // MARK: Keyboard keys

    func enableKeyboardKeys() {
        access.request(openSettings: true)
    }

    /// Starts the key tap when Accessibility access is there and removes it when it is not.
    private func updateKeyTap() {
        guard let keyTap else { return }
        let wasRunning = keyTap.isRunning
        if access.isGranted, keyTap.start() {
            access.stopWaiting()
        } else {
            keyTap.stop()
            access.startWaiting()
        }
        if keyTap.isRunning != wasRunning {
            log.notice("Keyboard key tap \(keyTap.isRunning ? "started" : "stopped", privacy: .public)")
        }
    }

    // MARK: System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(screensDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func screensDidWake() {
        log.info("Displays woke")
        // A display needs a moment after waking before it answers DDC again.
        scheduleRefresh(after: Self.wakeSettleDelay)
        updateKeyTap()
    }

    @objc private func screensDidSleep() {
        log.info("Displays went to sleep")
        displays?.suspend()
        hotkeys?.stopRepeating()
    }

    @objc private func screenParametersChanged() {
        log.info("Display configuration changed")
        // Plugging a display in produces a burst of these; act once it is over.
        scheduleRefresh(after: Self.reconfigurationSettleDelay)
    }

    // MARK: Displays

    private func startDisplays() {
        guard let io = IOAV.shared else {
            log.error("The private IOAVService functions are missing; display control is unavailable")
            return
        }
        let queue = DispatchQueue(label: "\(AppInfo.bundleID).ddc", qos: .userInitiated)
        let displays = Displays(transport: io, queue: queue) {
            // A failed write means the display went away; look again once things settle.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.scheduleRefresh(after: 1) }
            }
        }
        displays.onChange = { [unowned self] in displaysChanged() }
        displays.onMismatch = { feature, cached, actual, afterWrite in
            let name = String(describing: feature)
            if afterWrite {
                log.notice("The display kept \(name, privacy: .public) at \(actual) instead of taking \(cached)")
            } else {
                log.info("\(name, privacy: .public) was changed outside the app, from \(cached) to \(actual)")
            }
        }
        self.displays = displays
        displays.refresh()
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshDisplays), object: nil)
        perform(#selector(refreshDisplays), with: nil, afterDelay: delay)
    }

    /// Rediscovers the displays and re-reads their state.
    @objc func refreshDisplays() {
        displays?.refresh()
    }

    /// Shortcuts are held only while there is a display to control, so they stay free otherwise.
    private func displaysChanged() {
        statusMenu?.displaysChanged()
        let state = displays?.primary
        guard (state != nil) != shortcutsAreRegistered else { return }
        let hasBrightness = state?.brightness != nil
        let hasVolume = state?.volume != nil
        log.notice("Display: brightness \(hasBrightness, privacy: .public), volume \(hasVolume, privacy: .public)")
        if state != nil {
            registerShortcuts()
        } else {
            hotkeys?.unregisterAll()
            shortcutsAreRegistered = false
        }
    }

    private func registerShortcuts() {
        guard displays?.primary != nil, let hotkeys else { return }
        hotkeys.reload()
        shortcutsAreRegistered = true
        let refused = hotkeys.statuses.filter { !$0.registered }.map(\.keys)
        log.notice("Shortcuts registered: \(hotkeys.statuses.count - refused.count)")
        if !refused.isEmpty {
            log.error("macOS refused these shortcuts: \(refused.joined(separator: ", "), privacy: .public)")
        }
    }

    // MARK: Status

    private var status: AppStatus {
        let state = displays?.primary
        func level(_ value: DDC.Value?) -> AppStatus.Level? {
            value.map { AppStatus.Level(current: $0.current, maximum: $0.maximum) }
        }
        return AppStatus(
            version: AppInfo.version,
            displayControlAvailable: displayControlIsAvailable,
            brightness: level(state?.brightness),
            volume: level(state?.volume),
            muted: state?.isMuted ?? false,
            accessGranted: access.isGranted,
            keyTapActive: keyboardKeysAreActive,
            soundGoesToDisplay: audio.outputIsDisplay,
            quarterSteps: ShortcutSettings.quarterSteps,
            shortcuts: hotkeys?.statuses ?? [],
            input: input
        )
    }
}
