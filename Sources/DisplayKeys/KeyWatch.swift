import AppKit
import DisplayKeysCore

/// NX_SYSDEFINED: the event type that carries media keys.
private let systemDefinedEventType: UInt32 = 14

/// A short recording, started by the user, of the special keys that reach the app. It answers
/// the question "what does this keyboard's volume key actually send?".
///
/// Only media keys and function or navigation keys are recorded. Letters, digits and
/// punctuation are never recorded, and nothing is kept after the app quits.
@MainActor
final class KeyWatch {
    private static let limit = 40
    private nonisolated static let mediaKeyNames = [
        0: "volume up", 1: "volume down", 2: "brightness up", 3: "brightness down", 7: "mute",
        16: "play/pause", 17: "next", 18: "previous", 19: "fast forward", 20: "rewind",
    ]

    /// What the last watch saw; nil until one has run.
    private(set) var seen: [String]?
    private(set) var isWatching = false
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var session = 0

    /// Watches for the given time. Returns false when macOS refuses, which means Accessibility
    /// access is missing.
    @discardableResult
    func start(for seconds: TimeInterval) -> Bool {
        stop()
        let mask =
            CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue) | CGEventMask(1)
            << CGEventMask(systemDefinedEventType)
        // The watch only looks, so the tap only listens. A tap that could also change events
        // would make every key press in every app wait for this one's main thread.
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                callback: keyWatchCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
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
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
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
        guard event.subtype.rawValue == MediaKeyEvent.auxControlButtonsSubtype else { return nil }
        let code = (event.data1 & 0xFFFF_0000) >> 16
        let isDown = (event.data1 & 0xFF00) >> 8 == 0xA
        return isDown ? "media key \(mediaKeyNames[code] ?? "code \(code)")" : nil
    }
}

private func keyWatchCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)
    guard let userInfo, type == .keyDown || type.rawValue == systemDefinedEventType,
        let keyEvent = NSEvent(cgEvent: event), let description = KeyWatch.describe(type: type, event: keyEvent)
    else { return passthrough }
    let watch = Unmanaged<KeyWatch>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated { watch.record(description) }
    return passthrough
}
