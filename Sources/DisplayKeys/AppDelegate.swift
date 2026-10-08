import AppKit
import DisplayKeysCore
import os

/// View lifecycle events with:
/// log stream --level debug --predicate 'subsystem == "local.DisplayKeys"'
let log = Logger(subsystem: AppInfo.bundleID, category: "app")

/// Wires the pieces together. Everything is event-driven: in the steady state there are no
/// timers and no polling.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, StatusMenuHost {
    private static let wakeSettleDelay: TimeInterval = 3
    private static let reconfigurationSettleDelay: TimeInterval = 2

    private var displays: Displays<IOAV>?
    private let audio = AudioRoute()
    private let osd = OSD()
    private let keyboard = KeyboardInput()
    private let systemEvents = SystemEvents()
    private var statusMenu: StatusMenu?
    private var channel: CommandChannel?
    private var shortcutsWindow: ShortcutsWindow?
    private var lastReadMilliseconds: Int?

    var displayState: DisplayState? { displays?.primary }
    var displayControlIsAvailable: Bool { displays != nil }
    var keyboardKeysAreActive: Bool { keyboard.keysAreActive }
    var keyboardAskingIsDisabled: Bool { keyboard.askingIsDisabled }

    // MARK: Launch and termination

    func applicationDidFinishLaunching(_ notification: Notification) {
        startDisplays()

        keyboard.onCommand = { [unowned self] in run($0, showOSD: true) }
        keyboard.routingContext = { [unowned self] in routingContext }
        keyboard.start()

        statusMenu = StatusMenu(host: self)
        channel = CommandChannel(
            handlers: .init(
                onCommand: { [unowned self] in run($0, showOSD: true) },
                onShortcutsChanged: { [unowned self] in keyboard.reloadShortcuts() },
                onKeyTest: { [unowned self] in keyboard.postTestKey() },
                onWatchKeys: { [unowned self] in keyboard.watch.start(for: $0) },
                status: { [unowned self] in status }))
        audio.startListening()

        systemEvents.onDisplaysSlept = { [unowned self] in
            displays?.suspend()
            keyboard.stopRepeating()
        }
        systemEvents.onDisplaysWoke = { [unowned self] in
            // A display needs a moment after waking before it answers DDC again.
            scheduleRefresh(after: Self.wakeSettleDelay)
            keyboard.updateKeyTap()
        }
        // Plugging a display in produces a burst of these; act once it is over.
        systemEvents.onDisplaysReconfigured = { [unowned self] in
            scheduleRefresh(after: Self.reconfigurationSettleDelay)
        }
        systemEvents.start()
        let build = CodeIdentity.short ?? "unknown"
        log.notice("Launched, version \(AppInfo.version, privacy: .public), build \(build, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboard.stop()
    }

    // MARK: Commands

    /// Applies a command to the displays and optionally shows the result on screen.
    func run(_ command: Command, showOSD: Bool) {
        guard let displays else {
            if showOSD { osd.show(.noDisplay) }
            return
        }
        displays.apply(command) { [osd] feedback, isFinal in
            guard showOSD else { return }
            if let feedback {
                osd.show(.level(feedback))
            } else if isFinal {
                osd.show(displays.primary == nil ? .noDisplay : .unsupported(command.control))
            }
        }
    }

    private var routingContext: KeyRouting.Context? {
        guard let displays else { return nil }
        return KeyRouting.Context(
            hasBrightness: displays.hasBrightness,
            hasVolume: displays.hasVolume,
            soundGoesToDisplay: audio.outputIsDisplay,
            mainDisplayIsBuiltIn: CGDisplayIsBuiltin(CGMainDisplayID()) != 0)
    }

    // MARK: Menu

    func enableKeyboardKeys() {
        keyboard.requestAccess()
    }

    func disableKeyboardAsking() {
        keyboard.askingIsDisabled = true
    }

    func showShortcuts() {
        if shortcutsWindow == nil {
            shortcutsWindow = ShortcutsWindow(
                onOpen: { [unowned self] in keyboard.pauseShortcuts() },
                onClose: { [unowned self] in keyboard.reloadShortcuts() })
        }
        shortcutsWindow?.show()
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
        displays.onChange = { [unowned self] in statusMenu?.displaysChanged() }
        displays.onMismatch = { [unowned self] in displayDisagreed($0) }
        displays.onRead = { [unowned self] features, duration in
            lastReadMilliseconds = Int((duration * 1000).rounded())
            log.debug("Read \(features.count) value(s) from the display in \(Int((duration * 1000).rounded())) ms")
        }
        self.displays = displays
        displays.refresh()
    }

    private func displayDisagreed(_ mismatch: DisplayMismatch) {
        let name = String(describing: mismatch.feature)
        switch mismatch.kind {
        case .changedOutside:
            log.info(
                "\(name, privacy: .public) was changed outside the app, from \(mismatch.cached) to \(mismatch.actual)")
        case .writeAdjusted:
            log.info("The display set \(name, privacy: .public) to \(mismatch.actual) instead of \(mismatch.cached)")
        case .writeRefused:
            log.notice(
                "The display kept \(name, privacy: .public) at \(mismatch.actual) and did not take \(mismatch.cached)")
            osd.show(.refused(mismatch.feature == .brightness ? .brightness : .volume))
        }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshDisplays), object: nil)
        perform(#selector(refreshDisplays), with: nil, afterDelay: delay)
    }

    /// Rediscovers the displays and re-reads their state.
    @objc func refreshDisplays() {
        displays?.refresh()
    }

    // MARK: Status

    private var status: AppStatus {
        let state = displays?.primary
        func level(_ value: DDC.Value?) -> AppStatus.Level? {
            value.map { AppStatus.Level(current: $0.current, maximum: $0.maximum) }
        }
        return AppStatus(
            version: AppInfo.version,
            build: CodeIdentity.short,
            displayControlAvailable: displayControlIsAvailable,
            brightness: level(state?.brightness),
            volume: level(state?.volume),
            muted: state?.isMuted ?? false,
            accessGranted: keyboard.accessIsGranted,
            askingIsDisabled: keyboard.askingIsDisabled,
            keyTapActive: keyboard.keysAreActive,
            soundGoesToDisplay: audio.outputIsDisplay,
            quarterSteps: ShortcutSettings.quarterSteps,
            shortcuts: keyboard.shortcutStatuses,
            input: keyboard.input,
            lastReadMilliseconds: lastReadMilliseconds,
            isWatchingKeys: keyboard.watch.isWatching,
            watchedKeys: keyboard.watch.seen)
    }
}
