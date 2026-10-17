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
    private let feedbackSound = FeedbackSound()
    private let keyboard = KeyboardInput()
    private let systemEvents = SystemEvents()
    private var statusMenu: StatusMenu?
    private var channel: CommandChannel?
    private var settingsWindow: SettingsWindow?
    private var welcomeWindow: WelcomeWindow?
    private var lastRead: (milliseconds: Int, values: Int)?

    var displayState: DisplayState? {
        soundDisplay.flatMap { displays?.state(of: $0) } ?? displays?.primary
    }

    var menuDisplays: [MenuDisplay] {
        displays?.sessions.map { session in
            MenuDisplay(
                id: ObjectIdentifier(session.display), name: session.display.identity?.name ?? "Display",
                state: session.state)
        } ?? []
    }
    var displayControlIsAvailable: Bool { displays != nil }
    var keyboardKeysAreActive: Bool { keyboard.keysAreActive }

    var keyboardAskingIsDisabled: Bool {
        get { keyboard.askingIsDisabled }
        set { keyboard.askingIsDisabled = newValue }
    }

    // MARK: Launch and termination

    func applicationDidFinishLaunching(_ notification: Notification) {
        startDisplays()
        // Before any shortcut is registered.
        ShortcutSettings.settleDefaultSet(isNewInstall: !AppInfo.defaults.bool(forKey: Self.welcomeShownKey))

        keyboard.onCommand = { [unowned self] in run($0, showOSD: true, to: keyTargets(for: $0)) }
        // An open notice lights the key cap of a shortcut that is pressed.
        keyboard.onShortcut = { [unowned self] in welcomeWindow?.shortcutPressed($0) }
        keyboard.routingContext = { [unowned self] in routingContext }
        let shouldAskAboutKeys = keyboard.start()
        // With the menu open the shortcuts come as key presses on their way to the menu.
        if let application = NSApp as? Application {
            application.takeKeyFromMenu = { [unowned self] in keyboard.takeShortcut(from: $0) }
        } else {
            log.error("The application object is not the app's own; shortcuts will wait for the menu to close")
        }

        let statusMenu = StatusMenu(host: self)
        self.statusMenu = statusMenu
        osd.anchor = { [unowned statusMenu] in statusMenu.itemFrame }
        channel = CommandChannel(
            handlers: .init(
                onCommand: { [unowned self] in run($0, showOSD: true, to: displays(numbered: $1)) },
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

    /// A scroll over the menu bar icon steps the brightness of the display whose menu bar it
    /// is; on a screen that is not under control, of the display the keys would change.
    func stepBrightness(up: Bool, fromMenuBarOf screen: NSScreen?) {
        let command = Command.step(.brightness, up: up, fine: false)
        let onScreen = displays?.controlled.first { $0.identity?.screen == screen }
        run(command, showOSD: true, to: onScreen.map { [$0] } ?? keyTargets(for: command))
    }

    /// Applies a command from the menu to one display, or to all of them.
    func run(_ command: Command, showOSD: Bool, on display: MenuDisplay.ID?) {
        let handle = displays?.controlled.first { ObjectIdentifier($0) == display }
        run(command, showOSD: showOSD, to: handle.map { [$0] })
    }

    /// Applies a command to some displays, or to all of them, and optionally shows the result
    /// on the display that answered.
    func run(_ command: Command, showOSD: Bool, to targets: [AVService]?) {
        guard let displays else {
            if showOSD { indicate(.noDisplay) }
            return
        }
        let screen = displays.answering(command, to: targets)?.identity?.screen
        displays.apply(command, to: targets) { [unowned self] feedback, isFinal in
            // Mute may have changed, from the menu as from anywhere else.
            if isFinal { statusMenu?.updateIcon() }
            // What the menu asks for stops here. Its sliders are ahead of the display as it
            // is, and are not to be moved under the mouse.
            guard showOSD else { return }
            // An open menu shows what a key did, as the indicator does.
            if isFinal { statusMenu?.levelsChanged() }
            // A display switched to another input no longer shows this Mac.
            if feedback?.kind == .input { return }
            if let feedback {
                indicate(.level(feedback), on: screen)
                if isFinal,
                    FeedbackSound.plays(
                        after: command, feedback: feedback, soundGoesToDisplay: audio.outputIsDisplay,
                        isOn: FeedbackSound.isOn)
                {
                    feedbackSound.play()
                }
            } else if isFinal {
                indicate(displays.primary == nil ? .noDisplay : .unsupported(command.control))
            }
        }
    }

    private func indicate(_ indication: Indication, on screen: NSScreen? = nil) {
        osd.show(indication, on: screen)
        announcer.announce(indication)
    }

    // MARK: Which display

    /// Which displays a key or a shortcut changes: nil for all of them. With several displays
    /// and the keys set to follow the pointer, the volume goes to the display that sound plays
    /// through, and the rest to the display under the pointer; on a screen that is not under
    /// control, every display changes.
    private func keyTargets(for command: Command) -> [AVService]? {
        Self.keyTargets(
            for: command.control, setting: ControlSettings.keysChange, count: displays?.controlled.count ?? 0,
            soundDisplay: soundDisplay, displayUnderPointer: displayUnderPointer)
    }

    /// The rule `keyTargets(for:)` follows, apart from the screen and the sound output.
    static func keyTargets<Display>(
        for control: Command.Control, setting: ControlSettings.Target, count: Int, soundDisplay: Display?,
        displayUnderPointer: Display?
    ) -> [Display]? {
        guard setting == .pointer, count > 1 else { return nil }
        if control == .volume, let soundDisplay { return [soundDisplay] }
        return displayUnderPointer.map { [$0] }
    }

    /// The display with a number from the command line, counted from 1 in the order `status`
    /// lists them; nil for every display.
    private func displays(numbered number: Int?) -> [AVService]? {
        guard let number else { return nil }
        let controlled = displays?.controlled ?? []
        return controlled.indices.contains(number - 1) ? [controlled[number - 1]] : []
    }

    /// The display under control that sound plays through, by the name of the sound output.
    private var soundDisplay: AVService? {
        guard let name = audio.displayName else { return nil }
        return displays?.controlled.first { $0.identity?.playsSound(named: name) == true }
    }

    private var displayUnderPointer: AVService? {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return nil }
        return displays?.controlled.first { $0.identity?.screen == screen }
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

    func readDisplays() {
        displays?.readValues()
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
        keyboard.resumeShortcuts()
    }

    func menuDidChange(isOpen: Bool) {
        keyboard.menuIsOpen = isOpen
    }

    func canRegister(_ shortcut: Shortcut) -> Bool {
        keyboard.canRegister(shortcut)
    }

    var shortcutsUsedByMacOS: [Shortcut] { keyboard.shortcutsUsedByMacOS }

    func previewIndicator() {
        let brightness = displays?.primary?.brightness ?? DDC.Value(current: 50, maximum: 100)
        osd.show(.level(Feedback(kind: .brightness, value: brightness)), on: nil)
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
            let milliseconds = Int((duration * 1000).rounded())
            lastRead = (milliseconds, features.count)
            log.debug("Read \(features.count) value(s) from the display in \(milliseconds) ms")
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

    /// In every mode of the run loop, as the other delayed calls are: a display replugged or
    /// woken while a menu is open is looked for then, not when the menu closes.
    private func scheduleRefresh(after delay: TimeInterval) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshDisplays), object: nil)
        perform(#selector(refreshDisplays), with: nil, afterDelay: delay, inModes: [.common])
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
            quarterStepModifier: ShortcutSettings.quarterStepModifier.name,
            shortcuts: keyboard.shortcutStatuses,
            input: keyboard.input,
            lastReadMilliseconds: lastRead?.milliseconds,
            lastReadValues: lastRead?.values,
            memoryFootprint: ProcessMemory.footprint,
            isWatchingKeys: keyboard.watch.isWatching,
            displays: menuDisplays.map { display in
                AppStatus.DisplayStatus(
                    name: display.name, brightness: level(display.state.brightness),
                    volume: level(display.state.volume), muted: display.state.isMuted,
                    contrast: level(display.state.contrast), input: display.state.input)
            },
            watchedKeys: keyboard.watch.seen)
    }
}
