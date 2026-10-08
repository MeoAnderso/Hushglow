import Foundation
import Testing

@testable import DisplayKeysCore

@Suite struct DDCTests {
    @Test func encodesRequests() {
        #expect(DDC.getRequest(.brightness) == [0x82, 0x01, 0x10, 0xAC])
        #expect(DDC.setRequest(.brightness, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        #expect(DDC.setRequest(.volume, value: 70_000)[3...4] == [0xFF, 0xFF])
    }

    // Replies below were captured from a real display over USB-C.
    @Test func parsesCapturedReplies() throws {
        let brightness: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
        #expect(try DDC.parseGetReply(brightness, feature: .brightness) == DDC.Value(current: 50, maximum: 100))

        let volume: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x0D, 0xBF]
        #expect(try DDC.parseGetReply(volume, feature: .volume) == DDC.Value(current: 13, maximum: 100))
    }

    @Test func ignoresTheMangledLengthByte() throws {
        for lengthByte: UInt8 in [0x00, 0x51, 0x88] {
            let reply: [UInt8] = [0x6E, lengthByte, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
            #expect(try DDC.parseGetReply(reply, feature: .brightness).current == 50)
        }
    }

    @Test func aFeatureHasItsCommandLineName() {
        for feature in DDC.Feature.allCases { #expect(DDC.Feature(name: feature.name) == feature) }
        #expect(DDC.Feature(name: "volume") == .volume)
        #expect(DDC.Feature(name: "contrast") == nil)
    }

    @Test func rejectsBadReplies() {
        let null: [UInt8] = [0x6E, 0x80, 0xBE, 0x00, 0xE6, 0xD2, 0xD0, 0xA4, 0x0A, 0xF9, 0xAB]
        #expect(throws: DDC.ReplyError.notReady) { try DDC.parseGetReply(null, feature: .brightness) }

        let corrupt: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x33, 0xF2]
        #expect(throws: DDC.ReplyError.badChecksum) { try DDC.parseGetReply(corrupt, feature: .brightness) }

        let unsupported: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA5]
        #expect(throws: DDC.ReplyError.unsupported) { try DDC.parseGetReply(unsupported, feature: .brightness) }

        let volume: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x0D, 0xBF]
        #expect(throws: DDC.ReplyError.wrongFeature) { try DDC.parseGetReply(volume, feature: .brightness) }
        #expect(throws: DDC.ReplyError.truncated) { try DDC.parseGetReply([0x6E, 0x88], feature: .brightness) }
    }
}

@Suite struct PaceTests {
    @Test func oneLateReplyDoesNotSlowADisplayDown() {
        var pace = DDC.Pace()
        pace.readFinished(missedAReply: true)
        pace.readFinished(missedAReply: true)
        #expect(!pace.needsLongWaits)
        // A read that went well clears the count.
        pace.readFinished(missedAReply: false)
        pace.readFinished(missedAReply: true)
        pace.readFinished(missedAReply: true)
        #expect(!pace.needsLongWaits)
    }

    @Test func aDisplayThatKeepsMissingGetsTheLongWaitsForGood() {
        var pace = DDC.Pace()
        for _ in 0..<DDC.Pace.missesBeforeLongWaits { pace.readFinished(missedAReply: true) }
        #expect(pace.needsLongWaits)
        pace.readFinished(missedAReply: false)
        #expect(pace.needsLongWaits)
    }
}

@Suite struct LevelTests {
    @Test func walksTheWholeRangeInSixteenSteps() {
        var value = DDC.Value(current: 0, maximum: 100)
        var visited = [0]
        while value.current < value.maximum {
            value.current = Level.stepped(value, up: true, fine: false)
            visited.append(value.current)
        }
        #expect(visited == [0, 6, 13, 19, 25, 31, 38, 44, 50, 56, 63, 69, 75, 81, 88, 94, 100])

        var downward: [Int] = [100]
        while value.current > 0 {
            value.current = Level.stepped(value, up: false, fine: false)
            downward.append(value.current)
        }
        #expect(downward == visited.reversed())
    }

