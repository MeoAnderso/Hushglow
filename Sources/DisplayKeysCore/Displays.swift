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
}

extension DisplayTransport {
    public func state(of display: Handle) -> DisplayState {
        DisplayState(brightness: get(display, .brightness), volume: get(display, .volume), mute: get(display, .mute))
    }
}

/// The connected DDC displays and a cache of their state.
///
/// Commands are applied to the cache and written out asynchronously, so a key press never waits
/// for the display. The cache is kept honest in two ways: a control that has not been heard from
/// for a while is read before it is written, and every burst of writes is read back afterwards.
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

        public init() {}
    }

    /// Receives what the indicator should show. For a stale control it is called twice: at once
    /// with the expected result, then with the real one after the display has been read.
    public typealias FeedbackHandler = @MainActor (Feedback?) -> Void

    public var onChange: (() -> Void)?
    /// A reading disagreed with the cache. `afterWrite` tells a write the display did not take
    /// from a change made outside the app.
    public var onMismatch: ((_ feature: DDC.Feature, _ cached: Int, _ actual: Int, _ afterWrite: Bool) -> Void)?

    private struct Entry: Sendable {
        let display: Transport.Handle
        var state: DisplayState
    }

    private struct Waiting {
        let command: Command
        let feedback: FeedbackHandler
    }

    private let transport: Transport
    private let queue: DispatchQueue
    private let timing: Timing
    private let now: () -> Date
    private let writer: CoalescingWriter<Transport.Handle, DDC.Feature>

    private var entries: [Entry] = []
    /// Supersedes discoveries that are still in flight.
    private var generation = 0
    /// Changes whenever `entries` is replaced, so readings taken for older entries are dropped.
    private var topology = 0
    /// Counts commands per control, so a reading that a newer command has overtaken is dropped.
    private var epochs: [Command.Control: Int] = [:]
    private var syncedAt: [Command.Control: Date] = [:]
    private var isSyncing = false
    /// Commands for a stale control, held until the display has been read.
    private var waiting: [Waiting] = []
    /// The states the waiting commands are expected to produce, for immediate feedback.
    private var preview: [DisplayState]?
    /// Controls written since they were last read back.
    private var unverified: Set<Command.Control> = []
    private var verifyDeadline = DispatchTime.now()
    private var verifyIsScheduled = false

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

    public var primary: DisplayState? { entries.first?.state }
    public var hasBrightness: Bool { entries.contains { $0.state.brightness != nil } }
    public var hasVolume: Bool { entries.contains { $0.state.volume != nil } }

    /// Rediscovers the displays and re-reads their state. Newer calls supersede older ones.
    public func refresh() {
        refresh(attempt: 0)
    }

    /// Applies a command to every display that has the control.
    public func apply(_ command: Command, feedback: @escaping FeedbackHandler = { _ in }) {
        if isFresh(command.control) {
            feedback(applyNow(command))
            return
        }
        // The cache may be out of date: show the expected result, but read before writing.
        feedback(previewResult(of: command))
        waiting.append(Waiting(command: command, feedback: feedback))
        if !isSyncing { sync(Set(waiting.map(\.command.control))) }
    }

    /// Forgets everything pending and stops trusting the cache, for when the displays go to sleep.
    public func suspend() {
        writer.cancelAll()
        waiting.removeAll()
        preview = nil
        unverified.removeAll()
        syncedAt.removeAll()
    }

    // MARK: Applying commands

    private func isFresh(_ control: Command.Control) -> Bool {
        guard let time = syncedAt[control] else { return false }
        return now().timeIntervalSince(time) < timing.staleAfter
    }

    private func applyNow(_ command: Command) -> Feedback? {
        var feedback: Feedback?
        var wrote = false
        for index in entries.indices {
            guard let outcome = entries[index].state.apply(command) else { continue }
            for write in outcome.writes {
                writer.submit(entries[index].display, write.feature, write.value)
                wrote = true
            }
            feedback = feedback ?? outcome.feedback
        }
        guard feedback != nil else { return nil }
        epochs[command.control, default: 0] += 1
        syncedAt[command.control] = now()
        if wrote {
            unverified.insert(command.control)
            scheduleVerify()
        }
        return feedback
    }

    private func previewResult(of command: Command) -> Feedback? {
        var states = preview ?? entries.map(\.state)
        var feedback: Feedback?
        for index in states.indices {
            if let outcome = states[index].apply(command) { feedback = feedback ?? outcome.feedback }
        }
        preview = states
        return feedback
    }

    /// Applies the waiting commands whose control has just been read, and reads the rest.
    private func drainWaiting(synced: Set<Command.Control>) {
        let pending = waiting
        waiting = []
        for item in pending {
            if synced.contains(item.command.control) || isFresh(item.command.control) {
                item.feedback(applyNow(item.command))
            } else {
                waiting.append(item)
            }
        }
        if waiting.isEmpty {
            preview = nil
        } else if !isSyncing {
            sync(Set(waiting.map(\.command.control)))
        }
    }

    // MARK: Reading the displays

    private func refresh(attempt: Int) {
        generation += 1
        let generation = generation
        let startEpochs = epochs
        let transport = transport
        queue.async {
            let found = transport.displays().map { Entry(display: $0, state: transport.state(of: $0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishRefresh(found, generation: generation, startEpochs: startEpochs, attempt: attempt)
                }
            }
        }
    }

    private func finishRefresh(_ found: [Entry], generation: Int, startEpochs: [Command.Control: Int], attempt: Int) {
        guard generation == self.generation else { return }
        entries = found.filter(\.state.isControllable)
        topology += 1
        let time = now()
        for control in Command.Control.allCases {
            syncedAt[control] = time
            // A command applied while the displays were being read may be missing from the reading.
            if epochs[control] == startEpochs[control] {
                unverified.remove(control)
            } else {
                unverified.insert(control)
            }
        }
        if !unverified.isEmpty { scheduleVerify() }
        onChange?()
        drainWaiting(synced: Set(Command.Control.allCases))

        guard entries.count < found.count, attempt < timing.retryDelays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.retryDelays[attempt]) {
            MainActor.assumeIsolated {
                guard generation == self.generation else { return }
                self.refresh(attempt: attempt + 1)
            }
        }
    }

    /// Reads the given controls from every display and reconciles the cache with the readings.
    private func sync(_ controls: Set<Command.Control>) {
        isSyncing = true
        let features = Command.Control.allCases.filter(controls.contains).flatMap(\.features)
        let displays = entries.map(\.display)
        let startEpochs = epochs
        let topology = topology
        let transport = transport
        queue.async {
            let readings = displays.map { display in features.map { transport.get(display, $0) } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishSync(
                        controls, features: features, readings: readings, startEpochs: startEpochs, topology: topology)
                }
            }
        }
    }

    private func finishSync(
        _ controls: Set<Command.Control>, features: [DDC.Feature], readings: [[DDC.Value?]],
        startEpochs: [Command.Control: Int], topology: Int
    ) {
        isSyncing = false
        let time = now()
        var changed = false
        for control in controls {
            syncedAt[control] = time
            // Drop a reading that a newer command or a rediscovery has already overtaken.
            guard topology == self.topology, epochs[control] == startEpochs[control] else { continue }
            let afterWrite = unverified.remove(control) != nil
            for (index, values) in readings.enumerated() {
                for (feature, value) in zip(features, values) where control.features.contains(feature) {
                    guard let value, let cached = entries[index].state.reconcile(feature, with: value) else { continue }
                    changed = true
                    onMismatch?(feature, cached, value.current, afterWrite)
                }
            }
        }
        if changed { onChange?() }
        // A reading that was dropped leaves its control unverified; make sure it is read again.
        if !unverified.isEmpty { scheduleVerify() }
        drainWaiting(synced: controls)
    }

    // MARK: Reading back after writes

    /// Schedules one read-back after the writes stop; further writes only push the deadline out.
    private func scheduleVerify() {
        verifyDeadline = .now() + timing.verifyDelay
        guard !verifyIsScheduled else { return }
        verifyIsScheduled = true
        waitForVerifyDeadline()
    }

    private func waitForVerifyDeadline() {
        DispatchQueue.main.asyncAfter(deadline: verifyDeadline) {
            MainActor.assumeIsolated {
                if DispatchTime.now() < self.verifyDeadline || self.isSyncing || !self.waiting.isEmpty {
                    self.verifyDeadline = max(self.verifyDeadline, .now() + 0.05)
                    self.waitForVerifyDeadline()
                } else {
                    self.verifyIsScheduled = false
                    if !self.unverified.isEmpty { self.sync(self.unverified) }
                }
            }
        }
    }
}
