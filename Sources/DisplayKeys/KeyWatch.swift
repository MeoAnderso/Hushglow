import AppKit
import DisplayKeysCore

/// A short recording, started by the user, of the special keys that reach the app. It answers
/// the question "what does this keyboard's volume key actually send?".
///
/// Only media keys and function or navigation keys are recorded. Letters, digits and
/// punctuation are never recorded, and nothing is kept after the app quits.
@MainActor
final class KeyWatch {
    private static let limit = 40

    /// What the last watch saw; nil until one has run.
    private(set) var seen: [String]?
    private(set) var isWatching = false
    /// Called when a watch that was running stops, whether its time is up or it was cut short.
    var onEnd: (() -> Void)?
    private var tap: EventTap?
    private var session = 0

    /// Watches for the given time. Returns false when macOS refuses, which means Accessibility
    /// access is missing.
    @discardableResult
    func start(for seconds: TimeInterval) -> Bool {
        stop()
        // The watch only looks, so the tap only listens. A tap that could also change events
        // would make every key press in every app wait for this one's main thread.
        guard
            let tap = EventTap(
                eventTypes: [CGEventType.keyDown.rawValue, EventTap.systemDefined], options: .listenOnly,
                callback: keyWatchCallback, owner: self)
        else { return false }
        self.tap = tap
        seen = []
        isWatching = true
        session += 1
        let session = session
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                if session == self.session { self.stop() }
            }
        }
        return true
    }

    func stop() {
        isWatching = false
        guard let tap else { return }
        tap.remove()
        self.tap = nil
        onEnd?()
    }

    fileprivate func record(_ description: String) {
        guard isWatching, (seen?.count ?? 0) < Self.limit else { return }
        seen?.append(description)
    }

    fileprivate nonisolated static func describe(type: CGEventType, event: NSEvent) -> String? {
        if type == .keyDown {
            // Function and navigation keys report characters in a private Unicode range; ordinary
            // typing does not, and is left alone.
            let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first?.value
            guard scalar == nil || (0xF700...0xF8FF).contains(scalar!) else { return nil }
            let code = Int(event.keyCode)
            return "key \(Shortcut.keyName(for: code) ?? "code \(code)")"
        }
        guard let key = AuxiliaryKey(subtype: Int(event.subtype.rawValue), data1: event.data1), key.isDown
        else { return nil }
        return "media key \(key.name)"
    }
}

private func keyWatchCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)
    guard let userInfo, type == .keyDown || type.rawValue == EventTap.systemDefined,
        let keyEvent = NSEvent(cgEvent: event), let description = KeyWatch.describe(type: type, event: keyEvent)
    else { return passthrough }
    let watch = Unmanaged<KeyWatch>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated { watch.record(description) }
    return passthrough
}
