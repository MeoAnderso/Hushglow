import Foundation

/// Sends values on a serial queue, keeping only the newest value per target and key, so a
/// held key never builds a backlog behind a slow display.
public final class CoalescingWriter<Target: AnyObject & Sendable, Key: Hashable & Sendable>: @unchecked Sendable {
    public typealias Send = @Sendable (Target, Key, Int) -> Void

    private struct Entry {
        let target: Target
        let key: Key
        var value: Int
    }

    private let queue: DispatchQueue
    private let send: Send
    private let lock = NSLock()
    private var pending: [Entry] = []
    private var isDraining = false

    /// `send` is called on `queue`, one value at a time, in the order keys were first submitted.
    public init(queue: DispatchQueue, send: @escaping Send) {
        self.queue = queue
        self.send = send
    }

    public func submit(_ target: Target, _ key: Key, _ value: Int) {
        let shouldStart = lock.withLock {
            if let index = pending.firstIndex(where: { $0.target === target && $0.key == key }) {
                pending[index].value = value
            } else {
                pending.append(Entry(target: target, key: key, value: value))
            }
            defer { isDraining = true }
            return !isDraining
        }
        if shouldStart { queue.async { self.drain() } }
    }

    /// Drops values that have not been sent yet.
    public func cancelAll() {
        lock.withLock { pending.removeAll() }
    }

    private func drain() {
        while true {
            let next: Entry? = lock.withLock {
                if pending.isEmpty {
                    isDraining = false
                    return nil
                }
                return pending.removeFirst()
            }
            guard let next else { return }
            // One run lasts for as long as values keep arriving, which can be the whole drag
            // of a slider; what sending a value leaves behind is not kept that long.
            autoreleasepool { send(next.target, next.key, next.value) }
        }
    }
}
