import AppKit
import HushglowCore
import ServiceManagement

/// Command-line front end. Commands and readings go through the running app when there is one,
/// so its cached state and on-screen indicator stay in sync and only one process talks to the
/// display; otherwise they are sent to the display directly.
@MainActor
enum CLI {
    private static let quarterStepsWord = "quarter-steps"
    private static let noTransport = "This macOS no longer provides the display control functions."
    private static let notRunning = "\(AppInfo.name) is not running."
    private static let didNotAnswer = "\(AppInfo.name) is running but did not answer."
    private static let client = CommandClient()

    private static let usage = """
        Usage:
          Hushglow                                   run the menu bar app
          Hushglow step brightness|volume|contrast up|down [--fine] [--display <n>]
          Hushglow set brightness|volume|contrast <0-100> [--display <n>]
          Hushglow mute [toggle|on|off] [--display <n>]   n as numbered by status; every display without it
          Hushglow input dp1|dp2|hdmi1|hdmi2|usbc [--display <n>]
          Hushglow get brightness|volume|mute|contrast|input
          Hushglow shortcut                          list shortcuts
          Hushglow shortcut <action> <keys|none|default>   for example: brightness-up ctrl+alt+up
          Hushglow shortcut quarter-steps on|off|cmd|shift|alt|ctrl
                                                        also register each stepping shortcut with that
                                                        modifier added, Cmd unless another is named
          Hushglow status                            what the running app sees and has received
          Hushglow watch-keys [seconds]              show which special keys reach the app
          Hushglow doctor [--write-test] [--key-test]   check the display connection and the key path
          Hushglow help                              show this
        """

    /// Whether the arguments are meant for the command line and not for the app. No arguments
    /// start the app, and so do settings handed over as `-Name value`, which is how macOS and
    /// Xcode pass them. Anything else is a command, a mistyped one included: it gets the usage
    /// text, not a second copy of the app.
    static func handles(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return !first.hasPrefix("-") || first.hasPrefix("--") || first == "-h"
    }

