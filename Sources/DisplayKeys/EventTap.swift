import CoreGraphics
import Foundation

/// A tap on the session's events. Installing one needs Accessibility access.
///
/// A tap that only listens is served by the main run loop. One that can hold events back is
/// given a thread of its own: every event it is shown waits for its answer, and that answer
/// must not wait for whatever the main thread happens to be doing.
@MainActor
final class EventTap {
    /// NX_SYSDEFINED: the event type that carries media keys. CGEventType has no case for it.
    nonisolated static let systemDefined: UInt32 = 14

    private let port: CFMachPort
    private let source: CFRunLoopSource
    /// The thread that serves the tap, when it is not the main one.
    private let thread: RunLoopThread?

    /// Installs the tap and switches it on; nil when macOS refuses it, which means that
    /// Accessibility access is missing. The callback is handed `owner`. On a thread of its
    /// own it can run at any moment, so the thread keeps `owner` for as long as it lives.
    init?(
        eventTypes: [UInt32], options: CGEventTapOptions, callback: CGEventTapCallBack, owner: AnyObject,
        onOwnThread: Bool = false
    ) {
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1) }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: options, eventsOfInterest: mask,
                callback: callback, userInfo: Unmanaged.passUnretained(owner).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else { return nil }
        if onOwnThread {
            let thread = RunLoopThread(serving: source, keeping: owner, name: "Event tap")
            thread.startServing()
            self.thread = thread
        } else {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            thread = nil
        }
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
        if let thread {
            thread.stopServing()
        } else {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(port)
    }
}

/// A thread that serves one run loop source and nothing else. It sleeps until the source has
/// something for it, and ends when the source is taken away again.
final class RunLoopThread: Thread, @unchecked Sendable {
    private let source: CFRunLoopSource
    /// What the source's callback works with, kept for as long as the callback can still run.
    private let context: AnyObject
    private let isServing = DispatchSemaphore(value: 0)
    /// Set by the thread itself before it reports that it is serving, and only read after.
    private var runLoop: CFRunLoop?

    init(serving source: CFRunLoopSource, keeping context: AnyObject, name: String) {
        self.source = source
        self.context = context
        super.init()
        self.name = name
        // Whoever sent the event is waiting for it.
        qualityOfService = .userInteractive
    }

    /// Starts the thread, and returns once its run loop has the source.
    func startServing() {
        start()
        isServing.wait()
    }

    override func main() {
        let runLoop = CFRunLoopGetCurrent()
        self.runLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        isServing.signal()
        CFRunLoopRun()
    }

    /// Takes the source away, which leaves the run loop nothing to wait for, and the thread ends.
    func stopServing() {
        guard let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFRunLoopStop(runLoop)
    }
}
