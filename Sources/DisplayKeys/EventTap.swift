import CoreGraphics
import Foundation

/// A tap on the session's events, served by the main run loop. Installing one needs
/// Accessibility access.
@MainActor
final class EventTap {
    /// NX_SYSDEFINED: the event type that carries media keys. CGEventType has no case for it.
    nonisolated static let systemDefined: UInt32 = 14

    private let port: CFMachPort
    private let source: CFRunLoopSource

    /// Installs the tap and switches it on; nil when macOS refuses it, which means that
    /// Accessibility access is missing.
    init?(eventTypes: [UInt32], options: CGEventTapOptions, callback: CGEventTapCallBack, owner: AnyObject) {
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1) }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: options, eventsOfInterest: mask,
                callback: callback, userInfo: Unmanaged.passUnretained(owner).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
    }

    /// Switches the tap back on after macOS has switched it off.
    func enable() {
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func remove() {
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(port)
    }
}
