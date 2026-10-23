import Foundation

/// The link to the displays: discovery, plus reading and writing one feature at a time.
/// Calls block while they talk to a display, so they are made off the main thread.
public protocol DisplayTransport: Sendable {
    associatedtype Handle: AnyObject & Sendable

    /// One handle per external display, whether or not the display speaks DDC.
    func displays() -> [Handle]
    /// Reads a feature; nil when the display does not answer or does not implement it.
    func get(_ display: Handle, _ feature: DDC.Feature) -> DDC.Value?
    /// Writes a feature. Success means the bytes were sent, not that the display honoured them.
    func set(_ display: Handle, _ feature: DDC.Feature, value: Int) -> Bool
    /// Whether two handles, from two searches, stand for the same display; false when that
    /// cannot be told.
    func isSame(_ display: Handle, as other: Handle) -> Bool
}

extension DisplayTransport {
    /// Only a handle is the same as itself, for a transport whose searches hand out new ones.
    public func isSame(_ display: Handle, as other: Handle) -> Bool {
        display === other
    }

    public func state(of display: Handle) -> DisplayState {
        let brightness = get(display, .brightness)
        let volume = get(display, .volume)
        // A display that answers nothing is not asked for more.
        guard brightness != nil || volume != nil else {
            return DisplayState(brightness: nil, volume: nil, mute: nil)
        }
        return DisplayState(
            brightness: brightness, volume: volume, mute: get(display, .mute), contrast: get(display, .contrast),
            input: get(display, .input))
    }
}

/// A reading from a display that disagreed with the cache.
public struct DisplayMismatch: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The value was changed outside the app, for example with the display's own buttons.
        case changedOutside
        /// The display kept the value it had before the app wrote to it.
        case writeRefused
        /// The display took the write but settled on a different value.
        case writeAdjusted
    }

    public var feature: DDC.Feature
    public var cached: Int
    public var actual: Int
    public var kind: Kind
}

/// The connected DDC displays, a session for each, and the search for them.
///
/// Each display has a session of its own (`DisplaySession`) with its cache and its account of
/// what has been heard from it. This finds the displays, keeps one session per display that
/// answers DDC, and hands each command to the sessions it is for: all of them, or those asked.
@MainActor
public final class Displays<Transport: DisplayTransport> {
    public struct Timing: Sendable {
        /// A display that is still waking up does not answer yet, so discovery is retried.
        public var retryDelays: [TimeInterval] = [2, 5, 10]
        /// How long after the last write a control is read back.
        public var verifyDelay: TimeInterval = 1.5
        /// How long a cached value is trusted without hearing from the display. Short enough
        /// that each new burst of key presses starts by reading the display.
        public var staleAfter: TimeInterval = 5
        /// How often, at most, a command that finds no display under control has the displays
        /// looked for again, while some stayed silent.
        public var lookAgainAfter: TimeInterval = 5

        public init() {}
    }

    /// Receives the level to show. For a stale value it is called twice: at once with the
    /// expected result, then with the real one (`isFinal`) after the display has been read.
    /// The level is nil when no display has the control.
    public typealias FeedbackHandler = @MainActor (_ feedback: Feedback?, _ isFinal: Bool) -> Void

    public var onChange: (() -> Void)?
    public var onMismatch: ((DisplayMismatch) -> Void)?
    /// Reports how long a read of a display took.
    public var onRead: ((_ features: [DDC.Feature], _ duration: TimeInterval) -> Void)?

    private let transport: Transport
    private let queue: DispatchQueue
    private let timing: Timing
    private let now: () -> Date
    private let writer: CoalescingWriter<Transport.Handle, DDC.Feature>

