import Darwin
import Foundation
import HushglowCore
import Security

/// What the running app reports about itself to `Hushglow status` and `doctor`.
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

/// One request from the command line to the app.
struct ChannelRequest: Codable, Equatable {
    enum Kind: String, Codable {
        case command, shortcutsChanged, keyTest, watchKeys, status, values
    }

    var kind: Kind
    /// A command's words, such as `step brightness up`.
    var words: [String]?
    /// The display a command is for, numbered from 1 as `status` lists them; nil for every display.
    var display: Int?
    /// How long a key watch lasts.
    var seconds: Int?
    /// The feature to read, by name.
    var feature: String?

    static func command(_ command: Command, display: Int? = nil) -> Self {
        Self(kind: .command, words: command.words, display: display)
    }

    static func watchKeys(seconds: Int) -> Self { Self(kind: .watchKeys, seconds: seconds) }
    static func values(of feature: DDC.Feature) -> Self { Self(kind: .values, feature: feature.name) }
    static let shortcutsChanged = Self(kind: .shortcutsChanged)
    static let keyTest = Self(kind: .keyTest)
    static let status = Self(kind: .status)
}

/// The app's answer to a request.
struct ChannelReply: Codable {
    /// After `status`, and after `shortcutsChanged` once the shortcuts are registered again.
    var status: AppStatus?
    /// After `values`: one per display, in the order `status` lists them.
    var values: [AppStatus.Level]?
    /// Why the app did not take the request; nil when it did.
    var refusal: String?

    static let taken = Self()
    static func refused(_ reason: String) -> Self { Self(refusal: reason) }
}

/// Where the command line finds the running app: a socket in this user's own temporary
/// folder, which no other user can open.
enum ChannelAddress {
    /// The longest path a socket address holds, its closing zero left out.
    static let maximumLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func path(for name: String) -> String {
        var folder = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let length = folder.withUnsafeMutableBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { confstr(_CS_DARWIN_USER_TEMP_DIR, $0.baseAddress, $0.count) }
        }
        // The length includes the closing zero.
        let base = length > 1 ? String(decoding: folder.prefix(length - 1), as: UTF8.self) : NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("\(name).channel")
    }

    /// The socket address for a path; nil when the path is too long for one.
    static func address(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumLength else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}

/// Who may talk to the app: code whose signature meets the app's own designated requirement.
/// That is the same build while the app is ad-hoc signed, and the same certificate and
/// identifier once it has one. The command line is the app's own executable, so it meets it.
struct CallerRequirement: @unchecked Sendable {
    // A requirement is an immutable Core Foundation object, safe to share between threads.
    let requirement: SecRequirement

    /// The requirement the running code makes of itself; nil when it cannot be read.
    static let own: CallerRequirement? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement
        else { return nil }
        return CallerRequirement(requirement: requirement)
    }()

    init(requirement: SecRequirement) {
        self.requirement = requirement
    }

    /// A requirement written in the code-signing requirement language.
    init?(_ text: String) {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return nil }
        self.requirement = requirement
    }

    /// Whether the process at the other end of a connected socket meets the requirement. It is
    /// told by its audit token, which, unlike a process number, cannot pass to another process.
    func isMet(byPeerOf socket: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

/// Reading and writing one line of JSON on a socket that blocks, within its time limits.
private enum Line {
    /// No request or answer comes near this; a peer that sends more is not listened to.
    static let maximumLength = 1 << 20

    static func setTimeLimit(_ seconds: TimeInterval, on socket: Int32) {
        var limit = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &limit, size)
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &limit, size)
        // A peer that has gone away must not take the process down with it.
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func read(from socket: Int32) -> Data? {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while line.count < maximumLength {
            let count = Darwin.read(socket, &buffer, buffer.count)
            guard count > 0 else { return nil }
            if let end = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                return line + buffer[..<end]
            }
            line.append(contentsOf: buffer[..<count])
        }
        return nil
    }

    static func write(_ value: some Encodable, to socket: Int32) -> Bool {
        guard var bytes = try? JSONEncoder().encode(value) else { return false }
        bytes.append(UInt8(ascii: "\n"))
        return bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(socket, buffer.baseAddress! + sent, buffer.count - sent)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }
}

/// The app's end of the link to the command line. It answers one request per connection,
/// and only a caller that meets the app's own signature requirement: the command line can
/// change the displays, start a key watch and read the app's status, so no other program on
/// the Mac may.
@MainActor
final class CommandChannel {
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

    nonisolated static let notTheApp =
        "\(AppInfo.name) answers only its own command line, from the same build or signed alike, and this is not it."

