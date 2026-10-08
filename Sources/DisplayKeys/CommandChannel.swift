import DisplayKeysCore
import Foundation

/// What the running app reports about itself to `DisplayKeys status` and `doctor`.
struct AppStatus: Codable {
    struct Level: Codable {
        var current: Int
        var maximum: Int
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
    var shortcuts: [ShortcutStatus]
    var input: Input
    /// How long the last read of the display took.
    var lastReadMilliseconds: Int?
    var isWatchingKeys: Bool
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
    let statusReplyPrefix: String

    init(namespace: String) {
        command = Notification.Name("\(namespace).command")
        shortcutsChanged = Notification.Name("\(namespace).shortcutsChanged")
        keyTest = Notification.Name("\(namespace).keyTest")
        watchKeys = Notification.Name("\(namespace).watchKeys")
        statusRequest = Notification.Name("\(namespace).statusRequest")
        statusReplyPrefix = "\(namespace).statusReply."
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
        var onCommand: (Command) -> Void
        var onShortcutsChanged: () -> Void
        var onKeyTest: () -> Void
        var onWatchKeys: (TimeInterval) -> Void
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
        ] {
            center.addObserver(
                self, selector: selector, name: name, object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func commandReceived(_ notification: Notification) {
        guard let text = notification.object as? String,
            let command = Command(words: text.split(separator: " ").map(String.init))
        else { return }
        handlers.onCommand(command)
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
        // The request names the notification to answer with; only answer names of our own.
        guard let replyName = notification.object as? String, replyName.hasPrefix(names.statusReplyPrefix),
            let json = try? JSONEncoder().encode(handlers.status())
        else { return }
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

    func send(_ command: Command) {
        post(names.command, command.words.joined(separator: " "))
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
        let request = beginStatusRequest()
        defer { request.finish() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while request.status == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return request.status
    }

    /// Asks the app for its status without waiting; the answer appears on the returned request.
    func beginStatusRequest() -> StatusRequest {
        StatusRequest(names: names)
    }
}

/// A status request in flight.
@MainActor
final class StatusRequest {
    private final class Reply: @unchecked Sendable {
        var json: String?
    }

    private let reply = Reply()
    private let observer: NSObjectProtocol

    fileprivate init(names: ChannelNames) {
        let reply = reply
        let replyName = Notification.Name(names.statusReplyPrefix + UUID().uuidString)
        // No queue: the answer is taken as it is delivered, on the main thread.
        observer = DistributedNotificationCenter.default().addObserver(forName: replyName, object: nil, queue: nil) {
            reply.json = $0.object as? String
        }
        post(names.statusRequest, replyName.rawValue)
    }

    /// The app's answer, once it has arrived.
    var status: AppStatus? {
        reply.json.flatMap { try? JSONDecoder().decode(AppStatus.self, from: Data($0.utf8)) }
    }

    func finish() {
        DistributedNotificationCenter.default().removeObserver(observer)
    }
}
