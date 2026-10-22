import AppKit
import Carbon.HIToolbox
import HushglowCore

/// What `KeyboardInput` needs from the global shortcuts. Tests stand in for it, so that they
/// register nothing with macOS.
@MainActor
protocol ShortcutRegistry: AnyObject {
    /// One entry per shortcut that was asked for, including those macOS refused.
    var statuses: [AppStatus.ShortcutStatus] { get }
    /// Registers the configured shortcuts, replacing any earlier registration.
    func reload()
    func unregisterAll()
    func stopRepeating()
}

/// The repeat of a held shortcut. Carbon reports a press and a release and nothing in between,
/// so the steps between them are made here, at the keyboard's own pace.
@MainActor
final class ShortcutRepeat {
    /// Something that fires until it is stopped, as a repeating timer does.
    typealias Ticker =
        @MainActor (_ pace: Hotkeys.RepeatPace, _ fire: @escaping @MainActor () -> Void) ->
        any RepeatTicker

    /// Stops a repeat whose release was never delivered; enough to cross the whole range.
    static let maximumRepeats = Level.fineSteps

    private let pace: @MainActor () -> Hotkeys.RepeatPace?
    private let ticker: Ticker
    private var running: (any RepeatTicker)?
    /// The shortcut being held, and how many times it has repeated.
    private(set) var held: (id: UInt32, count: Int)?

    /// The pace is read at each press, and so follows a change in System Settings.
    init(
        pace: @escaping @MainActor () -> Hotkeys.RepeatPace? = { Hotkeys.repeatPace() },
        ticker: @escaping Ticker = ShortcutRepeat.timer
    ) {
        self.pace = pace
        self.ticker = ticker
    }

    /// A shortcut was pressed: its repeat starts after the keyboard's delay, unless it does not
    /// repeat or key repeat is switched off. Any other repeat stops.
    func pressed(_ id: UInt32, repeats: Bool, step: @escaping @MainActor () -> Void) {
        stop()
        guard repeats, let pace = pace() else { return }
        held = (id, 0)
        running = ticker(pace) { [weak self] in self?.fired(step) }
    }

    /// A shortcut was let go; only its own repeat stops.
    func released(_ id: UInt32) {
        if held?.id == id { stop() }
    }

    func stop() {
        running?.stop()
        running = nil
        held = nil
    }

    private func fired(_ step: @MainActor () -> Void) {
        guard let current = held, current.count < Self.maximumRepeats else { return stop() }
        held = (current.id, current.count + 1)
        step()
    }

    /// A timer on the main run loop, in every mode, so that an open menu does not hold it up.
    static func timer(_ pace: Hotkeys.RepeatPace, _ fire: @escaping @MainActor () -> Void) -> any RepeatTicker {
        let timer = Timer(timeInterval: pace.interval, repeats: true) { _ in MainActor.assumeIsolated { fire() } }
        timer.fireDate = Date(timeIntervalSinceNow: pace.delay)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// A repeat that runs until it is stopped.
@MainActor
protocol RepeatTicker {
    func stop()
}

extension Timer: RepeatTicker {
    func stop() { invalidate() }
}

/// Global shortcuts through Carbon hot keys, which need no permission and cost nothing while idle.
@MainActor
final class Hotkeys: NSObject, ShortcutRegistry {
    typealias Handler = @MainActor (Shortcut.Action, _ fine: Bool) -> Void

    private struct Registration {
        let reference: EventHotKeyRef
        let action: Shortcut.Action
        let fine: Bool
    }

    /// How a held shortcut repeats: the wait before the first repeat, and the time between two.
    struct RepeatPace: Equatable {
        var delay: TimeInterval
        var interval: TimeInterval
    }

    private static let signature: OSType = 0x4847_4C57  // "HGLW"
    /// One unit of the system's Key Repeat setting; the fastest pace System Settings offers is two.
    static let shortestRepeatInterval: TimeInterval = 1.0 / 60
    /// The slowest pace System Settings offers is two seconds. Switched off, key repeat is
    /// reported as an interval of more than an hour.
    private static let longestRepeatInterval: TimeInterval = 60

    /// One entry per shortcut that was asked for, including those macOS refused.
    private(set) var statuses: [AppStatus.ShortcutStatus] = []

    private let handler: Handler
    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private let repeating = ShortcutRepeat()

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Registers the configured shortcuts, replacing any earlier registration. With quarter
    /// steps switched on, each stepping shortcut is also registered with their modifier added.
    func reload() {
        unregisterAll()
        installEventHandler()
        let quarterStep = ShortcutSettings.quarterStep
        let system = Self.usedByMacOS()
        for (index, action) in Shortcut.Action.allCases.enumerated() {
            guard let shortcut = ShortcutSettings.shortcut(for: action) else { continue }
            // The shortcut itself, then the one for quarter steps when there is one.
            for (offset, keys) in shortcut.claimed(for: action, quarterStep: quarterStep).enumerated() {
                register(keys, id: UInt32(index * 2 + offset), action: action, fine: offset == 1, system: system)
            }
        }
    }

    /// The shortcuts macOS has switched on for itself, such as Mission Control on Ctrl-Up, as
    /// far as they use keys this app's shortcuts can use. macOS accepts the registration of a
    /// shortcut it uses itself, so this list is the only way to notice such a clash.
    static func usedByMacOS() -> [Shortcut] {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                let keyCode = entry[kHISymbolicHotKeyCode as String] as? Int,
                let flags = entry[kHISymbolicHotKeyModifiers as String] as? Int
            else { return nil }
            return shortcut(keyCode: keyCode, carbonFlags: flags)
        }
    }

    /// A shortcut from Carbon's form. Other flags are ignored: macOS sets one on every arrow
    /// and function key, whether or not Fn is held.
    static func shortcut(keyCode: Int, carbonFlags flags: Int) -> Shortcut? {
        var modifiers: Shortcut.Modifiers = []
        if flags & cmdKey != 0 { modifiers.insert(.command) }
        if flags & shiftKey != 0 { modifiers.insert(.shift) }
        if flags & optionKey != 0 { modifiers.insert(.option) }
        if flags & controlKey != 0 { modifiers.insert(.control) }
        return Shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    /// Tries the shortcut and lets it go again.
    static func canRegister(_ shortcut: Shortcut) -> Bool {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), carbonFlags(shortcut.modifiers), EventHotKeyID(signature: signature, id: .max),
            GetEventDispatcherTarget(), 0, &reference)
        if let reference { UnregisterEventHotKey(reference) }
        return status == noErr
    }

