import Foundation

/// One display and the cache of its state.
///
/// Commands are applied to the cache and written out asynchronously, so the indicator never
/// waits for the display. The cache is kept honest in two ways: a value that has not been heard
/// from for a while is read before it is written, and every burst of writes is read back. Each
/// display keeps its own account of all that, so that one can be changed without the others.
@MainActor
public final class DisplaySession<Transport: DisplayTransport> {
    public typealias Timing = Displays<Transport>.Timing
    public typealias FeedbackHandler = Displays<Transport>.FeedbackHandler

    /// What the session tells the displays it belongs to.
    struct Owner {
        /// Values that the display reported differently from the cache were taken in.
        var changed: () -> Void
        var mismatch: (DisplayMismatch) -> Void
        var read: (_ features: [DDC.Feature], _ duration: TimeInterval) -> Void
        /// A read of every value got no answer at all: the display may have gone.
        var answeredNothing: () -> Void
    }

    struct Waiting {
        let command: Command
        let feedback: FeedbackHandler
    }

    /// Why the display is read.
    private enum Purpose {
        /// Commands are waiting to know what the display holds.
        case commands
        /// A burst of writes is over and is read back.
        case readBack
        /// The values are wanted afresh, as when the menu opens.
        case again
    }

    public let display: Transport.Handle
    public private(set) var state: DisplayState
    /// How many steps the screen may be dimmed below the display's lowest brightness; 0 when
    /// dimming is off.
    var maximumDimming = 0 {
        didSet { state.dimming = min(state.dimming, maximumDimming) }
    }

    private let transport: Transport
    private let queue: DispatchQueue
    private let timing: Timing
    private let now: () -> Date
    private let writer: CoalescingWriter<Transport.Handle, DDC.Feature>
    private let owner: Owner

    /// Changes when the display goes to sleep and when the session is let go, so readings
    /// taken before that are dropped.
    private var topology = 0
    private var isRetired = false
    /// Counts commands per control, so a reading that a newer command has overtaken is dropped.
    private var epochs: [Command.Control: Int] = [:]
    private var syncedAt: [DDC.Feature: Date] = [:]
    /// Reads asked for and not yet answered. One for the menu can come while another is under way.
    private var readsInFlight = 0
    private var isSyncing: Bool { readsInFlight > 0 }
    /// Commands for a stale value, held until the display has been read.
    private var waiting: [Waiting] = []
    /// The state the waiting commands are expected to produce, for immediate feedback.
    private var preview: DisplayState?
    /// Controls written since they were last read back.
    private var unverified: Set<Command.Control> = []
    /// Controls whose last write was sent a second time after a read-back disagreed.
    private var retried: Set<Command.Control> = []
    /// The value each feature had before the current burst of writes began.
    private var burstOrigin: [DDC.Feature: Int] = [:]
    private var verifyDeadline = DispatchTime.now()
    private var verifyIsScheduled = false

    /// A display just found and read: everything that was read counts as heard from.
    init(
        display: Transport.Handle, state: DisplayState, transport: Transport, queue: DispatchQueue, timing: Timing,
        now: @escaping () -> Date, writer: CoalescingWriter<Transport.Handle, DDC.Feature>, owner: Owner
    ) {
        self.display = display
        self.state = state
        self.transport = transport
        self.queue = queue
        self.timing = timing
        self.now = now
        self.writer = writer
        self.owner = owner
        let time = now()
        for feature in DDC.Feature.allCases { syncedAt[feature] = time }
    }

    /// Whether the display has the control.
    public func has(_ control: Command.Control) -> Bool {
        state.has(control)
    }

    // MARK: Applying commands

    func apply(_ command: Command, feedback: @escaping FeedbackHandler) {
        if isFresh(command.featureToRead) {
            feedback(applyNow(command), true)
            return
        }
        // A command that says what the display is to hold need not know what it holds now.
        // It is written at once, with nothing left out on the stale cache's word. Only when
        // commands that do need to know are waiting for the same control does it take its
        // turn behind them.
        if command.isAbsolute, !waiting.contains(where: { $0.command.control == command.control }) {
            feedback(applyNow(command, trustingCache: false), true)
            return
        }
        // The cache may be out of date: show the expected result, but read before writing.
        feedback(previewResult(of: command), false)
        waiting.append(Waiting(command: command, feedback: feedback))
        if !isSyncing { readForWaitingCommands() }
    }

    /// A command applied while the display was being looked for may be missing from what was
    /// read then; it is read back like any write.
    func distrust(_ controls: Set<Command.Control>) {
        guard !controls.isEmpty else { return }
        unverified.formUnion(controls)
        scheduleVerify()
    }

    /// Forgets everything pending and stops trusting the cache, for when the display goes to sleep.
    func suspend() {
        topology += 1
        waiting.removeAll()
        preview = nil
        unverified.removeAll()
        retried.removeAll()
        burstOrigin.removeAll()
        syncedAt.removeAll()
    }

    /// Lets the session go, for when the displays have been looked for again. Readings still
    /// under way are dropped, and the commands still waiting are handed back to go elsewhere.
    func retire() -> [Waiting] {
        isRetired = true
        topology += 1
        defer { waiting.removeAll() }
        return waiting
    }

    private func isFresh(_ feature: DDC.Feature) -> Bool {
        guard let time = syncedAt[feature] else { return false }
        return now().timeIntervalSince(time) < timing.staleAfter
    }