    @Test func snapsOffGridValuesToTheNextGridPoint() {
        #expect(Level.stepped(DDC.Value(current: 10, maximum: 100), up: true, fine: false) == 13)
        #expect(Level.stepped(DDC.Value(current: 10, maximum: 100), up: false, fine: false) == 6)
    }

    @Test func fineStepsAreAQuarterOfCoarseSteps() {
        var value = DDC.Value(current: 50, maximum: 100)
        for _ in 0..<4 { value.current = Level.stepped(value, up: true, fine: true) }
        #expect(value.current == 56)
    }

    @Test func staysInRangeAndNeverStalls() {
        #expect(Level.stepped(DDC.Value(current: 100, maximum: 100), up: true, fine: false) == 100)
        #expect(Level.stepped(DDC.Value(current: 0, maximum: 100), up: false, fine: false) == 0)
        for maximum in [1, 5, 10, 15, 255] {
            var value = DDC.Value(current: 0, maximum: maximum)
            var steps = 0
            while value.current < maximum, steps <= maximum {
                let next = Level.stepped(value, up: true, fine: false)
                #expect(next > value.current)
                value.current = next
                steps += 1
            }
            #expect(value.current == maximum)
        }
    }

    @Test func everyStepFillsAWholeNumberOfSegments() {
        var value = DDC.Value(current: 0, maximum: 100)
        for step in 0...Level.coarseSteps {
            #expect(Level.barPosition(value) == Double(step) / Double(Level.coarseSteps))
            value.current = Level.stepped(value, up: true, fine: false)
        }
    }

    @Test func quarterStepsFillQuarterSegments() {
        var value = DDC.Value(current: 50, maximum: 100)
        for quarter in 0...4 {
            #expect(Level.barPosition(value) == (32.0 + Double(quarter)) / 64)
            value.current = Level.stepped(value, up: true, fine: true)
        }
    }

    @Test func aValueBetweenStepsKeepsItsTruePosition() {
        #expect(Level.barPosition(DDC.Value(current: 57, maximum: 100)) == 0.57)
        #expect(Level.barPosition(DDC.Value(current: 7, maximum: 0)) == 0)
    }

    @Test func worksOnRangesOtherThanAHundred() {
        var value = DDC.Value(current: 0, maximum: 255)
        for step in 0...Level.coarseSteps {
            #expect(Level.barPosition(value) == Double(step) / Double(Level.coarseSteps))
            value.current = Level.stepped(value, up: true, fine: false)
        }
    }

    @Test func convertsPercentages() {
        #expect(Level.value(percent: 50, maximum: 255) == 128)
        #expect(Level.value(percent: 140, maximum: 100) == 100)
    }
}

@Suite struct MediaKeyEventTests {
    @Test func decodesKeys() {
        #expect(MediaKeyEvent(subtype: 8, data1: 0x0000_0A00)?.key == .volumeUp)
        #expect(MediaKeyEvent(subtype: 8, data1: 0x0001_0A00)?.key == .volumeDown)
        #expect(MediaKeyEvent(subtype: 8, data1: 0x0002_0A00)?.key == .brightnessUp)
        #expect(MediaKeyEvent(subtype: 8, data1: 0x0003_0A00)?.key == .brightnessDown)
        #expect(MediaKeyEvent(subtype: 8, data1: 0x0007_0A00)?.key == .mute)
    }

    @Test func decodesStateAndRepeat() {
        let held = MediaKeyEvent(subtype: 8, data1: 0x0002_0A01)
        #expect(held?.isDown == true)
        #expect(held?.isRepeat == true)
        let released = MediaKeyEvent(subtype: 8, data1: 0x0002_0B00)
        #expect(released?.isDown == false)
        #expect(released?.isRepeat == false)
    }

    @Test func ignoresOtherEvents() {
        #expect(MediaKeyEvent(subtype: 7, data1: 0x0000_0A00) == nil)  // mouse buttons
        #expect(MediaKeyEvent(subtype: 8, data1: 0x0010_0A00) == nil)  // play/pause
    }
}

