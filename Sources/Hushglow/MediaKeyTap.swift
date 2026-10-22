import AppKit
import HushglowCore
import Synchronization

/// Intercepts the keyboard's own brightness, volume and mute keys with a session event tap.
///
/// Needs Accessibility access. The tap receives system-defined events only, never ordinary
/// keystrokes. It can swallow them, though, so each one waits for the tap's answer, and mouse
/// buttons report through such events as well. The tap therefore has a thread of its own,
/// which decides from a copy of what the decision depends on and tells the main thread
/// afterwards. An event never waits for the main thread.
@MainActor
final class MediaKeyTap {
    /// Called on the main thread with a key press that the tap has already decided about.
    typealias Handler = @MainActor (MediaKeyEvent, KeyRouting.Decision) -> Void

    private let handler: Handler
    private let onDisabled: @MainActor () -> Void
    private lazy var router = KeyRouter(handler: handler, onDisabled: { [weak self] in self?.recover() })
    private var tap: EventTap?

    var isRunning: Bool { tap != nil }

    /// What deciding about a key depends on; nil while every key is to be left to macOS. The
    /// tap's thread cannot ask for it, so it has to be set again whenever something in it changes.
    var routing: KeyRouting.Context? {
        get { router.context }
        set { router.context = newValue }
    }

    init(handler: @escaping Handler, onDisabled: @escaping @MainActor () -> Void) {
        self.handler = handler
        self.onDisabled = onDisabled
    }

    /// Installs the tap; false when macOS refuses it, which means Accessibility access is missing.
    @discardableResult
    func start() -> Bool {
        if tap == nil {
            tap = EventTap(
                eventTypes: [EventTap.systemDefined], options: .defaultTap, callback: mediaKeyTapCallback,
                owner: router, onOwnThread: true)
        }
        return tap != nil
    }

    func stop() {
        tap?.remove()
        tap = nil
    }

    /// macOS disables a tap that responds slowly, or when Accessibility access is withdrawn.
    /// A tap left installed without access stalls keyboard and mouse input, so it is removed.
    private func recover() {
        guard let tap else { return }
        if AXIsProcessTrusted() {
            tap.enable()
        } else {
            stop()
            onDisabled()
        }
    }
}

/// What the tap's thread works with: a copy of the routing context, which the main thread
/// replaces whenever something in it changes, and the way to tell the main thread what was
/// decided. Deciding about a key needs nothing else, so it can happen on any thread.
final class KeyRouter: Sendable {
    private let handler: MediaKeyTap.Handler
    private let onDisabled: @MainActor () -> Void
    private let snapshot = Mutex<KeyRouting.Context?>(nil)

    init(handler: @escaping MediaKeyTap.Handler, onDisabled: @escaping @MainActor () -> Void) {
        self.handler = handler
        self.onDisabled = onDisabled
    }

    var context: KeyRouting.Context? {
        get { snapshot.withLock { $0 } }
        set { snapshot.withLock { $0 = newValue } }
    }

    /// Decides about an event from `NSEvent.subtype` and `NSEvent.data1`. Returns whether it
    /// is a key of the app's, which must not reach macOS. The main thread hears of every
    /// press afterwards, in the order they came, and runs the command if there is one.
    func route(subtype: Int, data1: Int, fine: Bool) -> Bool {
        guard let event = MediaKeyEvent(subtype: subtype, data1: data1), let context else { return false }
        let decision = KeyRouting.decide(event, fine: fine, in: context)
        if event.isDown {
            let handler = handler
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(event, decision) }
            }
        }
        return decision != .passThrough
    }

    /// Passes on that macOS has switched the tap off.
    func tapWasDisabled() {
        let onDisabled = onDisabled
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onDisabled() }
        }
    }
}

/// Runs on the tap's thread.
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)
    guard let userInfo else { return passthrough }
    let router = Unmanaged<KeyRouter>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        router.tapWasDisabled()
        return passthrough
    }
    guard type.rawValue == EventTap.systemDefined else { return passthrough }
    // This thread never returns to an event loop that would empty a pool for it.
    let isTheApps = autoreleasepool {
        guard let keyEvent = NSEvent(cgEvent: event) else { return false }
        // Shift-Option selects quarter steps, as it does for the system's own keys.
        let fine = event.flags.isSuperset(of: [.maskShift, .maskAlternate])
        return router.route(subtype: Int(keyEvent.subtype.rawValue), data1: keyEvent.data1, fine: fine)
    }
    return isTheApps ? nil : passthrough
}