    private func applyNow(_ command: Command, trustingCache: Bool = true) -> Feedback? {
        let before = state
        guard let outcome = state.apply(command, trustingCache: trustingCache, maximumDimming: maximumDimming)
        else { return nil }
        let time = now()
        for write in outcome.writes {
            writer.submit(display, write.feature, write.value)
            syncedAt[write.feature] = time
            if burstOrigin[write.feature] == nil, let value = before.value(of: write.feature) {
                burstOrigin[write.feature] = value
            }
        }
        epochs[command.control, default: 0] += 1
        syncedAt[command.featureToRead] = time
        retried.remove(command.control)
        if !outcome.writes.isEmpty {
            unverified.insert(command.control)
            scheduleVerify()
        }
        return outcome.feedback
    }

    private func previewResult(of command: Command) -> Feedback? {
        var expected = preview ?? state
        let feedback = expected.apply(command, maximumDimming: maximumDimming)?.feedback
        preview = expected
        return feedback
    }

    private func readForWaitingCommands() {
        var features: [DDC.Feature] = []
        for item in waiting where !features.contains(item.command.featureToRead) {
            features.append(item.command.featureToRead)
        }
        read(features, for: Set(waiting.map(\.command.control)), purpose: .commands)
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

    // MARK: Reading the display

    /// Reads every value again and brings the cache in line with what the display holds, for
    /// when the menu opens. A control that has just been written is left to its read-back,
    /// which is due anyway and knows what to do when the display did not take the write. Read
    /// here, the old value would pass for one set with the display's buttons.
    func readValues() {
        // Only the controls the display answered for: one that ignores a request is waited for
        // each time, and costs every read after it the long pauses.
        let controls = Command.Control.allCases.filter { has($0) && !unverified.contains($0) }
        if !controls.isEmpty { read(controls.flatMap(\.features), for: Set(controls), purpose: .again) }
    }

    /// Reads features and reconciles the cache with the readings.
    private func read(_ features: [DDC.Feature], for controls: Set<Command.Control>, purpose: Purpose) {
        readsInFlight += 1
        let display = display
        let startEpochs = epochs
        let topology = topology
        let transport = transport
        queue.async {
            let start = DispatchTime.now().uptimeNanoseconds
            let readings = features.map { transport.get(display, $0) }
            let duration = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishRead(
                        features, for: controls, purpose: purpose, readings: readings, startEpochs: startEpochs,
                        topology: topology, duration: duration)
                }
            }
        }
    }

    private func finishRead(
        _ features: [DDC.Feature], for controls: Set<Command.Control>, purpose: Purpose, readings: [DDC.Value?],
        startEpochs: [Command.Control: Int], topology: Int, duration: TimeInterval
    ) {
        readsInFlight -= 1
        guard !isRetired else { return }
        owner.read(features, duration)
        // Readings taken before the display went to sleep say nothing about it as it is now.
        // Commands that came since are read for.
        guard topology == self.topology else {
            if !unverified.isEmpty { scheduleVerify() }
            return drainWaiting(read: [])
        }
        let time = now()
        for (feature, value) in zip(features, readings) {
            // Only an answer makes a value fresh. A display that has the feature and did not
            // answer leaves it stale, so that it is read again before it is next relied on.
            if value != nil || state.value(of: feature) == nil { syncedAt[feature] = time }
        }

        var changed = false
        for control in Command.Control.allCases where controls.contains(control) {
            // Drop a reading that a newer command has already overtaken.
            guard epochs[control] == startEpochs[control] else { continue }
            let afterWrite = purpose == .readBack && unverified.remove(control) != nil
            if afterWrite, resendIfNotTaken(control, features: features, readings: readings) { continue }
            for (feature, value) in zip(features, readings) where control.features.contains(feature) {
                let origin = burstOrigin[feature]
                if afterWrite { burstOrigin[feature] = nil }
                guard let value, let cached = state.reconcile(feature, with: value) else { continue }
                changed = true
                let kind: DisplayMismatch.Kind =
                    !afterWrite ? .changedOutside : value.current == origin ? .writeRefused : .writeAdjusted
                owner.mismatch(DisplayMismatch(feature: feature, cached: cached, actual: value.current, kind: kind))
            }
        }
        if changed { owner.changed() }
        // A reading that was dropped leaves its control unverified; make sure it is read again.
        if !unverified.isEmpty { scheduleVerify() }
        drainWaiting(read: features)
        if purpose == .again, readings.allSatisfy({ $0 == nil }) { owner.answeredNothing() }
    }

    // MARK: Reading back after writes

    /// Displays drop a write now and then (about one in a hundred on the display it was tuned on). When a
    /// read-back disagrees with what was written, the values are sent once more and read back
    /// again before the disagreement is believed. Returns true when it sent them again.
    private func resendIfNotTaken(_ control: Command.Control, features: [DDC.Feature], readings: [DDC.Value?]) -> Bool {
        guard !retried.contains(control) else {
            retried.remove(control)
            return false
        }
        var resent = false
        for (feature, value) in zip(features, readings) where control.features.contains(feature) {
            var trial = state
            guard let value, let cached = trial.reconcile(feature, with: value) else { continue }
            writer.submit(display, feature, cached)
            resent = true
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
                guard !self.isRetired else { return }
                if DispatchTime.now() < self.verifyDeadline || self.isSyncing || !self.waiting.isEmpty {
                    self.verifyDeadline = max(self.verifyDeadline, .now() + 0.05)
                    self.waitForVerifyDeadline()
                } else {
                    self.verifyIsScheduled = false
                    let controls = self.unverified
                    let features = Command.Control.allCases.filter(controls.contains).flatMap(\.features)
                    if !controls.isEmpty { self.read(features, for: controls, purpose: .readBack) }
                }
            }
        }
    }
}
