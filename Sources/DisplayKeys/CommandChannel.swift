import DisplayKeysCore
import Foundation

/// What the running app reports about itself to `DisplayKeys status` and `doctor`.
struct AppStatus: Codable {
    struct Level: Codable {
        var current: Int
        var maximum: Int
    }

    /// One display under control.
    struct DisplayStatus: Codable {
        var name: String
        var brightness: Level?
        var volume: Level?
        var muted: Bool
        var contrast: Level?
        /// The input the display shows, as it reports it.
        var input: Int?
    }

    struct ShortcutStatus: Codable {
        var action: String
        var keys: String
        /// False when macOS refused the shortcut.
        var registered: Bool
        /// True when macOS has a shortcut of its own on the same keys.
        var usedByMacOS: Bool
    }

    /// Counts of the input the app has received since it started.
    struct Input: Codable {
        var shortcutPresses = 0
        var keysHandled = 0
        var keysLeftToSystem = 0
        var last: String?
        var lastAt: Date?

        mutating func record(_ description: String) {
            last = description
            lastAt = Date()
        }
    }

    var version: String
    /// Short hash of the running build, to tell two builds of one version apart.
    var build: String?
    var displayControlAvailable: Bool
    var brightness: Level?
    var volume: Level?
    var muted: Bool
    var accessGranted: Bool
    var askingIsDisabled: Bool
    var keyTapActive: Bool
    var soundGoesToDisplay: Bool
    var quarterSteps: Bool
    /// What quarter steps add, such as `cmd`. Optional, so that a status from an older build still reads.
    var quarterStepModifier: String?
    var shortcuts: [ShortcutStatus]
    var input: Input
    /// How long the last read of the display took.
    var lastReadMilliseconds: Int?
    /// How many values that read was for. Optional, so that a status from an older build still reads.
    var lastReadValues: Int?
    /// The app's memory footprint in bytes. Optional, so that a status from an older build still reads.
    var memoryFootprint: UInt64?
    var isWatchingKeys: Bool
    /// Every display under control, numbered from 1 in this order. Optional, so that a status
    /// from an older build still reads.
    var displays: [DisplayStatus]?
    /// What the last key watch saw; nil when none has run.
    var watchedKeys: [String]?
}

/// The notification names the command line and the app talk through. Tests use their own
/// namespace so that they never reach the installed app.
struct ChannelNames {
    let command: Notification.Name
    let shortcutsChanged: Notification.Name
    let keyTest: Notification.Name
    let watchKeys: Notification.Name
    let statusRequest: Notification.Name
    let valueRequest: Notification.Name
    /// What the name of every answer starts with.
    let replyPrefix: String

    init(namespace: String) {
        command = Notification.Name("\(namespace).command")
        shortcutsChanged = Notification.Name("\(namespace).shortcutsChanged")
        keyTest = Notification.Name("\(namespace).keyTest")
        watchKeys = Notification.Name("\(namespace).watchKeys")
        statusRequest = Notification.Name("\(namespace).statusRequest")
        valueRequest = Notification.Name("\(namespace).valueRequest")
        replyPrefix = "\(namespace).reply."
    }
}

private func post(_ name: Notification.Name, _ object: String?) {
    DistributedNotificationCenter.default().postNotificationName(
        name, object: object, userInfo: nil, deliverImmediately: true)
}

/// The app's end of the link to the command line, over distributed notifications.
@MainActor
final class CommandChannel: NSObject {
    struct Handlers {
        /// A command, and the number of the display it is for; nil for every display.
        var onCommand: (Command, Int?) -> Void
        var onShortcutsChanged: () -> Void
        var onKeyTest: () -> Void
        var onWatchKeys: (TimeInterval) -> Void
        /// Reads a feature from the displays and passes on what they answered.
        var readValues: (DDC.Feature, @escaping @MainActor ([AppStatus.Level]) -> Void) -> Void
        var status: () -> AppStatus
    }

    private let names: ChannelNames
    private let handlers: Handlers

