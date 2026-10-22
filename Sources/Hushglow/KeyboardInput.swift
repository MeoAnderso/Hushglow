import AppKit
import HushglowCore

/// Everything that comes from the keyboard: the keyboard's own media keys (which need
/// Accessibility access) and the global shortcuts (which do not).
@MainActor
final class KeyboardInput {
    /// A key or shortcut asked for this command.
    var onCommand: ((Command) -> Void)?
    /// A shortcut was pressed, as a press and at each repeat.
    var onShortcut: ((Shortcut.Action) -> Void)?
    /// What deciding about a media key depends on; nil while display control is unavailable.
    /// It is asked for only by `updateRouting`.
    var routingContext: (() -> KeyRouting.Context?)?

    /// Why the shortcuts are released at the moment.
    private enum Pause {
        /// A field in Settings is waiting for keys.
        case recording
        /// The app's own menu is open.
        case menu
    }

    private(set) var input = AppStatus.Input()
    private var pauses: Set<Pause> = []
    let watch = KeyWatch()
    private let access = AccessibilityAccess()
    private lazy var keyTap = MediaKeyTap(
        handler: { [unowned self] event, decision in took(event, decision) },
        onDisabled: { [unowned self] in updateKeyTap() })
    private let makeRegistry: (@escaping Hotkeys.Handler) -> any ShortcutRegistry
    private lazy var hotkeys = makeRegistry { [unowned self] action, fine in shortcutPressed(action, fine: fine) }

    /// The shortcuts are registered with macOS through Carbon; tests pass a registry of their
    /// own, which hands them the handler a pressed shortcut calls.
    init(makeRegistry: @escaping (@escaping Hotkeys.Handler) -> any ShortcutRegistry = { Hotkeys(handler: $0) }) {
        self.makeRegistry = makeRegistry
    }

    var keysAreActive: Bool { keyTap.isRunning }
    var accessIsGranted: Bool { access.isGranted }
    var shortcutStatuses: [AppStatus.ShortcutStatus] { hotkeys.statuses }

    var askingIsDisabled: Bool {
        get { access.askingIsDisabled }
        set { access.askingIsDisabled = newValue }
    }

    /// Starts listening. Returns whether this launch should ask the user about access for the
    /// keyboard's own keys.
    func start() -> Bool {
        reloadShortcuts()
        access.onChange = { [unowned self] in updateKeyTap() }
        let shouldAsk = access.start()
        updateRouting()
        updateKeyTap()
        return shouldAsk
    }

    func stop() {
        keyTap.stop()
        watch.stop()
        hotkeys.unregisterAll()
    }

    // MARK: Shortcuts

    /// Registers the shortcuts afresh from the settings. While they are released this waits
    /// until they are taken up again.
    func reloadShortcuts() {
        register(logging: true)
    }

    private func register(logging: Bool) {
        guard pauses.isEmpty else { return }
        hotkeys.reload()
        guard logging else { return }
        let refused = hotkeys.statuses.filter { !$0.registered }.map(\.keys)
        log.notice("Shortcuts registered: \(self.hotkeys.statuses.count - refused.count)")
        if !refused.isEmpty {
            log.error("macOS refused these shortcuts: \(refused.joined(separator: ", "), privacy: .public)")
        }
        let clashing = hotkeys.statuses.filter(\.usedByMacOS).map(\.keys)
        if !clashing.isEmpty {
            log.error("macOS uses these shortcuts itself: \(clashing.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Releases the shortcuts, so that pressing one can be recorded instead of acted on.
    func pauseShortcuts() {
        pause(.recording)
    }

    func resumeShortcuts() {
        resume(.recording)
    }

    /// Whether the app's own menu is open. macOS holds the app's shortcuts back for that time
    /// and delivers them when the menu closes, so they are released while it is open: their
    /// keys then arrive as ordinary key presses, which `takeShortcut` picks out.
    var menuIsOpen = false {
        didSet {
            guard menuIsOpen != oldValue else { return }
            if menuIsOpen { pause(.menu) } else { resume(.menu) }
        }
    }

    /// Takes a key press that the open menu was about to get, if it is one of the shortcuts.
    /// Returns whether it was, in which case the menu must not get it.
    func takeShortcut(from event: NSEvent) -> Bool {
        guard menuIsOpen, let shortcut = Shortcut(keyPress: event),
            let binding = Hotkeys.binding(
                for: shortcut, among: ShortcutSettings.shortcuts, quarterStep: ShortcutSettings.quarterStep)
        else { return false }
        // A held key repeats by itself here, at the keyboard's own pace. Mute does not repeat.
        if !event.isARepeat || binding.action.repeatsWhileHeld { shortcutPressed(binding.action, fine: binding.fine) }
        return true
    }

    private func pause(_ reason: Pause) {
        pauses.insert(reason)
        hotkeys.unregisterAll()
    }

    private func resume(_ reason: Pause) {
        pauses.remove(reason)
        // Coming back from the menu is no news for the log; what was just recorded may be.
        register(logging: reason == .recording)
    }

    /// Whether macOS accepts the shortcut. Meant for when the app's own shortcuts are paused.
    func canRegister(_ shortcut: Shortcut) -> Bool {
        Hotkeys.canRegister(shortcut)
    }

    /// The shortcuts macOS has switched on for itself.
    var shortcutsUsedByMacOS: [Shortcut] { Hotkeys.usedByMacOS() }

    func stopRepeating() {
        hotkeys.stopRepeating()
    }

    private func shortcutPressed(_ action: Shortcut.Action, fine: Bool) {
        input.shortcutPresses += 1
        input.record("shortcut \(action.rawValue)")
        log.debug("Shortcut \(action.rawValue, privacy: .public)")
        onShortcut?(action)
        onCommand?(action.command(fine: fine))
    }

    // MARK: The keyboard's own keys

    /// Asks for Accessibility access; an explicit request also turns asking back on.
    func requestAccess() {
        askingIsDisabled = false
        access.request()
    }

    /// Starts the key tap when Accessibility access is there and removes it when it is not.
    func updateKeyTap() {
        let wasRunning = keyTap.isRunning
        if !(access.isGranted && keyTap.start()) { keyTap.stop() }
        if keyTap.isRunning != wasRunning {
            log.notice("Keyboard key tap \(self.keyTap.isRunning ? "started" : "stopped", privacy: .public)")
        }
    }

    /// Sends a simulated volume-up key through the system, to prove that such keys reach the app.
    func postTestKey() {
        for isDown in [true, false] {
            let state = isDown ? 0xA : 0xB
            NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: Int16(AuxiliaryKey.eventSubtype),
                data1: state << 8, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Gives the key tap a fresh copy of what its decisions depend on. The tap decides on a
    /// thread of its own and cannot ask, so this is called whenever the displays, the sound
    /// output or the arrangement of the screens changes.
    func updateRouting() {
        keyTap.routing = routingContext?()
    }

    /// Takes note of a key press the tap has decided about, and runs its command.
    func took(_ event: MediaKeyEvent, _ decision: KeyRouting.Decision) {
        let handled = decision != .passThrough
        if handled { input.keysHandled += 1 } else { input.keysLeftToSystem += 1 }
        input.record("key \(event.key), \(handled ? "handled" : "left to macOS")")
        log.debug("Key \(String(describing: event.key), privacy: .public), handled: \(handled, privacy: .public)")
        if case .run(let command) = decision { onCommand?(command) }
        // Should a change ever have gone unnoticed, it is picked up here for the presses that follow.
        updateRouting()
    }
}
