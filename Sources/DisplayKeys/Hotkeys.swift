import AppKit
import Carbon.HIToolbox
import DisplayKeysCore

/// Global shortcuts through Carbon hot keys, which need no permission and cost nothing while idle.
@MainActor
final class Hotkeys: NSObject {
    typealias Handler = @MainActor (Shortcut.Action, _ fine: Bool) -> Void

    private struct Registration {
        let reference: EventHotKeyRef
        let action: Shortcut.Action
        let fine: Bool
    }

    private static let signature: OSType = 0x444B_4559  // "DKEY"
    private static let repeatDelay: TimeInterval = 0.4
    private static let repeatInterval: TimeInterval = 0.07
    /// Stops a repeat whose key release was never delivered; enough to cross the whole range.
    private static let maximumRepeats = Level.fineSteps

    /// One entry per shortcut that was asked for, including those macOS refused.
    private(set) var statuses: [AppStatus.ShortcutStatus] = []

    private let handler: Handler
    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var repeatTimer: Timer?
    private var repeating: (id: UInt32, count: Int)?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Registers the configured shortcuts, replacing any earlier registration. With quarter
    /// steps switched on, each stepping shortcut is also registered with Shift added.
    func reload() {
        unregisterAll()
        installEventHandler()
        let quarterSteps = ShortcutSettings.quarterSteps
        let system = Self.usedByMacOS()
        for (index, action) in Shortcut.Action.allCases.enumerated() {
            guard let keys = ShortcutSettings.text(for: action), let shortcut = Shortcut(keys) else { continue }
            register(shortcut, keys: keys, id: UInt32(index * 2), action: action, fine: false, system: system)
            if quarterSteps, action.repeatsWhileHeld, let quarter = shortcut.quarterStepVariant {
                register(
                    quarter, keys: "shift+\(keys)", id: UInt32(index * 2 + 1), action: action, fine: true,
                    system: system)
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

    func unregisterAll() {
        stopRepeating()
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        registrations.removeAll()
        statuses.removeAll()
    }

    func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeating = nil
    }

    fileprivate func handle(id: UInt32, pressed: Bool) {
        guard let registration = registrations[id] else { return }
        guard pressed else {
            if repeating?.id == id { stopRepeating() }
            return
        }
        stopRepeating()
        handler(registration.action, registration.fine)
        guard registration.action.repeatsWhileHeld else { return }
        // Carbon reports only press and release, so holding the shortcut is repeated here.
        repeating = (id, 0)
        let timer = Timer(
            fireAt: Date(timeIntervalSinceNow: Self.repeatDelay), interval: Self.repeatInterval,
            target: self, selector: #selector(repeatFired), userInfo: nil, repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    @objc private func repeatFired() {
        guard let current = repeating, let registration = registrations[current.id], current.count < Self.maximumRepeats
        else { return stopRepeating() }
        repeating = (current.id, current.count + 1)
        handler(registration.action, registration.fine)
    }

    private func register(
        _ shortcut: Shortcut, keys: String, id: UInt32, action: Shortcut.Action, fine: Bool, system: [Shortcut]
    ) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), Self.carbonFlags(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: id), GetEventDispatcherTarget(), 0, &reference)
        if status == noErr, let reference {
            registrations[id] = Registration(reference: reference, action: action, fine: fine)
        }
        statuses.append(
            AppStatus.ShortcutStatus(
                action: action.rawValue, keys: keys, registered: registrations[id] != nil,
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