@Suite struct CommandTests {
    @Test func roundTripsThroughWords() {
        let commands: [Command] = [
            .step(.brightness, up: true, fine: false),
            .step(.volume, up: false, fine: true),
            .set(.brightness, percent: 40),
            .mute(.toggle), .mute(.on), .mute(.off),
        ]
        for command in commands {
            #expect(Command(words: command.words) == command)
        }
        #expect(Command(words: ["mute"]) == .mute(.toggle))
    }

    @Test func rejectsInvalidWords() {
        #expect(Command(words: []) == nil)
        #expect(Command(words: ["step", "contrast", "up"]) == nil)
        #expect(Command(words: ["step", "volume", "sideways"]) == nil)
        #expect(Command(words: ["set", "volume", "101"]) == nil)
        #expect(Command(words: ["set", "volume"]) == nil)
    }
}

@Suite struct DisplayStateTests {
    private func state(
        volume: Int = 13, mute: DDC.Value? = DDC.Value(current: DDC.Mute.off, maximum: 2)
    ) -> DisplayState {
        DisplayState(
            brightness: DDC.Value(current: 50, maximum: 100),
            volume: DDC.Value(current: volume, maximum: 100),
            mute: mute
        )
    }

    @Test func stepsBrightness() {
        var state = state()
        let outcome = state.apply(.step(.brightness, up: true, fine: false))
        #expect(outcome?.writes == [.init(.brightness, 56)])
        #expect(outcome?.feedback == Feedback(kind: .brightness, value: DDC.Value(current: 56, maximum: 100)))
        #expect(state.brightness?.current == 56)
    }

    @Test func togglesHardwareMute() {
        var state = state()
        #expect(state.apply(.mute(.toggle))?.writes == [.init(.mute, DDC.Mute.on)])
        #expect(state.isMuted)
        #expect(state.apply(.mute(.on))?.writes == [])
        #expect(state.apply(.mute(.toggle))?.writes == [.init(.mute, DDC.Mute.off)])
    }

    @Test func changingVolumeUnmutes() {
        var state = state(mute: DDC.Value(current: DDC.Mute.on, maximum: 2))
        #expect(state.isMuted)
        let outcome = state.apply(.step(.volume, up: true, fine: false))
        #expect(outcome?.writes == [.init(.mute, DDC.Mute.off), .init(.volume, 19)])
        #expect(outcome?.feedback.kind == .volume)
        #expect(!state.isMuted)
    }

    @Test func emulatesMuteWithoutHardwareSupport() {
        var state = state(mute: nil)
        let muted = state.apply(.mute(.toggle))
        #expect(muted?.writes == [.init(.volume, 0)])
        #expect(muted?.feedback == Feedback(kind: .muted, value: DDC.Value(current: 13, maximum: 100)))
        #expect(state.apply(.mute(.toggle))?.writes == [.init(.volume, 13)])
    }

    @Test func reportsMissingControls() {
        var state = DisplayState(brightness: DDC.Value(current: 50, maximum: 100), volume: nil, mute: nil)
        #expect(state.apply(.step(.volume, up: true, fine: false)) == nil)
        #expect(state.apply(.mute(.toggle)) == nil)
        #expect(state.isControllable)
        #expect(!DisplayState(brightness: nil, volume: nil, mute: nil).isControllable)
    }
}

@Suite struct ShortcutTests {
    @Test func parsesShortcuts() {
        let shortcut = Shortcut("Ctrl+Alt+Up")
        #expect(shortcut?.keyCode == 0x7E)
        #expect(shortcut?.modifiers == [.control, .option])
        #expect(Shortcut("f15")?.modifiers == [])
        #expect(Shortcut("f15")?.keyCode == 0x71)
    }

    @Test func rejectsInvalidShortcuts() {
        #expect(Shortcut("ctrl+alt") == nil)
        #expect(Shortcut("ctrl+up+down") == nil)
        #expect(Shortcut("hyper+up") == nil)
        #expect(Shortcut("") == nil)
    }

