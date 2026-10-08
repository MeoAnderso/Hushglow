import AppKit
import DisplayKeysCore

/// Intercepts the keyboard's own brightness, volume and mute keys with a session event tap.
///
/// Needs Accessibility access. The tap only receives system-defined events, never ordinary
/// keystrokes, and its callback runs on the main run loop, so it must stay cheap.
@MainActor
final class MediaKeyTap {
    /// Returns true when the key was handled and must not reach the system.
    typealias Handler = @MainActor (MediaKeyEvent, _ fine: Bool) -> Bool

    private let handler: Handler
    private let onDisabled: @MainActor () -> Void
    private var tap: EventTap?

    var isRunning: Bool { tap != nil }

    init(handler: @escaping Handler, onDisabled: @escaping @MainActor () -> Void) {
        self.handler = handler
        self.onDisabled = onDisabled
    }

    /// Installs the tap; false when macOS refuses it, which means Accessibility access is missing.
    @discardableResult
    func start() -> Bool {
        if tap == nil {
            tap = EventTap(
                eventTypes: [EventTap.systemDefined], options: .defaultTap, callback: mediaKeyTapCallback, owner: self)
        }
        return tap != nil
    }

    func stop() {
        tap?.remove()
        tap = nil
    }

    fileprivate func handle(subtype: Int, data1: Int, fine: Bool) -> Bool {
        guard let event = MediaKeyEvent(subtype: subtype, data1: data1) else { return false }
        return handler(event, fine)
    }

    /// macOS disables a tap that responds slowly, or when Accessibility access is withdrawn.
    /// A tap left installed without access stalls keyboard and mouse input, so it is removed.
    fileprivate func recover() {
        guard let tap else { return }
        if AXIsProcessTrusted() {
            tap.enable()
        } else {
            stop()
            onDisabled()
        }
    }
}

private func mediaKeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)
    guard let userInfo else { return passthrough }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.recover() }
        return passthrough
    }
    guard type.rawValue == EventTap.systemDefined, let keyEvent = NSEvent(cgEvent: event) else { return passthrough }
    let subtype = Int(keyEvent.subtype.rawValue)
    let data1 = keyEvent.data1
    // Shift-Option selects quarter steps, as it does for the system's own keys.
    let fine = keyEvent.modifierFlags.isSuperset(of: [.shift, .option])
    let handled = MainActor.assumeIsolated { tap.handle(subtype: subtype, data1: data1, fine: fine) }
    return handled ? nil : passthrough
}