    private let handlers: Handlers
    let path: String
    private let listener: Int32
    /// Set once the channel exists, since it holds on to the channel.
    private var source: DispatchSourceRead?

    /// Listens under a name of the channel's own; tests use names of theirs, so that they
    /// never reach the installed app. Nil when the socket cannot be made; a caller that meets
    /// `requirement` is answered, and nobody when there is none.
    init?(name: String = AppInfo.bundleID, requirement: CallerRequirement? = .own, handlers: Handlers) {
        let path = ChannelAddress.path(for: name)
        guard var address = ChannelAddress.address(path) else { return nil }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return nil }
        // A socket left by an earlier run that ended without removing it. Only one copy of the
        // app runs at a time, so nothing else is listening there.
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else {
            close(listener)
            return nil
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

        self.handlers = handlers
        self.path = path
        self.listener = listener
        source = Self.accept(on: listener) { [weak self] client in
            if let self {
                serve(client, requirement: requirement)
            } else {
                close(client)
            }
        }
    }

    /// Takes each caller as it connects, off the main thread. Made outside the initializer, so
    /// that the handlers do not take on the main actor's isolation.
    nonisolated private static func accept(
        on listener: Int32, serving serve: @escaping @Sendable (Int32) -> Void
    ) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            while case let client = Darwin.accept(listener, nil, nil), client >= 0 { serve(client) }
        }
        source.setCancelHandler { close(listener) }
        source.resume()
        return source
    }

    func stop() {
        source?.cancel()
        unlink(path)
    }

    /// Reads one request off the thread that accepted it, and answers it on the main thread,
    /// where the app's state lives.
    nonisolated private func serve(_ client: Int32, requirement: CallerRequirement?) {
        // An accepted socket takes after the listener; this one is read and written in turn.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        Line.setTimeLimit(2, on: client)
        let finish: @Sendable (ChannelReply) -> Void = { reply in
            _ = Line.write(reply, to: client)
            close(client)
        }
        guard let line = Line.read(from: client),
            let request = try? JSONDecoder().decode(ChannelRequest.self, from: line)
        else { return finish(.refused("Not a request.")) }
        guard requirement?.isMet(byPeerOf: client) == true else {
            return finish(.refused(Self.notTheApp))
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.handle(request) { reply in DispatchQueue.global(qos: .userInitiated).async { finish(reply) } }
            }
        }
    }

    private func handle(_ request: ChannelRequest, reply: @escaping @Sendable (ChannelReply) -> Void) {
        switch request.kind {
        case .command:
            guard let command = Command(words: request.words ?? []), (request.display ?? 1) > 0 else {
                return reply(.refused("Not a command."))
            }
            handlers.onCommand(command, request.display)
            reply(.taken)
        case .shortcutsChanged:
            handlers.onShortcutsChanged()
            reply(ChannelReply(status: handlers.status()))
        case .keyTest:
            handlers.onKeyTest()
            reply(.taken)
        case .watchKeys:
            guard let seconds = request.seconds, (1...60).contains(seconds) else {
                return reply(.refused("A key watch lasts 1 to 60 seconds."))
            }
            handlers.onWatchKeys(TimeInterval(seconds))
            reply(.taken)
        case .status:
            reply(ChannelReply(status: handlers.status()))
        case .values:
            guard let feature = request.feature.flatMap(DDC.Feature.init(name:)) else {
                return reply(.refused("Not a feature."))
            }
            handlers.readValues(feature) { reply(ChannelReply(values: $0)) }
        }
    }
}

/// The command line's end of the link to the running app. Each request waits for its answer,
/// on the thread it is made on.
struct CommandClient: Sendable {
    /// Long enough for the app to read every display, which can take a few hundred
    /// milliseconds each when one is slow.
    static let timeout: TimeInterval = 3

    let path: String

    init(name: String = AppInfo.bundleID) {
        path = ChannelAddress.path(for: name)
    }

    /// Sends a request and returns the app's answer; nil when nothing answers in time.
    func ask(_ request: ChannelRequest, timeout: TimeInterval = Self.timeout) -> ChannelReply? {
        guard var address = ChannelAddress.address(path) else { return nil }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        Line.setTimeLimit(timeout, on: socket)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, Line.write(request, to: socket), let line = Line.read(from: socket) else { return nil }
        return try? JSONDecoder().decode(ChannelReply.self, from: line)
    }

    /// The app's status; nil when it does not answer or turns the request down.
    func requestStatus(timeout: TimeInterval = Self.timeout) -> AppStatus? {
        ask(.status, timeout: timeout)?.status
    }
}