    @Test func everyActionHasADistinctUsableDefault() {
        let defaults = Shortcut.Action.allCases.compactMap(\.defaultShortcut)
        #expect(defaults.count == Shortcut.Action.allCases.count)
        #expect(Set(defaults).count == defaults.count)
        for text in defaults { #expect(Shortcut(text)?.isUsable == true) }
    }

    @Test func writesItselfAsTextAndSymbols() {
        #expect(Shortcut("Alt+Ctrl+Up")?.text == "ctrl+alt+up")
        #expect(Shortcut("ctrl+alt+up")?.symbols == "⌃⌥↑")
        #expect(Shortcut("cmd+shift+f5")?.symbols == "⇧⌘F5")
        #expect(Shortcut("ctrl+alt+end")?.symbols == "⌃⌥↘")
        for text in ["ctrl+alt+shift+cmd+pagedown", "f15", "shift+home"] {
            #expect(Shortcut(text)?.text == text)
        }
    }

    @Test func isBuiltFromAKeyPress() {
        #expect(Shortcut(keyCode: 0x7E, modifiers: [.control, .option])?.text == "ctrl+alt+up")
        #expect(Shortcut(keyCode: 0x00, modifiers: [.control]) == nil)  // the A key
        #expect(Shortcut.keyName(for: 0x67) == "f11")
        #expect(Shortcut.keyName(for: 0x00) == nil)
    }

    @Test func aBareArrowIsNotUsableButABareFunctionKeyIs() {
        #expect(Shortcut("up")?.isUsable == false)
        #expect(Shortcut("pagedown")?.isUsable == false)
        #expect(Shortcut("shift+up")?.isUsable == true)
        #expect(Shortcut("f15")?.isUsable == true)
    }
}

@Suite struct KeyRoutingTests {
    private func key(_ code: Int, down: Bool = true, isRepeat: Bool = false) -> MediaKeyEvent {
        MediaKeyEvent(subtype: 8, data1: code << 16 | (down ? 0xA : 0xB) << 8 | (isRepeat ? 1 : 0))!
    }

    private func context(
        brightness: Bool = true, volume: Bool = true, soundGoesToDisplay: Bool = true, builtIn: Bool = false
    ) -> KeyRouting.Context {
        KeyRouting.Context(
            hasBrightness: brightness, hasVolume: volume, soundGoesToDisplay: soundGoesToDisplay,
            mainDisplayIsBuiltIn: builtIn
        )
    }

    @Test func runsCommandsForTheDisplaysKeys() {
        #expect(KeyRouting.decide(key(0), fine: false, in: context()) == .run(.step(.volume, up: true, fine: false)))
        #expect(KeyRouting.decide(key(1), fine: true, in: context()) == .run(.step(.volume, up: false, fine: true)))
        #expect(
            KeyRouting.decide(key(2), fine: false, in: context()) == .run(.step(.brightness, up: true, fine: false)))
        #expect(
            KeyRouting.decide(key(3), fine: false, in: context()) == .run(.step(.brightness, up: false, fine: false)))
        #expect(KeyRouting.decide(key(7), fine: false, in: context()) == .run(.mute(.toggle)))
    }

    @Test func holdingAKeyRepeatsStepsButNotMute() {
        #expect(
            KeyRouting.decide(key(0, isRepeat: true), fine: false, in: context())
                == .run(.step(.volume, up: true, fine: false)))
        #expect(KeyRouting.decide(key(7, isRepeat: true), fine: false, in: context()) == .swallow)
    }

    @Test func keyReleasesAreSwallowedWithTheirPresses() {
        #expect(KeyRouting.decide(key(0, down: false), fine: false, in: context()) == .swallow)
        #expect(
            KeyRouting.decide(key(0, down: false), fine: false, in: context(soundGoesToDisplay: false)) == .passThrough)
    }

    @Test func leavesVolumeKeysToTheSystemWhenSoundGoesElsewhere() {
        for code in [0, 1, 7] {
            #expect(KeyRouting.decide(key(code), fine: false, in: context(soundGoesToDisplay: false)) == .passThrough)
            #expect(KeyRouting.decide(key(code), fine: false, in: context(volume: false)) == .passThrough)
        }
        #expect(KeyRouting.decide(key(2), fine: false, in: context(soundGoesToDisplay: false)) != .passThrough)
    }

    @Test func leavesBrightnessKeysToTheSystemWhenItHandlesThem() {
        #expect(KeyRouting.decide(key(2), fine: false, in: context(builtIn: true)) == .passThrough)
        #expect(KeyRouting.decide(key(3), fine: false, in: context(brightness: false)) == .passThrough)
    }
}