    static func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "doctor": doctor(writeTest: arguments.contains("--write-test"), keyTest: arguments.contains("--key-test"))
        case "status": status()
        case "watch-keys": watchKeys(arguments)
        case "get": get(arguments)
        case "set", "step", "mute", "input": send(arguments)
        case "shortcut": shortcut(Array(arguments.dropFirst()))
        case "help", "--help", "-h": succeed(usage)
        default: fail(usage, status: 64)
        }
    }

    // MARK: Commands

    /// Takes `--display <n>` out of the arguments; nil when it is there without a number of 1
    /// or more.
    static func displayOption(in arguments: [String]) -> (arguments: [String], display: Int?)? {
        guard let index = arguments.firstIndex(of: "--display") else { return (arguments, nil) }
        guard index + 1 < arguments.count, let number = Int(arguments[index + 1]), number > 0 else { return nil }
        var rest = arguments
        rest.removeSubrange(index...(index + 1))
        return (rest, number)
    }

    private static func send(_ arguments: [String]) -> Int32 {
        guard let (words, display) = displayOption(in: arguments), let command = Command(words: words) else {
            return fail(usage, status: 64)
        }
        if AppInfo.otherInstance != nil {
            let send = { ask(.command(command, display: display)) { _ in 0 } }
            guard let display else { return send() }
            return ask(.status) { reply in
                display <= reply.status?.displays?.count ?? 0
                    ? send() : fail("There is no display \(display); `status` lists them.")
            }
        }
        guard let io = IOAV.shared else { return fail(noTransport) }
        // Numbered as the running app numbers them: the displays that answer, in order.
        var answering = io.displays().map { ($0, io.state(of: $0)) }.filter(\.1.isControllable)
        if let display {
            guard answering.indices.contains(display - 1) else { return fail("There is no display \(display).") }
            answering = [answering[display - 1]]
        }
        var applied = false
        for (display, state) in answering {
            var state = state
            guard let outcome = state.apply(command) else { continue }
            for write in outcome.writes { io.set(display, write.feature, value: write.value) }
            applied = true
        }
        return applied ? 0 : fail("No connected display supports that control.")
    }

    private static func get(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2, let feature = DDC.Feature(name: arguments[1]) else {
            return fail(usage, status: 64)
        }
        if AppInfo.otherInstance != nil {
            // The running app does the reading: two processes must not talk to a display at once.
            return ask(.values(of: feature)) { reply in
                show((reply.values ?? []).map { DDC.Value(current: $0.current, maximum: $0.maximum) }, of: feature)
            }
        }
        guard let io = IOAV.shared else { return fail(noTransport) }
        return show(io.displays().compactMap { io.get($0, feature) }, of: feature)
    }

    private static func show(_ values: [DDC.Value], of feature: DDC.Feature) -> Int32 {
        guard !values.isEmpty else { return fail("No connected display answered.") }
        for value in values {
            switch feature {
            case .mute: print(value.current == DDC.Mute.on ? "on" : "off")
            case .input: print(DDC.Input(reported: value.current)?.name ?? "input \(value.current)")
            default: print("\(value.current)/\(value.maximum)")
            }
        }
        return 0
    }

    // MARK: Shortcuts

    private static func shortcut(_ arguments: [String]) -> Int32 {
        if arguments.isEmpty {
            for action in Shortcut.Action.allCases {
                print("\(action.rawValue): \(ShortcutSettings.text(for: action) ?? "none")")
            }
            let modifier = ShortcutSettings.quarterStepModifier.name ?? ""
            return succeed("\(quarterStepsWord): \(ShortcutSettings.quarterSteps ? "on" : "off"), with \(modifier)")
        }
        guard arguments.count == 2 else { return fail(usage, status: 64) }

        if arguments[0] == quarterStepsWord {
            let named = Shortcut.Modifiers(name: arguments[1])
            guard ["on", "off"].contains(arguments[1]) || named != nil else { return fail(usage, status: 64) }
            let modifier = named ?? ShortcutSettings.quarterStepModifier
            if arguments[1] != "off",
                let clash = Shortcut.firstClash(among: ShortcutSettings.shortcuts, quarterStep: modifier)
            {
                return fail(
                    "With \(modifier.title ?? "that") for quarter steps, \(clash.action.rawValue) and "
                        + "\(clash.other.rawValue) would both take \(clash.keys.text).", status: 64)
            }
            ShortcutSettings.quarterStepModifier = modifier
            ShortcutSettings.quarterSteps = arguments[1] != "off"
        } else if let action = Shortcut.Action(rawValue: arguments[0]) {
            switch arguments[1] {
            case "default":
                ShortcutSettings.set(nil, for: action)
            case "none":
                ShortcutSettings.set("", for: action)
            case let keys:
                guard let parsed = Shortcut(keys) else {
                    return fail(
                        "Not a valid shortcut: \(keys). Use modifiers (ctrl, alt, shift, cmd) plus an arrow, "
                            + "page or function key, for example ctrl+alt+up or shift+f15.", status: 64)
                }
                switch Shortcut.check(
                    parsed, for: action, others: ShortcutSettings.shortcuts,
                    quarterStep: ShortcutSettings.quarterStep, isUsedBySystem: Hotkeys.usedByMacOS().contains)
                {
                case .needsModifier:
                    return fail(
                        "\(keys) on its own would take that key away from every app; add a modifier.", status: 64)
                case .usedBy(let other):
                    return fail("\(other.rawValue) already uses \(keys).", status: 64)
                case .usedBySystem:
                    return fail("macOS uses \(keys) for a shortcut of its own. \(systemShortcutAdvice)", status: 64)
                case .unsupportedKey, nil:
                    break
                }
                ShortcutSettings.set(parsed.text, for: action)
            }
        } else {
            let actions = Shortcut.Action.allCases.map(\.rawValue).joined(separator: ", ")
            return fail("Unknown action: \(arguments[0]). Actions: \(actions), \(quarterStepsWord)", status: 64)
        }

        guard AppInfo.otherInstance != nil else { return succeed("Saved. \(notRunning)") }
        // The running app answers once it has registered the new shortcuts.
        return ask(.shortcutsChanged) { reply in
            guard let status = reply.status else { return fail(didNotAnswer) }
            return report(status.shortcuts)
        }
    }

    /// What became of the shortcuts the running app registered.
    private static func report(_ shortcuts: [AppStatus.ShortcutStatus]) -> Int32 {
        let refused = shortcuts.filter { !$0.registered }
        let clashing = shortcuts.filter(\.usedByMacOS)
        for entry in shortcuts { print(describe(entry)) }
        if !refused.isEmpty {
            return fail("macOS refused \(refused.map(\.keys).joined(separator: ", ")); choose other keys.")
        }
        return clashing.isEmpty
            ? 0
            : fail(
                "macOS uses \(clashing.map(\.keys).joined(separator: ", ")) for shortcuts of its own, so they may "
                    + "not work. \(systemShortcutAdvice)")
    }

    private static let systemShortcutAdvice =
        "Choose other keys, or switch that one off in System Settings › Keyboard › Keyboard Shortcuts."

    // MARK: Status, key watch and doctor

    private static func status() -> Int32 {
        guard AppInfo.otherInstance != nil else { return fail(notRunning) }
        return ask(.status) { reply in reply.status.map { succeed(describe($0)) } ?? fail(didNotAnswer) }
    }

    /// Has the running app record, for a few seconds, which special keys reach it.
    private static func watchKeys(_ arguments: [String]) -> Int32 {
        let seconds = arguments.count > 1 ? Int(arguments[1]) ?? 0 : 10
        guard arguments.count <= 2, (1...60).contains(seconds) else { return fail(usage, status: 64) }
        guard AppInfo.otherInstance != nil else { return fail(notRunning) }
        let isOn = ask(.status) { reply in
            reply.status?.keyTapActive == true
                ? 0
                : fail(
                    "Watching keys needs the \(KeyboardKeys.phrase) turned on; choose \"Turn On "
                        + "\(KeyboardKeys.name)…\" in the menu.")
        }
        guard isOn == 0, ask(.watchKeys(seconds: seconds), then: { _ in 0 }) == 0 else { return 1 }
        print("Press the keys you want to identify. Watching for \(seconds) seconds; ordinary typing is not recorded.")
        Thread.sleep(forTimeInterval: TimeInterval(seconds) + 0.5)
        guard let seen = client.requestStatus()?.watchedKeys else { return fail("The app did not report back.") }
        if seen.isEmpty {
            return succeed(
                "Nothing arrived. If you pressed the keyboard's brightness or volume keys, the keyboard does not send them in a "
                    + "form macOS passes on, so they cannot be used; give those actions a shortcut instead.")
        }
        return succeed(seen.map { "  \($0)" }.joined(separator: "\n"))
    }

    private static func doctor(writeTest: Bool, keyTest: Bool) -> Int32 {
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

        let reply = AppInfo.otherInstance == nil ? nil : client.ask(.status)
        if AppInfo.otherInstance == nil {
            print("App: not running")
        } else if let refusal = reply?.refusal {
            print("App: running, but it did not answer: \(refusal)")
            healthy = false
        } else if let status = reply?.status {
            print("App: running\n" + describe(status).split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
            healthy = healthy && status.shortcuts.allSatisfy { $0.registered && !$0.usedByMacOS }
            if keyTest { healthy = self.keyTest(status) && healthy }
        } else {
            print("App: running, but it did not answer")
            healthy = false
        }
        return healthy ? 0 : 1
    }

    /// Nudges a feature by one unit, reads it back, then restores and re-reads the original value.
    private static func writeTest(
        _ io: IOAV, _ display: AVService, _ feature: DDC.Feature, _ original: DDC.Value?
    )
        -> Bool
    {
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

    /// Has the app send a simulated volume key through the system and checks that it came back
    /// to the app, which proves the path the keyboard's own keys take. Volume is put back.
    private static func keyTest(_ before: AppStatus) -> Bool {
        guard before.keyTapActive, before.soundGoesToDisplay, let volume = before.volume else {
            print("  Key test: skipped; it needs the \(KeyboardKeys.phrase) on and sound going to the display")
            return true
        }
        _ = client.ask(.keyTest)
        Thread.sleep(forTimeInterval: 0.6)
        let after = client.requestStatus()
        let percent = Int((Double(volume.current) * 100 / Double(volume.maximum)).rounded())
        _ = client.ask(.command(.set(.volume, percent: percent)))
        if before.muted { _ = client.ask(.command(.mute(.on))) }
        let received = (after?.input.keysHandled ?? 0) > before.input.keysHandled
        let moved = after?.volume.map { "volume \(volume.current) -> \($0.current), put back" } ?? "no answer"
        let outcome = received ? "passed, a simulated volume key reached" : "FAILED, no simulated volume key reached"
        print("  Key test: \(outcome) the app (\(moved))")
        return received
    }

    // MARK: Descriptions

    static func describe(_ status: AppStatus) -> String {
        var lines = ["\(AppInfo.name) \(status.version)" + (status.build.map { ", build \($0)" } ?? "")]
        if !status.displayControlAvailable {
            lines.append("Display: control is unavailable on this macOS")
        } else if status.brightness == nil, status.volume == nil {
            lines.append("Display: none that can be controlled")
        } else if let displays = status.displays, displays.count > 1 {
            for (index, display) in displays.enumerated() {
                lines.append(
                    "Display \(index + 1), \(display.name): brightness \(describe(display.brightness)), "
                        + "volume \(describe(display.volume)), mute \(display.muted ? "on" : "off")"
                        + Self.describeExtras(display))
            }
        } else {
            lines.append(
                "Display: brightness \(describe(status.brightness)), volume \(describe(status.volume)), "
                    + "mute \(status.muted ? "on" : "off")" + (status.displays?.first.map(Self.describeExtras) ?? ""))
        }
        if let milliseconds = status.lastReadMilliseconds {
            // A read takes its time for each value, so the figure says little without their number.
            let values = status.lastReadValues.map { " for \($0) value\($0 == 1 ? "" : "s")" } ?? ""
            lines.append("Last read of the display: \(milliseconds) ms\(values)")
        }
        if let bytes = status.memoryFootprint {
            lines.append("Memory: \(String(format: "%.1f", Double(bytes) / 1_048_576)) MB")
        }

        if status.keyTapActive {
            lines.append(
                "\(KeyboardKeys.name): active, "
                    + (status.soundGoesToDisplay
                        ? "controlling the display" : "left to macOS while sound goes elsewhere"))
        } else if status.accessGranted {
            lines.append("\(KeyboardKeys.name): OFF, access is granted but the key tap could not start")
        } else {
            lines.append(
                "\(KeyboardKeys.name): OFF, not yet allowed under \(AccessibilityAccess.listName) "
                    + "(choose \"Turn On \(KeyboardKeys.name)…\" in the menu)"
                    + (status.askingIsDisabled ? "; asking is switched off" : ""))
        }

        lines.append("Shortcuts:" + (status.shortcuts.isEmpty ? " none registered" : ""))
        lines += status.shortcuts.map { "  " + describe($0) }
        // A build from before the modifier could be chosen used Shift.
        let modifier = status.quarterStepModifier.flatMap(Shortcut.Modifiers.init(name:))?.title ?? "Shift"
        lines.append("Quarter steps: \(status.quarterSteps ? "on" : "off"), with \(modifier)")

        let input = status.input
        lines.append(
            "Input since launch: \(input.shortcutPresses) shortcut presses, \(input.keysHandled) keys handled, "
                + "\(input.keysLeftToSystem) keys left to macOS")
        if let last = input.last, let lastAt = input.lastAt {
            lines.append("Last input: \(last), \(Int(Date().timeIntervalSince(lastAt))) s ago")
        }
        return lines.joined(separator: "\n")
    }

    /// Contrast and the input, for a display that has them.
    private static func describeExtras(_ display: AppStatus.DisplayStatus) -> String {
        let contrast = display.contrast.map { ", contrast \(describe($0))" } ?? ""
        let input = display.input.map { ", input \(DDC.Input(reported: $0)?.title ?? String($0))" } ?? ""
        return contrast + input
    }

    private static func describe(_ shortcut: AppStatus.ShortcutStatus) -> String {
        "\(shortcut.action): \(shortcut.keys)\(shortcut.registered ? "" : "  REFUSED by macOS")"
            + (shortcut.usedByMacOS ? "  USED by macOS itself" : "")
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

    /// Sends a request to the running app and hands on its answer; without one, says why.
    private static func ask(_ request: ChannelRequest, then use: (ChannelReply) -> Int32) -> Int32 {
        guard let reply = client.ask(request) else { return fail(didNotAnswer) }
        if let refusal = reply.refusal { return fail(refusal) }
        return use(reply)
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
