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
        for (index, action) in Shortcut.Action.allCases.enumerated() {
            guard let keys = ShortcutSettings.text(for: action), let shortcut = Shortcut(keys) else { continue }
            register(
                shortcut.keyCode, shortcut.modifiers, keys: keys, id: UInt32(index * 2), action: action, fine: false)
            if quarterSteps, action.repeatsWhileHeld, !shortcut.modifiers.contains(.shift) {
                let modifiers = shortcut.modifiers.union(.shift)
                register(
                    shortcut.keyCode, modifiers, keys: "shift+\(keys)", id: UInt32(index * 2 + 1), action: action,
                    fine: true)
            }
        }
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
        _ keyCode: Int, _ modifiers: Shortcut.Modifiers, keys: String, id: UInt32, action: Shortcut.Action, fine: Bool
    ) {
        var carbonModifiers = 0
        if modifiers.contains(.command) { carbonModifiers |= cmdKey }
        if modifiers.contains(.shift) { carbonModifiers |= shiftKey }
        if modifiers.contains(.option) { carbonModifiers |= optionKey }
        if modifiers.contains(.control) { carbonModifiers |= controlKey }

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(carbonModifiers), EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(), 0, &reference
        )
        if status == noErr, let reference {
            registrations[id] = Registration(reference: reference, action: action, fine: fine)
        }
        statuses.append(
            AppStatus.ShortcutStatus(action: action.rawValue, keys: keys, registered: registrations[id] != nil))
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