@Suite struct CoalescingWriterTests {
    private final class Target: Sendable {}

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func record(_ entry: String) {
            lock.withLock { entries.append(entry) }
        }

        var sent: [String] {
            lock.withLock { entries }
        }
    }

    /// A writer whose first send blocks until `release` is signalled, like a slow display.
    private func blockedWriter(
        _ recorder: Recorder
    ) -> (
        writer: CoalescingWriter<Target, String>, queue: DispatchQueue, started: DispatchSemaphore,
        release: DispatchSemaphore
    ) {
        let queue = DispatchQueue(label: "CoalescingWriterTests")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = CoalescingWriter<Target, String>(queue: queue) { _, key, value in
            started.signal()
            release.wait()
            recorder.record("\(key)=\(value)")
        }
        return (writer, queue, started, release)
    }

    @Test func keepsOnlyTheNewestValuePerKey() {
        let recorder = Recorder()
        let (writer, queue, started, release) = blockedWriter(recorder)
        let target = Target()

        writer.submit(target, "brightness", 1)
        started.wait()
        for value in 2...50 { writer.submit(target, "brightness", value) }
        writer.submit(target, "volume", 7)
        writer.submit(target, "brightness", 51)
        for _ in 0..<3 { release.signal() }
        queue.sync {}

        #expect(recorder.sent == ["brightness=1", "brightness=51", "volume=7"])
    }

    @Test func keepsTargetsSeparate() {
        let recorder = Recorder()
        let (writer, queue, started, release) = blockedWriter(recorder)
        let first = Target()
        let second = Target()

        writer.submit(first, "brightness", 1)
        started.wait()
        writer.submit(first, "brightness", 2)
        writer.submit(second, "brightness", 3)
        for _ in 0..<3 { release.signal() }
        queue.sync {}

        #expect(recorder.sent == ["brightness=1", "brightness=2", "brightness=3"])
    }

    @Test func cancelDropsUnsentValues() {
        let recorder = Recorder()
        let (writer, queue, started, release) = blockedWriter(recorder)
        let target = Target()

        writer.submit(target, "brightness", 1)
        started.wait()
        writer.submit(target, "brightness", 2)
        writer.submit(target, "volume", 3)
        writer.cancelAll()
        release.signal()
        queue.sync {}
        #expect(recorder.sent == ["brightness=1"])

        // The writer keeps working after a cancel.
        writer.submit(target, "volume", 4)
        release.signal()
        queue.sync {}
        #expect(recorder.sent == ["brightness=1", "volume=4"])
    }
}

@Suite struct AccessPolicyTests {
    private func shouldAsk(granted: Bool = false, handled: String? = "old", disabled: Bool = false) -> Bool {
        AccessPolicy.shouldAskAtLaunch(
            isGranted: granted, handledBuild: handled, currentBuild: "new", askingIsDisabled: disabled)
    }

    @Test func asksOncePerBuildWhileAccessIsMissing() {
        #expect(shouldAsk(handled: nil))
        #expect(shouldAsk(handled: "old"))
        #expect(!shouldAsk(handled: "new"))
    }

    @Test func neverAsksWhenAccessIsGrantedOrAskingIsOff() {
        #expect(!shouldAsk(granted: true))
        #expect(!shouldAsk(disabled: true))
    }
}

