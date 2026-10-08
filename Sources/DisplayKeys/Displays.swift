import DisplayKeysCore
import Foundation

/// The connected DDC displays and their cached state. A display is read once when it is
/// discovered; after that every command is applied to the cache and written out asynchronously.
@MainActor
final class Displays {
    private struct Entry: Sendable {
        let service: AVService
        var state: DisplayState
    }

    /// A display that is still waking up does not answer yet, so discovery is retried a few times.
    private static let retryDelays: [TimeInterval] = [2, 5, 10]

    var onChange: (() -> Void)?
    private let io: IOAV
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).ddc", qos: .userInitiated)
    private let writer: CoalescingWriter<AVService, DDC.Feature>
    private var entries: [Entry] = []
    private var generation = 0

    init(io: IOAV, onWriteFailure: @escaping @Sendable () -> Void) {
        self.io = io
        writer = CoalescingWriter(queue: queue) { service, feature, value in
            if !io.set(service, feature, value: value) { onWriteFailure() }
        }
    }

    var primary: DisplayState? { entries.first?.state }
    var hasBrightness: Bool { entries.contains { $0.state.brightness != nil } }
    var hasVolume: Bool { entries.contains { $0.state.volume != nil } }

    /// Rediscovers the displays and re-reads their state. Newer calls supersede older ones.
    func refresh() {
        refresh(attempt: 0)
    }

    /// Applies a command to every display that has the control; nil when none does.
    func apply(_ command: Command) -> Feedback? {
        var feedback: Feedback?
        for index in entries.indices {
            guard let outcome = entries[index].state.apply(command) else { continue }
            for write in outcome.writes { writer.submit(entries[index].service, write.feature, write.value) }
            feedback = feedback ?? outcome.feedback
        }
        return feedback
    }

    /// Drops writes that have not been sent yet, for when the displays go to sleep.
    func suspend() {
        writer.cancelAll()
    }

    private func refresh(attempt: Int) {
        generation += 1
        let generation = generation
        let io = io
        queue.async {
            let found = io.externalServices().map { Entry(service: $0, state: io.state(of: $0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishRefresh(found, generation: generation, attempt: attempt)
                }
            }
        }
    }

    private func finishRefresh(_ found: [Entry], generation: Int, attempt: Int) {
        guard generation == self.generation else { return }
        entries = found.filter(\.state.isControllable)
        onChange?()

        guard entries.count < found.count, attempt < Self.retryDelays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) {
            MainActor.assumeIsolated {
                guard generation == self.generation else { return }
                self.refresh(attempt: attempt + 1)
            }
        }
    }
}