    init(namespace: String = AppInfo.bundleID, handlers: Handlers) {
        names = ChannelNames(namespace: namespace)
        self.handlers = handlers
        super.init()
        let center = DistributedNotificationCenter.default()
        for (selector, name) in [
            (#selector(commandReceived), names.command),
            (#selector(shortcutsChanged), names.shortcutsChanged),
            (#selector(keyTestRequested), names.keyTest),
            (#selector(watchKeysRequested), names.watchKeys),
            (#selector(statusRequested), names.statusRequest),
            (#selector(valuesRequested), names.valueRequest),
        ] {
            center.addObserver(
                self, selector: selector, name: name, object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func commandReceived(_ notification: Notification) {
        guard let text = notification.object as? String else { return }
        var words = text.split(separator: " ").map(String.init)
        // A command for one display ends with its number.
        var display: Int?
        if let last = words.last, last.hasPrefix(CommandClient.displayPrefix) {
            guard let number = Int(last.dropFirst(CommandClient.displayPrefix.count)), number > 0 else { return }
            display = number
            words.removeLast()
        }
        guard let command = Command(words: words) else { return }
        handlers.onCommand(command, display)
    }

    @objc private func shortcutsChanged() {
        handlers.onShortcutsChanged()
    }

    @objc private func keyTestRequested() {
        handlers.onKeyTest()
    }

    @objc private func watchKeysRequested(_ notification: Notification) {
        guard let text = notification.object as? String, let seconds = TimeInterval(text), (1...60).contains(seconds)
        else { return }
        handlers.onWatchKeys(seconds)
    }

    @objc private func statusRequested(_ notification: Notification) {
        guard let replyName = replyName(in: notification) else { return }
        answer(replyName, with: handlers.status())
    }

    @objc private func valuesRequested(_ notification: Notification) {
        guard let replyName = replyName(in: notification),
            let name = (notification.object as? String)?.split(separator: " ").dropFirst().first,
            let feature = DDC.Feature(name: String(name))
        else { return }
        let reply: @MainActor ([AppStatus.Level]) -> Void = { [weak self] in self?.answer(replyName, with: $0) }
        handlers.readValues(feature, reply)
    }

    /// A request starts with the name of the notification to answer with; only names of our
    /// own are answered.
    private func replyName(in notification: Notification) -> String? {
        guard let name = (notification.object as? String)?.split(separator: " ").first.map(String.init),
            name.hasPrefix(names.replyPrefix)
        else { return nil }
        return name
    }

    private func answer(_ replyName: String, with value: some Encodable) {
        guard let json = try? JSONEncoder().encode(value) else { return }
        post(Notification.Name(replyName), String(decoding: json, as: UTF8.self))
    }
}

/// The command line's end of the link to the running app.
@MainActor
struct CommandClient {
    private let names: ChannelNames

    init(namespace: String = AppInfo.bundleID) {
        names = ChannelNames(namespace: namespace)
    }

    static let displayPrefix = "display="

    /// Sends a command for every display, or for the one with this number.
    func send(_ command: Command, display: Int? = nil) {
        let words = command.words + (display.map { ["\(Self.displayPrefix)\($0)"] } ?? [])
        post(names.command, words.joined(separator: " "))
    }

    func notifyShortcutsChanged() {
        post(names.shortcutsChanged, nil)
    }

    func requestKeyTest() {
        post(names.keyTest, nil)
    }

    func watchKeys(seconds: Int) {
        post(names.watchKeys, String(seconds))
    }

    /// Asks the app for its status and waits for the answer; nil when nothing answers in time.
    func requestStatus(timeout: TimeInterval = 1.5) -> AppStatus? {
        wait(for: beginStatusRequest(), timeout: timeout)
    }

    /// Asks the app for its status without waiting; the answer appears on the returned request.
    func beginStatusRequest() -> Request<AppStatus> {
        Request(names.statusRequest, replyPrefix: names.replyPrefix)
    }

    /// Has the app read a feature from the displays and waits for what they answered, one
    /// value per display; nil when the app does not answer in time. A read can take a few
    /// hundred milliseconds when a display is slow.
    func requestValues(of feature: DDC.Feature, timeout: TimeInterval = 3) -> [AppStatus.Level]? {
        wait(for: beginValueRequest(of: feature), timeout: timeout)
    }

    func beginValueRequest(of feature: DDC.Feature) -> Request<[AppStatus.Level]> {
        Request(names.valueRequest, replyPrefix: names.replyPrefix, argument: feature.name)
    }

    private func wait<Answer>(for request: Request<Answer>, timeout: TimeInterval) -> Answer? {
        defer { request.finish() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while request.answer == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return request.answer
    }
}

/// A question to the app that is waiting for its answer.
@MainActor
final class Request<Answer: Decodable> {
    private let listener: ReplyListener

    /// The request carries the name to answer with, then the argument when there is one.
    fileprivate init(_ name: Notification.Name, replyPrefix: String, argument: String? = nil) {
        listener = ReplyListener(prefix: replyPrefix)
        post(name, [listener.name.rawValue, argument].compactMap { $0 }.joined(separator: " "))
    }

    /// The app's answer, once it has arrived.
    var answer: Answer? {
        listener.json.flatMap { try? JSONDecoder().decode(Answer.self, from: Data($0.utf8)) }
    }

    func finish() {
        listener.stop()
    }
}

/// Listens for one answer under a name of its own.
@MainActor
private final class ReplyListener {
    private final class Reply: @unchecked Sendable {
        var json: String?
    }

    let name: Notification.Name
    private let reply = Reply()
    private let observer: NSObjectProtocol

    init(prefix: String) {
        let reply = reply
        name = Notification.Name(prefix + UUID().uuidString)
        // No queue: the answer is taken as it is delivered, on the main thread.
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: nil) {
            reply.json = $0.object as? String
        }
    }

    var json: String? { reply.json }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(observer)
    }
}