@Suite struct CommandDetailTests {
    @Test func knowsItsControlAndWhatToReadFirst() {
        #expect(Command.step(.brightness, up: true, fine: false).featureToRead == .brightness)
        #expect(Command.set(.volume, percent: 40).featureToRead == .volume)
        #expect(Command.mute(.toggle).featureToRead == .mute)
        #expect(Command.mute(.toggle).control == .volume)
        #expect(Command.Control.volume.features == [.volume, .mute])
    }

    @Test func aStateReportsItsValuesByFeature() {
        let state = DisplayState(
            brightness: DDC.Value(current: 50, maximum: 100), volume: nil,
            mute: DDC.Value(current: DDC.Mute.on, maximum: 2))
        #expect(state.value(of: .brightness) == 50)
        #expect(state.value(of: .volume) == nil)
        #expect(state.value(of: .mute) == DDC.Mute.on)
    }
}

@Suite struct ShortcutCheckTests {
    private let others: [Shortcut.Action: Shortcut] = [
        .brightnessUp: Shortcut("ctrl+alt+up")!, .volumeUp: Shortcut("ctrl+alt+right")!,
        .mute: Shortcut("ctrl+alt+end")!,
    ]

    private func check(_ text: String?, for action: Shortcut.Action, quarterSteps: Bool = false) -> Shortcut.Rejection?
    {
        Shortcut.check(text.flatMap(Shortcut.init), for: action, others: others, quarterSteps: quarterSteps)
    }

    @Test func acceptsAFreeShortcut() {
        #expect(check("ctrl+alt+down", for: .brightnessDown) == nil)
        #expect(check("f15", for: .brightnessDown) == nil)
    }

    @Test func anActionMayKeepItsOwnShortcut() {
        #expect(check("ctrl+alt+up", for: .brightnessUp) == nil)
    }

    @Test func rejectsKeysThatCannotBeShortcuts() {
        #expect(check(nil, for: .mute) == .unsupportedKey)
        #expect(check("up", for: .mute) == .needsModifier)
    }

    @Test func rejectsAShortcutAnotherActionUses() {
        #expect(check("ctrl+alt+up", for: .volumeDown) == .usedBy(.brightnessUp))
    }

    @Test func quarterStepsAlsoClaimTheShiftVariant() {
        #expect(check("ctrl+alt+shift+up", for: .volumeDown) == nil)
        #expect(check("ctrl+alt+shift+up", for: .volumeDown, quarterSteps: true) == .usedBy(.brightnessUp))
        // Mute does not step, so it has no Shift variant.
        #expect(check("ctrl+alt+shift+end", for: .volumeDown, quarterSteps: true) == nil)
    }

    @Test func rejectsAShortcutMacOSUsesItself() {
        let system = [Shortcut("ctrl+up")!]
        func check(_ text: String) -> Shortcut.Rejection? {
            Shortcut.check(
                Shortcut(text), for: .volumeDown, others: others, quarterSteps: false,
                isUsedBySystem: system.contains)
        }
        #expect(check("ctrl+up") == .usedBySystem)
        #expect(check("ctrl+down") == nil)
        // A clash with another action is the more useful thing to say.
        #expect(
            Shortcut.check(
                Shortcut("ctrl+alt+up"), for: .volumeDown, others: others, quarterSteps: false,
                isUsedBySystem: { _ in true }) == .usedBy(.brightnessUp))
    }

    @Test func theQuarterStepVariantAddsShift() {
        #expect(Shortcut("ctrl+alt+up")?.quarterStepVariant == Shortcut("ctrl+alt+shift+up"))
        #expect(Shortcut("shift+f15")?.quarterStepVariant == nil)
    }
}

@Suite struct FeedbackTests {
    @Test func reportsAWholePercentage() {
        #expect(Feedback(kind: .brightness, fraction: 0.5625).percent == 56)
        // The bar snaps to the step; the percentage stays the display's own number.
        let stepped = Feedback(kind: .brightness, value: DDC.Value(current: 56, maximum: 100))
        #expect(stepped.percent == 56)
        #expect(stepped.barPosition == 9.0 / 16)
        #expect(Feedback(kind: .volume, fraction: 1.4).percent == 100)
        #expect(Feedback(kind: .volume, fraction: -1).percent == 0)
    }
}