    /// One per display that answers DDC, in the order the displays were found.
    public private(set) var sessions: [DisplaySession<Transport>] = []
    /// How many steps a screen may be dimmed below its display's lowest brightness; 0 turns
    /// dimming off, and takes off any there is.
    public var maximumDimming = 0 {
        didSet { applyDimmingLimits() }
    }
    /// Whether a display's screen can be dimmed; nil for every display. One whose screen is not
    /// known has no overlay to darken it, so its brightness keys stop at its lowest.
    public var canDim: ((Transport.Handle) -> Bool)? {
        didSet { applyDimmingLimits() }
    }
    /// Supersedes discoveries that are still in flight.
    private var generation = 0
    /// Counts commands per control, so that one applied while the displays were being looked
    /// for is read back from what was found.
    private var commandCounts: [Command.Control: Int] = [:]
    /// How many displays stayed silent through a whole round of retries. They are taken to
    /// have no DDC, and are not waited for again.
    private var knownSilent = 0
    /// When a command last had the displays looked for again.
    private var lookedAgainAt: Date?

    public init(
        transport: Transport, queue: DispatchQueue, timing: Timing = Timing(), now: @escaping () -> Date = Date.init,
        onWriteFailure: @escaping @Sendable () -> Void
    ) {
        self.transport = transport
        self.queue = queue
        self.timing = timing
        self.now = now
        writer = CoalescingWriter(queue: queue) { display, feature, value in
            if !transport.set(display, feature, value: value) { onWriteFailure() }
        }
    }

    /// The first display's state.
    public var primary: DisplayState? { sessions.first?.state }
    /// The displays that answer DDC, which commands go to.
    public var controlled: [Transport.Handle] { sessions.map(\.display) }
    public var hasBrightness: Bool { sessions.contains { $0.has(.brightness) } }
    public var hasVolume: Bool { sessions.contains { $0.has(.volume) } }

    /// The state of one display; nil when it is not one under control.
    public func state(of display: Transport.Handle) -> DisplayState? {
        session(for: display)?.state
    }

    /// Rediscovers the displays and re-reads their state. Newer calls supersede older ones.
    public func refresh() {
        refresh(attempt: 0)
    }

    /// Reads every value again from the displays already known, and brings the cache in line
    /// with them: what was changed with a display's own buttons shows up. This is for when
    /// the menu opens. The displays are not looked for afresh, unless none is known or one of
    /// them answers nothing at all.
    public func readValues() {
        guard !sessions.isEmpty else { return refresh() }
        for session in sessions { session.readValues() }
    }

    /// The display whose feedback a command for these displays would give: the first of them
    /// that has the control; nil when none has it.
    public func answering(_ command: Command, to displays: [Transport.Handle]? = nil) -> Transport.Handle? {
        sessions.first { session in
            session.has(command.control) && displays.map { $0.contains { $0 === session.display } } ?? true
        }?.display
    }

    /// Applies a command to the given displays, or to every display when none is given, as far
    /// as they have the control. The feedback is the first of those displays', and that display
    /// is returned; nil when none of them has the control.
    @discardableResult
    public func apply(
        _ command: Command, to displays: [Transport.Handle]? = nil, feedback: @escaping FeedbackHandler = { _, _ in }
    ) -> Transport.Handle? {
        let targets = sessions.filter { session in
            session.has(command.control) && displays.map { $0.contains { $0 === session.display } } ?? true
        }
        guard let first = targets.first else {
            lookAgainIfOnlySilentDisplays()
            feedback(nil, true)
            return nil
        }
        commandCounts[command.control, default: 0] += 1
        first.apply(command, feedback: feedback)
        for session in targets.dropFirst() { session.apply(command) { _, _ in } }
        return first.display
    }

