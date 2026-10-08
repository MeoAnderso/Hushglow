import AppKit
import DisplayKeysCore
import ServiceManagement

/// Command-line front end. Commands go to the running app when there is one, so its cached
/// state and on-screen indicator stay in sync; otherwise they are sent to the display directly.
@MainActor
enum CLI {
    static let verbs: Set<String> = ["doctor", "get", "set", "step", "mute", "shortcut", "help"]

    private static let usage = """
        Usage:
          DisplayKeys                                   run the menu bar app
          DisplayKeys step brightness|volume up|down [--fine]
          DisplayKeys set brightness|volume <0-100>
          DisplayKeys mute [toggle|on|off]
          DisplayKeys get brightness|volume|mute
          DisplayKeys shortcut                          list shortcuts
          DisplayKeys shortcut <action> <keys|none|default>   for example: brightness-up ctrl+alt+up
          DisplayKeys doctor [--write-test]             check the display connection
        """

    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "doctor": doctor(writeTest: arguments.contains("--write-test"))
        case "get": get(arguments)
        case "set", "step", "mute": send(arguments)
        case "shortcut": shortcut(Array(arguments.dropFirst()))
        case "help": succeed(usage)
        default: fail(usage, status: 64)
        }
    }

    // MARK: Commands

    private static func send(_ arguments: [String]) -> Int32 {
        guard let command = Command(words: arguments) else { return fail(usage, status: 64) }
        if AppInfo.otherInstance != nil {
            post(AppInfo.commandNotification, object: command.words.joined(separator: " "))
            return 0
        }
        guard let io = IOAV.shared else { return fail("This macOS no longer provides the display control functions.") }
        var applied = false
        for service in io.externalServices() {
            var state = io.state(of: service)
            guard let outcome = state.apply(command) else { continue }
            for write in outcome.writes { io.set(service, write.feature, value: write.value) }
            applied = true
        }
        return applied ? 0 : fail("No connected display supports that control.")
    }

    private static func get(_ arguments: [String]) -> Int32 {
        let features: [String: DDC.Feature] = ["brightness": .brightness, "volume": .volume, "mute": .mute]
        guard arguments.count == 2, let feature = features[arguments[1]] else { return fail(usage, status: 64) }
        guard let io = IOAV.shared else { return fail("This macOS no longer provides the display control functions.") }
        let values = io.externalServices().compactMap { io.get($0, feature) }
        guard !values.isEmpty else { return fail("No connected display answered.") }
        for value in values {
            print(feature == .mute ? (value.current == DDC.Mute.on ? "on" : "off") : "\(value.current)/\(value.maximum)")
        }
        return 0
    }

    // MARK: Shortcuts

    private static func shortcut(_ arguments: [String]) -> Int32 {
        if arguments.isEmpty {
            for action in Shortcut.Action.allCases {
                print("\(action.rawValue): \(ShortcutSettings.text(for: action) ?? "none")")
            }
            return 0
        }
        guard arguments.count == 2, let action = Shortcut.Action(rawValue: arguments[0]) else {
            let actions = Shortcut.Action.allCases.map(\.rawValue).joined(separator: ", ")
            return fail("Usage: DisplayKeys shortcut <action> <keys|none|default>\nActions: \(actions)", status: 64)
        }
        switch arguments[1] {
        case "default":
            ShortcutSettings.set(nil, for: action)
        case "none":
            ShortcutSettings.set("", for: action)
        case let text:
            guard Shortcut(text) != nil else {
                return fail("Not a valid shortcut: \(text). Use modifiers (ctrl, alt, shift, cmd) plus an arrow, "
                    + "page or function key, for example ctrl+alt+up or shift+f15.", status: 64)
            }
            ShortcutSettings.set(text.lowercased(), for: action)
        }
        post(AppInfo.shortcutsChangedNotification, object: nil)
        return succeed("\(action.rawValue): \(ShortcutSettings.text(for: action) ?? "none")")
    }

    // MARK: Doctor

    private static func doctor(writeTest: Bool) -> Int32 {
        print("\(AppInfo.name) \(AppInfo.version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("App running: \(AppInfo.otherInstance.map { "yes (pid \($0.processIdentifier))" } ?? "no")")
        guard let io = IOAV.shared else {
            return fail("Display control functions: MISSING. This macOS removed the private IOAVService functions.")
        }
        print("Display control functions: available")

        let services = io.externalServices()
        print("External displays: \(services.count)")
        var healthy = !services.isEmpty
        for (index, service) in services.enumerated() {
            let state = io.state(of: service)
            let mute = state.hasHardwareMute ? (state.isMuted ? "on" : "off") : "not supported"
            print("  [\(index + 1)] brightness \(describe(state.brightness)), volume \(describe(state.volume)), mute \(mute)")
            if !state.isControllable {
                print("      No DDC answer. Check that DDC/CI is enabled in the display's own menu.")
                healthy = false
            }
            if writeTest {
                healthy = self.writeTest(io, service, .brightness, state.brightness) && healthy
                healthy = self.writeTest(io, service, .volume, state.volume) && healthy
            }
        }

        let audio = AudioRoute()
        audio.refresh()
        print("Sound output: \(audio.outputIsDisplay ? "a display (volume keys control the display)" : "not a display (volume keys are left to macOS)")")
        print("Launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
        for action in Shortcut.Action.allCases {
            if let text = ShortcutSettings.text(for: action) { print("Shortcut \(action.rawValue): \(text)") }
        }
        return healthy ? 0 : 1
    }

    /// Nudges a feature by one unit, reads it back, then restores and re-reads the original value.
    private static func writeTest(_ io: IOAV, _ service: AVService, _ feature: DDC.Feature, _ original: DDC.Value?) -> Bool {
        guard let original else { return true }
        let probe = original.current < original.maximum ? original.current + 1 : original.current - 1
        io.set(service, feature, value: probe)
        usleep(100_000)
        let changed = io.get(service, feature)?.current
        io.set(service, feature, value: original.current)
        usleep(100_000)
        let restored = io.get(service, feature)?.current
        let passed = changed == probe && restored == original.current
        print("      write test \(feature): \(passed ? "passed" : "FAILED") "
            + "(\(original.current) -> \(describe(changed)) -> \(describe(restored)))")
        return passed
    }

    // MARK: Helpers

    private static func describe(_ value: DDC.Value?) -> String {
        value.map { "\($0.current)/\($0.maximum)" } ?? "not supported"
    }

    private static func describe(_ value: Int?) -> String {
        value.map(String.init) ?? "no answer"
    }

    private static func post(_ name: Notification.Name, object: String?) {
        DistributedNotificationCenter.default().postNotificationName(name, object: object, userInfo: nil, deliverImmediately: true)
    }

    private static func succeed(_ message: String) -> Int32 {
        print(message)
        return 0
    }

    private static func fail(_ message: String, status: Int32 = 1) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return status
    }
}
