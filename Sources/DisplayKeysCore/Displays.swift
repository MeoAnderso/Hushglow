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

/// The connected DDC displays and a cache of their state.
///
/// Commands are applied to the cache and written out asynchronously, so the indicator never
/// waits for the display. The cache is kept honest in two ways: a value that has not been heard
/// from for a while is read before it is written, and every burst of writes is read back.
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

    /// Receives the level to show. For a stale value it is called twice: at once with the
    /// expected result, then with the real one (`isFinal`) after the display has been read.
    /// The level is nil when no display has the control.
    public typealias FeedbackHandler = @MainActor (_ feedback: Feedback?, _ isFinal: Bool) -> Void

    public var onChange: (() -> Void)?
    public var onMismatch: ((DisplayMismatch) -> Void)?
    /// Reports how long a read of the displays took.
    public var onRead: ((_ features: [DDC.Feature], _ duration: TimeInterval) -> Void)?

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
    /// Changes whenever `entries` is replaced and when the displays go to sleep, so readings
    /// taken before that are dropped.
    private var topology = 0
    /// Counts commands per control, so a reading that a newer command has overtaken is dropped.
    private var epochs: [Command.Control: Int] = [:]
    private var syncedAt: [DDC.Feature: Date] = [:]
    private var isSyncing = false
    /// Commands for a stale value, held until the display has been read.
    private var waiting: [Waiting] = []
    /// The states the waiting commands are expected to produce, for immediate feedback.
    private var preview: [DisplayState]?
    /// Controls written since they were last read back.
    private var unverified: Set<Command.Control> = []
    /// Controls whose last write was sent a second time after a read-back disagreed.
    private var retried: Set<Command.Control> = []
    /// Per display, the value each feature had before the current burst of writes began.
    private var burstOrigin: [Int: [DDC.Feature: Int]] = [:]
    private var verifyDeadline = DispatchTime.now()
    private var verifyIsScheduled = false
    /// How many displays stayed silent through a whole round of retries. They are taken to
    /// have no DDC, and are not waited for again.
    private var knownSilent = 0

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
    public func apply(_ command: Command, feedback: @escaping FeedbackHandler = { _, _ in }) {
        if isFresh(command.featureToRead) {
            feedback(applyNow(command), true)
            return
        }
        // The cache may be out of date: show the expected result, but read before writing.
        feedback(previewResult(of: command), false)
        waiting.append(Waiting(command: command, feedback: feedback))
        if !isSyncing { readForWaitingCommands() }
    }

    /// Reads a feature from every display, for the command line. The request waits its turn
    /// on the queue that everything sent to the displays goes through, so the command line
    /// never talks to a display while the app does. The cache is left as it is.
    public func values(of feature: DDC.Feature, completion: @escaping @MainActor ([DDC.Value]) -> Void) {
        let displays = entries.map(\.display)
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
        // Whatever is being read at this moment was asked of displays that were still awake.
        generation += 1
        topology += 1
        writer.cancelAll()
        waiting.removeAll()
        preview = nil
        unverified.removeAll()
        retried.removeAll()
        burstOrigin.removeAll()
        syncedAt.removeAll()
    }

    // MARK: Applying commands

    private func isFresh(_ feature: DDC.Feature) -> Bool {
        guard let time = syncedAt[feature] else { return false }
        return now().timeIntervalSince(time) < timing.staleAfter
    }

    private func applyNow(_ command: Command) -> Feedback? {
        var feedback: Feedback?
        var wrote = false
        let time = now()
        for index in entries.indices {
            let before = entries[index].state
            guard let outcome = entries[index].state.apply(command) else { continue }
            for write in outcome.writes {
                writer.submit(entries[index].display, write.feature, write.value)
                syncedAt[write.feature] = time
                if burstOrigin[index]?[write.feature] == nil, let value = before.value(of: write.feature) {
                    burstOrigin[index, default: [:]][write.feature] = value
                }
                wrote = true
            }
            feedback = feedback ?? outcome.feedback
        }
        guard feedback != nil else { return nil }
        epochs[command.control, default: 0] += 1
        syncedAt[command.featureToRead] = time
        retried.remove(command.control)
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

    private func readForWaitingCommands() {
        var features: [DDC.Feature] = []
        for item in waiting where !features.contains(item.command.featureToRead) {
            features.append(item.command.featureToRead)
        }
        read(features, for: Set(waiting.map(\.command.control)), isVerify: false)
    }

    /// Applies the waiting commands whose value has just been read, and reads for the rest.
    private func drainWaiting(read features: [DDC.Feature]) {
        let pending = waiting
        waiting = []
        for item in pending {
            let feature = item.command.featureToRead
            if features.contains(feature) || isFresh(feature) {
                item.feedback(applyNow(item.command), true)
            } else {
                waiting.append(item)
            }
        }
        if waiting.isEmpty {
            preview = nil
        } else if !isSyncing {
            readForWaitingCommands()
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
        burstOrigin.removeAll()
        retried.removeAll()
        let time = now()
        for control in Command.Control.allCases {
            for feature in control.features { syncedAt[feature] = time }
            // A command applied while the displays were being read may be missing from the reading.
            if epochs[control] == startEpochs[control] {
                unverified.remove(control)
            } else {
                unverified.insert(control)
            }
        }
        if !unverified.isEmpty { scheduleVerify() }
        onChange?()
        drainWaiting(read: Command.Control.allCases.flatMap(\.features))

        // A display that does not answer may still be waking, so discovery is tried again;
        // but only for a silence that is new. One that lasted through every retry is a
        // display without DDC, and would otherwise set off the retries on every refresh.
        let silent = found.count - entries.count
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

    /// Reads features from every display and reconciles the cache with the readings.
    private func read(_ features: [DDC.Feature], for controls: Set<Command.Control>, isVerify: Bool) {
        isSyncing = true
        let displays = entries.map(\.display)
        let startEpochs = epochs
        let topology = topology
        let transport = transport
        queue.async {
            let start = DispatchTime.now().uptimeNanoseconds
            let readings = displays.map { display in features.map { transport.get(display, $0) } }
            let duration = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !displays.isEmpty { self.onRead?(features, duration) }
                    self.finishRead(
                        features, for: controls, isVerify: isVerify, readings: readings, startEpochs: startEpochs,
                        topology: topology)
                }
            }
        }
    }

    private func finishRead(
        _ features: [DDC.Feature], for controls: Set<Command.Control>, isVerify: Bool, readings: [[DDC.Value?]],
        startEpochs: [Command.Control: Int], topology: Int
    ) {
        isSyncing = false
        // Readings taken before a rediscovery, or before the displays went to sleep, say
        // nothing about the displays as they are now. Commands that came since are read for.
        guard topology == self.topology else {
            if !unverified.isEmpty { scheduleVerify() }
            return drainWaiting(read: [])
        }
        let time = now()
        for (position, feature) in features.enumerated() {
            // Only an answer makes a value fresh. A display that has the feature and did not
            // answer leaves it stale, so that it is read again before it is next relied on.
            let wasAnswered = zip(entries, readings).allSatisfy { entry, values in
                values[position] != nil || entry.state.value(of: feature) == nil
            }
            if wasAnswered { syncedAt[feature] = time }
        }

        var changed = false
        for control in controls {
            // Drop a reading that a newer command has already overtaken.
            guard epochs[control] == startEpochs[control] else { continue }
            let afterWrite = isVerify && unverified.remove(control) != nil
            if afterWrite, resendIfNotTaken(control, features: features, readings: readings) { continue }
            for (index, values) in readings.enumerated() {
                for (feature, value) in zip(features, values) where control.features.contains(feature) {
                    let origin = burstOrigin[index]?[feature]
                    if afterWrite { burstOrigin[index]?[feature] = nil }
                    guard let value, let cached = entries[index].state.reconcile(feature, with: value) else { continue }
                    changed = true
                    let kind: DisplayMismatch.Kind =
                        !afterWrite ? .changedOutside : value.current == origin ? .writeRefused : .writeAdjusted
                    onMismatch?(DisplayMismatch(feature: feature, cached: cached, actual: value.current, kind: kind))
                }
            }
        }
        if changed { onChange?() }
        // A reading that was dropped leaves its control unverified; make sure it is read again.
        if !unverified.isEmpty { scheduleVerify() }
        drainWaiting(read: features)
    }

    // MARK: Reading back after writes

    /// Displays drop a write now and then (about one in a hundred on the display it was tuned on). When a
    /// read-back disagrees with what was written, the values are sent once more and read back
    /// again before the disagreement is believed. Returns true when it sent them again.
    private func resendIfNotTaken(_ control: Command.Control, features: [DDC.Feature], readings: [[DDC.Value?]]) -> Bool
    {
        guard !retried.contains(control) else {
            retried.remove(control)
            return false
        }
        var resent = false
        for (index, values) in readings.enumerated() {
            for (feature, value) in zip(features, values) where control.features.contains(feature) {
                var trial = entries[index].state
                guard let value, let cached = trial.reconcile(feature, with: value) else { continue }
                writer.submit(entries[index].display, feature, cached)
                resent = true
            }
        }
        guard resent else { return false }
        retried.insert(control)
        unverified.insert(control)
        return true
    }

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
                    let controls = self.unverified
                    let features = Command.Control.allCases.filter(controls.contains).flatMap(\.features)
                    if !controls.isEmpty { self.read(features, for: controls, isVerify: true) }
                }
            }
        }
    }
}