    /// Reads a feature from every display, for the command line. The request waits its turn
    /// on the queue that everything sent to the displays goes through, so the command line
    /// never talks to a display while the app does. The cache is left as it is.
    public func values(of feature: DDC.Feature, completion: @escaping @MainActor ([DDC.Value]) -> Void) {
        let displays = controlled
        let transport = transport
        queue.async {
            let values = displays.compactMap { transport.get($0, feature) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(values) }
            }
        }
    }

    /// Forgets everything pending and stops trusting the cache, for when the displays go to sleep.
    public func suspend() {
        // A search under way was made of displays that were still awake.
        generation += 1
        writer.cancelAll()
        for session in sessions { session.suspend() }
    }

    /// A display that stayed silent through every retry after a wake may only have been slow to
    /// wake. With no display under control, a command has the displays looked for again, now
    /// and then, rather than waiting for the menu to open or a display to be plugged in.
    private func lookAgainIfOnlySilentDisplays() {
        guard sessions.isEmpty, knownSilent > 0 else { return }
        let time = now()
        if let lookedAgainAt, time.timeIntervalSince(lookedAgainAt) < timing.lookAgainAfter { return }
        lookedAgainAt = time
        refresh()
    }

    /// Gives each display the dimming it may have, for when what decides it has changed, such
    /// as the arrangement of the screens.
    public func applyDimmingLimits() {
        for session in sessions { session.maximumDimming = dimmingLimit(for: session.display) }
    }

    private func dimmingLimit(for display: Transport.Handle) -> Int {
        canDim?(display) == false ? 0 : maximumDimming
    }

    private func session(for display: Transport.Handle) -> DisplaySession<Transport>? {
        sessions.first { $0.display === display }
    }

    // MARK: Looking for the displays

    private func refresh(attempt: Int) {
        generation += 1
        let generation = generation
        let startCounts = commandCounts
        let transport = transport
        queue.async {
            let found = transport.displays().map { ($0, transport.state(of: $0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishRefresh(found, generation: generation, startCounts: startCounts, attempt: attempt)
                }
            }
        }
    }

    private func finishRefresh(
        _ found: [(Transport.Handle, DisplayState)], generation: Int, startCounts: [Command.Control: Int],
        attempt: Int
    ) {
        guard generation == self.generation else { return }
        // Weak: a session finishing a read can outlive the displays it belonged to.
        let owner = DisplaySession<Transport>.Owner(
            changed: { [weak self] in self?.onChange?() },
            mismatch: { [weak self] in self?.onMismatch?($0) },
            read: { [weak self] in self?.onRead?($0, $1) },
            answeredNothing: { [weak self] in self?.refresh() })
        let old = sessions
        sessions = found.filter(\.1.isControllable).map { display, state in
            let session = DisplaySession(
                display: display, state: state, transport: transport, queue: queue, timing: timing, now: now,
                writer: writer, owner: owner)
            session.maximumDimming = dimmingLimit(for: display)
            return session
        }
        // A command applied while the displays were being read may be missing from the reading.
        let overtaken = Set(Command.Control.allCases.filter { commandCounts[$0] != startCounts[$0] })
        for session in sessions { session.distrust(overtaken) }
        onChange?()
        // Commands still waiting for a display that is gone go to the same display, found again,
        // whatever its place in the new search; with one display before and after, that one.
        // Where that cannot be told, they are dropped rather than sent to another display.
        for session in old {
            let waiting = session.retire()
            guard !waiting.isEmpty else { continue }
            let same =
                old.count == 1 && sessions.count == 1
                ? sessions : sessions.filter { transport.isSame($0.display, as: session.display) }
            for item in waiting {
                if same.count == 1 {
                    same[0].apply(item.command, feedback: item.feedback)
                } else {
                    item.feedback(nil, true)
                }
            }
        }

        // A display that does not answer may still be waking, so discovery is tried again;
        // but only for a silence that is new. One that lasted through every retry is a
        // display without DDC, and would otherwise set off the retries on every refresh.
        let silent = found.count - sessions.count
        guard silent > knownSilent, attempt < timing.retryDelays.count else {
            knownSilent = silent
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.retryDelays[attempt]) {
            MainActor.assumeIsolated {
                guard generation == self.generation else { return }
                self.refresh(attempt: attempt + 1)
            }
        }
    }
}
