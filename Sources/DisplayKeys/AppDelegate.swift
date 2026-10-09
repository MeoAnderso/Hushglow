import AppKit
import DisplayKeysCore
import os

/// View lifecycle events with:
/// log stream --level debug --predicate 'subsystem == "local.DisplayKeys"'
let log = Logger(subsystem: AppInfo.bundleID, category: "app")

/// Wires the pieces together. Everything is event-driven: in the steady state there are no
/// timers and no polling.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, StatusMenuHost, SettingsHost {
    private static let wakeSettleDelay: TimeInterval = 3
    private static let reconfigurationSettleDelay: TimeInterval = 2
    private static let welcomeShownKey = "welcomeShown"

    private var displays: Displays<IOAV>?
    private let audio = AudioRoute()
    private let osd = OSD()
    private let announcer = Announcer()
    private let keyboard = KeyboardInput()
    private let systemEvents = SystemEvents()
    private var statusMenu: StatusMenu?
    private var channel: CommandChannel?
    private var settingsWindow: SettingsWindow?
    private var welcomeWindow: WelcomeWindow?
    private var lastReadMilliseconds: Int?

    var displayState: DisplayState? { displays?.primary }
    var displayControlIsAvailable: Bool { displays != nil }
    var keyboardKeysAreActive: Bool { keyboard.keysAreActive }

    var keyboardAskingIsDisabled: Bool {
        get { keyboard.askingIsDisabled }
        set { keyboard.askingIsDisabled = newValue }
    }

    // MARK: Launch and termination

    func applicationDidFinishLaunching(_ notification: Notification) {
        startDisplays()

        keyboard.onCommand = { [unowned self] in run($0, showOSD: true) }
        keyboard.routingContext = { [unowned self] in routingContext }
        let shouldAskAboutKeys = keyboard.start()

        let statusMenu = StatusMenu(host: self)
        self.statusMenu = statusMenu
        osd.anchor = { [unowned statusMenu] in statusMenu.itemFrame }
        channel = CommandChannel(
            handlers: .init(
                onCommand: { [unowned self] in run($0, showOSD: true) },
                onShortcutsChanged: { [unowned self] in keyboard.reloadShortcuts() },
                onKeyTest: { [unowned self] in keyboard.postTestKey() },
                onWatchKeys: { [unowned self] in watchKeys(for: $0) },
                readValues: { [unowned self] in readValues(of: $0, answer: $1) },
                status: { [unowned self] in status }))
        keyboard.watch.onEnd = { [unowned self] in osd.release(.watchingKeys) }
        audio.onChange = { [unowned self] in keyboard.updateRouting() }
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
            // Which display is the main one may have changed already.
            keyboard.updateRouting()
        }
        systemEvents.start()

        let build = CodeIdentity.short ?? "unknown"
        log.notice("Launched, version \(AppInfo.version, privacy: .public), build \(build, privacy: .public)")
        greet(shouldAskAboutKeys: shouldAskAboutKeys)
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboard.stop()
    }

    /// Explains the app on its first launch, and the lost permission after an update, before
    /// macOS shows a prompt of its own.
    private func greet(shouldAskAboutKeys: Bool) {
        let isFirstLaunch = !AppInfo.defaults.bool(forKey: Self.welcomeShownKey)
        guard isFirstLaunch || shouldAskAboutKeys else { return }
        AppInfo.defaults.set(true, forKey: Self.welcomeShownKey)
        let welcome = WelcomeWindow(
            onTurnOn: { [unowned self] in keyboard.requestAccess() },
            onDontAsk: { [unowned self] in keyboard.askingIsDisabled = true })
        welcomeWindow = welcome
        welcome.show(isFirstLaunch ? .firstLaunch : .update, keysAreActive: keyboard.keysAreActive)
    }

    // MARK: Commands

    /// Applies a command to the displays and optionally shows the result on screen.
    func run(_ command: Command, showOSD: Bool) {
        guard let displays else {
            if showOSD { indicate(.noDisplay) }
            return
        }
        displays.apply(command) { [unowned self] feedback, isFinal in
            guard showOSD else { return }
            if let feedback {
                indicate(.level(feedback))
            } else if isFinal {
                indicate(displays.primary == nil ? .noDisplay : .unsupported(command.control))
            }
        }
    }

    private func indicate(_ indication: Indication) {
        osd.show(indication)
        announcer.announce(indication)
    }

    /// Starts a key watch. Any process on this Mac can ask for one over the command channel,
    /// so the indicator says that one is running for as long as it runs.
    private func watchKeys(for seconds: TimeInterval) {
        guard keyboard.watch.start(for: seconds) else { return }
        osd.hold(.watchingKeys)
        announcer.announce(.watchingKeys)
    }

    /// Reads a feature from the displays for the command line.
    private func readValues(of feature: DDC.Feature, answer: @escaping @MainActor ([AppStatus.Level]) -> Void) {
        guard let displays else { return answer([]) }
        displays.values(of: feature) { values in
            answer(values.map { AppStatus.Level(current: $0.current, maximum: $0.maximum) })
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

    // MARK: Menu and Settings

    func enableKeyboardKeys() {
        keyboard.requestAccess()
    }

    func refreshKeyboardAccess() {
        keyboard.updateKeyTap()
    }

    func showSettings() {
        if settingsWindow == nil {
            let settings = SettingsWindow(host: self)
            settings.onClose = { [unowned self] in settingsWindow = nil }
            settingsWindow = settings
        }
        settingsWindow?.show()
    }

    func pauseShortcuts() {
        keyboard.pauseShortcuts()
    }

    func resumeShortcuts() {
        keyboard.reloadShortcuts()
    }

    func canRegister(_ shortcut: Shortcut) -> Bool {
        keyboard.canRegister(shortcut)
    }

    var shortcutsUsedByMacOS: [Shortcut] { keyboard.shortcutsUsedByMacOS }

    func previewIndicator() {
        let brightness = displays?.primary?.brightness ?? DDC.Value(current: 50, maximum: 100)
        osd.show(.level(Feedback(kind: .brightness, value: brightness)))
    }

    // MARK: Displays

    private func startDisplays() {
        guard let io = IOAV.shared else {
            log.error("The private IOAVService functions are missing; display control is unavailable")
            return
        }
        // A pool for each piece of work, so nothing it leaves behind outlives it.
        let queue = DispatchQueue(
            label: "\(AppInfo.bundleID).ddc", qos: .userInitiated, autoreleaseFrequency: .workItem)
        let displays = Displays(transport: io, queue: queue) {
            // A failed write means the display went away; look again once things settle.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.scheduleRefresh(after: 1) }
            }
        }
        displays.onChange = { [unowned self] in
            statusMenu?.displaysChanged()
            keyboard.updateRouting()
        }
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
            indicate(.refused(mismatch.feature == .brightness ? .brightness : .volume))
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
            memoryFootprint: ProcessMemory.footprint,
            isWatchingKeys: keyboard.watch.isWatching,
            watchedKeys: keyboard.watch.seen)
    }
}
