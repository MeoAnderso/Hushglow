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
    var displayControlAvailable: Bool
    var brightness: Level?
    var volume: Level?
    var muted: Bool
    var accessGranted: Bool
    var keyTapActive: Bool
    var soundGoesToDisplay: Bool
    var quarterSteps: Bool
    var shortcuts: [ShortcutStatus]
    var input: Input
}

/// The link between the command line and the running app, over distributed notifications.
/// The app serves it with an instance; the command line uses the static functions.
@MainActor
final class CommandChannel: NSObject {
    private static let commandNotification = Notification.Name("\(AppInfo.bundleID).command")
    private static let shortcutsChangedNotification = Notification.Name("\(AppInfo.bundleID).shortcutsChanged")
    private static let statusRequestNotification = Notification.Name("\(AppInfo.bundleID).statusRequest")
    private static let statusReplyPrefix = "\(AppInfo.bundleID).statusReply."

    private let onCommand: (Command) -> Void
    private let onShortcutsChanged: () -> Void
    private let status: () -> AppStatus

    // MARK: App side

    init(
        onCommand: @escaping (Command) -> Void, onShortcutsChanged: @escaping () -> Void,
        status: @escaping () -> AppStatus
    ) {
        self.onCommand = onCommand
        self.onShortcutsChanged = onShortcutsChanged
        self.status = status
        super.init()
        let center = DistributedNotificationCenter.default()
        for (selector, name) in [
            (#selector(commandReceived), Self.commandNotification),
            (#selector(shortcutsChanged), Self.shortcutsChangedNotification),
            (#selector(statusRequested), Self.statusRequestNotification),
        ] {
            center.addObserver(
                self, selector: selector, name: name, object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    @objc private func commandReceived(_ notification: Notification) {
        guard let text = notification.object as? String,
            let command = Command(words: text.split(separator: " ").map(String.init))
        else { return }
        onCommand(command)
    }

    @objc private func shortcutsChanged() {
        onShortcutsChanged()
    }

    @objc private func statusRequested(_ notification: Notification) {
        // The request names the notification to answer with; only answer names of our own.
        guard let replyName = notification.object as? String, replyName.hasPrefix(Self.statusReplyPrefix),
            let json = try? JSONEncoder().encode(status())
        else { return }
        Self.post(Notification.Name(replyName), String(decoding: json, as: UTF8.self))
    }

    // MARK: Command line side

    static func send(_ command: Command) {
        post(commandNotification, command.words.joined(separator: " "))
    }

    static func notifyShortcutsChanged() {
        post(shortcutsChangedNotification, nil)
    }

    /// Asks the running app for its status; nil when it is not running or does not answer in time.
    static func requestStatus(timeout: TimeInterval = 1.5) -> AppStatus? {
        guard AppInfo.otherInstance != nil else { return nil }
        final class Reply: @unchecked Sendable {
            var json: String?
        }
        let reply = Reply()
        let replyName = Notification.Name(statusReplyPrefix + String(ProcessInfo.processInfo.processIdentifier))
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: replyName, object: nil, queue: .main) { notification in
            reply.json = notification.object as? String
        }
        defer { center.removeObserver(observer) }

        post(statusRequestNotification, replyName.rawValue)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while reply.json == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return reply.json.flatMap { try? JSONDecoder().decode(AppStatus.self, from: Data($0.utf8)) }
    }

    private static func post(_ name: Notification.Name, _ object: String?) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: object, userInfo: nil, deliverImmediately: true)
    }
}
