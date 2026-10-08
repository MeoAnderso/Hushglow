import AppKit
import DisplayKeysCore
import ServiceManagement

/// Command-line front end. Commands go to the running app when there is one, so its cached
/// state and on-screen indicator stay in sync; otherwise they are sent to the display directly.
@MainActor
enum CLI {
    static let verbs: Set<String> = ["doctor", "status", "get", "set", "step", "mute", "shortcut", "help"]

    private static let quarterStepsWord = "quarter-steps"
    private static let noTransport = "This macOS no longer provides the display control functions."

    private static let usage = """
        Usage:
          DisplayKeys                                   run the menu bar app
          DisplayKeys step brightness|volume up|down [--fine]
          DisplayKeys set brightness|volume <0-100>
          DisplayKeys mute [toggle|on|off]
          DisplayKeys get brightness|volume|mute
          DisplayKeys shortcut                          list shortcuts
          DisplayKeys shortcut <action> <keys|none|default>   for example: brightness-up ctrl+alt+up
          DisplayKeys shortcut quarter-steps on|off     also register each stepping shortcut with Shift
          DisplayKeys status                            what the running app sees and has received
          DisplayKeys doctor [--write-test]             check the display connection
        """

    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "doctor": doctor(writeTest: arguments.contains("--write-test"))
        case "status": status()
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
            CommandChannel.send(command)
            return 0
        }
        guard let io = IOAV.shared else { return fail(noTransport) }
        var applied = false
        for display in io.displays() {
            var state = io.state(of: display)
            guard let outcome = state.apply(command) else { continue }
            for write in outcome.writes { io.set(display, write.feature, value: write.value) }
            applied = true
        }
        return applied ? 0 : fail("No connected display supports that control.")
    }

    private static func get(_ arguments: [String]) -> Int32 {
        let features: [String: DDC.Feature] = ["brightness": .brightness, "volume": .volume, "mute": .mute]
        guard arguments.count == 2, let feature = features[arguments[1]] else { return fail(usage, status: 64) }
        guard let io = IOAV.shared else { return fail(noTransport) }
        let values = io.displays().compactMap { io.get($0, feature) }
        guard !values.isEmpty else { return fail("No connected display answered.") }
        for value in values {
            print(
                feature == .mute ? (value.current == DDC.Mute.on ? "on" : "off") : "\(value.current)/\(value.maximum)")
        }
        return 0
    }

    // MARK: Shortcuts

    private static func shortcut(_ arguments: [String]) -> Int32 {
        if arguments.isEmpty {
            for action in Shortcut.Action.allCases {
                print("\(action.rawValue): \(ShortcutSettings.text(for: action) ?? "none")")
            }
            return succeed("\(quarterStepsWord): \(ShortcutSettings.quarterSteps ? "on" : "off")")
        }
        guard arguments.count == 2 else { return fail(usage, status: 64) }

        if arguments[0] == quarterStepsWord {
            guard ["on", "off"].contains(arguments[1]) else { return fail(usage, status: 64) }
            ShortcutSettings.quarterSteps = arguments[1] == "on"
        } else if let action = Shortcut.Action(rawValue: arguments[0]) {
            switch arguments[1] {
            case "default":
                ShortcutSettings.set(nil, for: action)
            case "none":
                ShortcutSettings.set("", for: action)
            case let keys:
                guard Shortcut(keys) != nil else {
                    return fail(
                        "Not a valid shortcut: \(keys). Use modifiers (ctrl, alt, shift, cmd) plus an arrow, "
                            + "page or function key, for example ctrl+alt+up or shift+f15.", status: 64)
                }
                ShortcutSettings.set(keys.lowercased(), for: action)
            }
        } else {
            let actions = Shortcut.Action.allCases.map(\.rawValue).joined(separator: ", ")
            return fail("Unknown action: \(arguments[0]). Actions: \(actions), \(quarterStepsWord)", status: 64)
        }

        CommandChannel.notifyShortcutsChanged()
        // The running app answers after it has registered the new shortcuts.
        guard let status = CommandChannel.requestStatus() else { return succeed("Saved. DisplayKeys is not running.") }
        let refused = status.shortcuts.filter { !$0.registered }
        for entry in status.shortcuts { print(describe(entry)) }
        return refused.isEmpty
            ? 0 : fail("macOS refused \(refused.map(\.keys).joined(separator: ", ")); choose other keys.")
    }

    // MARK: Status and doctor

    private static func status() -> Int32 {
        guard AppInfo.otherInstance != nil else { return fail("\(AppInfo.name) is not running.") }
        guard let status = CommandChannel.requestStatus() else {
            return fail("\(AppInfo.name) is running but did not answer.")
        }
        return succeed(describe(status))
    }

    private static func doctor(writeTest: Bool) -> Int32 {
        print("\(AppInfo.name) \(AppInfo.version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        guard let io = IOAV.shared else {
            return fail("Display control functions: MISSING. This macOS removed the private IOAVService functions.")
        }
        print("Display control functions: available")

        let displays = io.displays()
        print("External displays: \(displays.count)")
        var healthy = !displays.isEmpty
        for (index, display) in displays.enumerated() {
            let state = io.state(of: display)
            let mute = state.hasHardwareMute ? (state.isMuted ? "on" : "off") : "not supported"
            let levels = "brightness \(describe(state.brightness)), volume \(describe(state.volume))"
            print("  [\(index + 1)] \(levels), mute \(mute)")
            if !state.isControllable {
                print("      No DDC answer. Check that DDC/CI is enabled in the display's own menu.")
                healthy = false
            }
            if writeTest {
                healthy = self.writeTest(io, display, .brightness, state.brightness) && healthy
                healthy = self.writeTest(io, display, .volume, state.volume) && healthy
            }
        }
        print("Launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")

        if AppInfo.otherInstance == nil {
            print("App: not running")
        } else if let status = CommandChannel.requestStatus() {
            print("App: running\n" + describe(status).split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
            healthy = healthy && status.shortcuts.allSatisfy(\.registered)
        } else {
            print("App: running, but it did not answer")
            healthy = false
        }
        return healthy ? 0 : 1
    }

    /// Nudges a feature by one unit, reads it back, then restores and re-reads the original value.
    private static func writeTest(
        _ io: IOAV, _ display: AVService, _ feature: DDC.Feature, _ original: DDC.Value?
    ) -> Bool {
        guard let original else { return true }
        let probe = original.current < original.maximum ? original.current + 1 : original.current - 1
        io.set(display, feature, value: probe)
        usleep(100_000)
        let changed = io.get(display, feature)?.current
        io.set(display, feature, value: original.current)
        usleep(100_000)
        let restored = io.get(display, feature)?.current
        let passed = changed == probe && restored == original.current
        print(
            "      write test \(feature): \(passed ? "passed" : "FAILED") "
                + "(\(original.current) -> \(describe(changed)) -> \(describe(restored)))")
        return passed
    }

    // MARK: Descriptions

    private static func describe(_ status: AppStatus) -> String {
        var lines: [String] = []
        if !status.displayControlAvailable {
            lines.append("Display: control is unavailable on this macOS")
        } else if status.brightness == nil, status.volume == nil {
            lines.append("Display: none that can be controlled")
        } else {
            lines.append(
                "Display: brightness \(describe(status.brightness)), volume \(describe(status.volume)), "
                    + "mute \(status.muted ? "on" : "off")")
        }

        if status.keyTapActive {
            lines.append(
                "Keyboard volume keys: active, "
                    + (status.soundGoesToDisplay
                        ? "controlling the display" : "left to macOS while sound goes elsewhere"))
        } else if status.accessGranted {
            lines.append("Keyboard volume keys: OFF, access is granted but the key tap could not start")
        } else {
            lines.append(
                "Keyboard volume keys: OFF, waiting for Accessibility access "
                    + "(choose \"Enable Keyboard Volume Keys…\" in the menu)")
        }

        lines.append("Shortcuts:" + (status.shortcuts.isEmpty ? " none registered" : ""))
        lines += status.shortcuts.map { "  " + describe($0) }
        lines.append("Quarter steps with Shift: \(status.quarterSteps ? "on" : "off")")

        let input = status.input
        lines.append(
            "Input since launch: \(input.shortcutPresses) shortcut presses, \(input.keysHandled) keys handled, "
                + "\(input.keysLeftToSystem) keys left to macOS")
        if let last = input.last, let lastAt = input.lastAt {
            lines.append("Last input: \(last), \(Int(Date().timeIntervalSince(lastAt))) s ago")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ shortcut: AppStatus.ShortcutStatus) -> String {
        "\(shortcut.action): \(shortcut.keys)\(shortcut.registered ? "" : "  REFUSED by macOS")"
    }

    private static func describe(_ level: AppStatus.Level?) -> String {
        level.map { "\($0.current)/\($0.maximum)" } ?? "not supported"
    }

    private static func describe(_ value: DDC.Value?) -> String {
        value.map { "\($0.current)/\($0.maximum)" } ?? "not supported"
    }

    private static func describe(_ value: Int?) -> String {
        value.map(String.init) ?? "no answer"
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
