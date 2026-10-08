import AppKit
import DisplayKeysCore

/// Everything that comes from the keyboard: the keyboard's own media keys (which need
/// Accessibility access) and the global shortcuts (which do not).
@MainActor
final class KeyboardInput {
    /// A key or shortcut asked for this command.
    var onCommand: ((Command) -> Void)?
    /// What deciding about a media key depends on; nil while display control is unavailable.
    var routingContext: (() -> KeyRouting.Context?)?

    private(set) var input = AppStatus.Input()
    let watch = KeyWatch()
    private let access = AccessibilityAccess()
    private lazy var keyTap = MediaKeyTap(
        handler: { [unowned self] event, fine in handle(event, fine: fine) },
        onDisabled: { [unowned self] in updateKeyTap() })
    private lazy var hotkeys = Hotkeys { [unowned self] action, fine in shortcutPressed(action, fine: fine) }

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
        updateKeyTap()
        return shouldAsk
    }

    func stop() {
        keyTap.stop()
        watch.stop()
        hotkeys.unregisterAll()
    }

    // MARK: Shortcuts

    func reloadShortcuts() {
        hotkeys.reload()
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
        hotkeys.unregisterAll()
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
                timestamp: 0, windowNumber: 0, context: nil, subtype: Int16(MediaKeyEvent.auxControlButtonsSubtype),
                data1: state << 8, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Handles a media key; returns false to leave it to macOS.
    private func handle(_ event: MediaKeyEvent, fine: Bool) -> Bool {
        guard let context = routingContext?() else { return false }
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
            onCommand?(command)
            return true
        }
    }
}