    private static func carbonFlags(_ modifiers: Shortcut.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }

    /// Which action a shortcut stands for, and whether as a quarter step, given every action's
    /// shortcut. It answers for a key press what registering does for a hot key.
    static func binding(
        for shortcut: Shortcut, among shortcuts: [Shortcut.Action: Shortcut], quarterStep: Shortcut.Modifiers?
    ) -> (action: Shortcut.Action, fine: Bool)? {
        for action in Shortcut.Action.allCases {
            guard let claimed = shortcuts[action]?.claimed(for: action, quarterStep: quarterStep),
                let index = claimed.firstIndex(of: shortcut)
            else { continue }
            return (action, index == 1)
        }
        return nil
    }

    /// The pace of the keyboard's own key repeat, from System Settings → Keyboard, so that a
    /// held shortcut repeats as any held key does. nil when key repeat is switched off there.
    static func repeatPace(
        delay: TimeInterval = NSEvent.keyRepeatDelay, interval: TimeInterval = NSEvent.keyRepeatInterval
    ) -> RepeatPace? {
        guard interval <= longestRepeatInterval else { return nil }
        // No setting goes below this. Should a value ever do, a held shortcut must not cross
        // the whole range in an instant.
        let interval = max(interval, shortestRepeatInterval)
        return RepeatPace(delay: max(delay, interval), interval: interval)
    }

    func unregisterAll() {
        stopRepeating()
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        registrations.removeAll()
        statuses.removeAll()
    }

    func stopRepeating() {
        repeating.stop()
    }

    fileprivate func handle(id: UInt32, pressed: Bool) {
        guard let registration = registrations[id] else { return }
        guard pressed else { return repeating.released(id) }
        handler(registration.action, registration.fine)
        repeating.pressed(id, repeats: registration.action.repeatsWhileHeld) { [weak self] in
            // A shortcut unregistered while held, as when the menu opens, repeats no more.
            guard let self else { return }
            guard registrations[id] != nil else { return stopRepeating() }
            handler(registration.action, registration.fine)
        }
    }

    private func register(_ shortcut: Shortcut, id: UInt32, action: Shortcut.Action, fine: Bool, system: [Shortcut]) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), Self.carbonFlags(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: id), GetEventDispatcherTarget(), 0, &reference)
        if status == noErr, let reference {
            registrations[id] = Registration(reference: reference, action: action, fine: fine)
        }
        statuses.append(
            AppStatus.ShortcutStatus(
                action: action.rawValue, keys: shortcut.text, registered: registrations[id] != nil,
                usedByMacOS: system.contains(shortcut)))
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(), hotkeyCallback, eventTypes.count, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
    }
}

private func hotkeyCallback(_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { hotkeys.handle(id: id, pressed: pressed) }
    return noErr
}
