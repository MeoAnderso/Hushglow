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
        #expect(DDC.Feature(name: "contrast") == .contrast && DDC.Feature(name: "gamma") == nil)
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

    /// The key watch names every key of this kind, the ones the app does not act on too.
    @Test func namesEveryAuxiliaryKey() {
        let playPause = AuxiliaryKey(subtype: 8, data1: 0x0010_0A00)
        #expect(playPause?.name == "play/pause" && playPause?.isDown == true)
        #expect(AuxiliaryKey(subtype: 8, data1: 0x0007_0B00)?.name == "mute")
        #expect(AuxiliaryKey(subtype: 8, data1: 0x0063_0A01)?.name == "code 99")
        #expect(AuxiliaryKey(subtype: 7, data1: 0x0000_0A00) == nil)
        // Neither pressed nor released.
        #expect(AuxiliaryKey(subtype: 8, data1: 0x0000_0C00) == nil)
    }
}

@Suite struct CommandTests {
    @Test func roundTripsThroughWords() {
        let commands: [Command] = [
            .step(.brightness, up: true, fine: false),
            .step(.volume, up: false, fine: true),
            .set(.brightness, percent: 40),
            .mute(.toggle), .mute(.on), .mute(.off),
            .step(.contrast, up: true, fine: false), .set(.contrast, percent: 70), .input(.hdmi2), .input(.usbC),
        ]
        for command in commands {
            #expect(Command(words: command.words) == command)
        }
        #expect(Command(words: ["mute"]) == .mute(.toggle))
    }

    @Test func rejectsInvalidWords() {
        #expect(Command(words: []) == nil)
        #expect(Command(words: ["step", "input", "up"]) == nil)
        #expect(Command(words: ["set", "input", "50"]) == nil)
        #expect(Command(words: ["input", "vga"]) == nil)
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

    /// A step at either end of the range changes nothing, and says which end it was pushed
    /// against, for the indicator to show.
    @Test func aStepPastEitherEndSaysWhichEndItMet() {
        var state = state(volume: 100)
        #expect(state.apply(.step(.brightness, up: true, fine: false))?.feedback.pushedAgainst == nil)
        let top = state.apply(.step(.volume, up: true, fine: false))
        #expect(top?.writes == [] && top?.feedback.pushedAgainst == .top)
        #expect(state.apply(.step(.volume, up: false, fine: true))?.feedback.pushedAgainst == nil)

        var low = self.state(volume: 0)
        #expect(low.apply(.step(.volume, up: false, fine: false))?.feedback.pushedAgainst == .bottom)
        #expect(low.apply(.step(.volume, up: true, fine: false))?.feedback.pushedAgainst == nil)

        // At the top but muted, a step up unmutes, which is something.
        var muted = self.state(volume: 100, mute: DDC.Value(current: DDC.Mute.on, maximum: 2))
        let unmuted = muted.apply(.step(.volume, up: true, fine: false))
        #expect(unmuted?.writes == [.init(.mute, DDC.Mute.off)] && unmuted?.feedback.pushedAgainst == nil)
        // A value set outright is never a push, even when it is already there.
        #expect(muted.apply(.set(.volume, percent: 100))?.feedback.pushedAgainst == nil)
    }

    /// Below the display's lowest brightness a step down dims the screen, to the most dimming
    /// allowed, and only then is pushed against the end; a step up takes the dimming off first,
    /// and a brightness set outright takes it off.
    @Test func dimsBelowTheLowestBrightness() {
        var state = DisplayState(brightness: DDC.Value(current: 6, maximum: 100), volume: nil, mute: nil)
        let down = Command.step(.brightness, up: false, fine: false)
        #expect(state.apply(down, maximumDimming: 2)?.writes == [.init(.brightness, 0)])
        let first = state.apply(down, maximumDimming: 2)
        #expect(first?.writes == [] && first?.feedback.dimming == 1 && first?.feedback.pushedAgainst == nil)
        #expect(state.apply(down, maximumDimming: 2)?.feedback.dimming == 2)
        let deepest = state.apply(down, maximumDimming: 2)
        #expect(deepest?.feedback.dimming == 2 && deepest?.feedback.pushedAgainst == .bottom)
        #expect(Indication.level(deepest!.feedback).spoken == "Brightness 0 percent, dimmed 20 percent")

        let up = Command.step(.brightness, up: true, fine: false)
        #expect(state.apply(up, maximumDimming: 2)?.writes == [] && state.dimming == 1)
        #expect(state.apply(up, maximumDimming: 2)?.writes == [] && state.dimming == 0)
        #expect(state.apply(up, maximumDimming: 2)?.writes == [.init(.brightness, 6)])

        state.dimming = 2
        #expect(state.apply(.set(.brightness, percent: 30), maximumDimming: 2)?.writes == [.init(.brightness, 30)])
        #expect(state.dimming == 0)

        // With dimming off, the lowest brightness is the end, as before.
        var plain = DisplayState(brightness: DDC.Value(current: 0, maximum: 100), volume: nil, mute: nil)
        #expect(plain.apply(down)?.feedback.pushedAgainst == .bottom && plain.dimming == 0)
    }

    @Test func contrastStepsAndIsSetLikeBrightness() {
        var state = DisplayState(
            brightness: DDC.Value(current: 50, maximum: 100), volume: nil, mute: nil,
            contrast: DDC.Value(current: 70, maximum: 100))
        #expect(state.has(.contrast) && !state.has(.volume) && !state.has(.input))
        let up = state.apply(.step(.contrast, up: true, fine: false))
        #expect(up?.writes == [.init(.contrast, 75)] && up?.feedback.kind == .contrast)
        #expect(state.apply(.set(.contrast, percent: 40))?.writes == [.init(.contrast, 40)])
        #expect(state.reconcile(.contrast, with: DDC.Value(current: 45, maximum: 100)) == 40)
        #expect(state.contrast?.current == 45)
        // Without contrast, nothing to do.
        var plain = DisplayState(brightness: DDC.Value(current: 50, maximum: 100), volume: nil, mute: nil)
        #expect(plain.apply(.step(.contrast, up: true, fine: false)) == nil)
    }

    /// Switching inputs writes the input's number, unless the display shows it already; the
    /// number some displays report has other bits beside it.
    @Test func switchesInputs() {
        var state = DisplayState(
            brightness: DDC.Value(current: 50, maximum: 100), volume: nil, mute: nil,
            input: DDC.Value(current: 0x0F, maximum: 0x1B))
        #expect(state.has(.input))
        #expect(state.apply(.input(.displayPort1))?.writes == [])
        let hdmi = state.apply(.input(.hdmi1))
        #expect(hdmi?.writes == [.init(.input, 0x11)] && hdmi?.feedback.kind == .input)
        #expect(state.input == 0x11)
        #expect(state.reconcile(.input, with: DDC.Value(current: 0x0111, maximum: 0x1B)) == nil)
        #expect(state.reconcile(.input, with: DDC.Value(current: 0x0F, maximum: 0x1B)) == 0x0111)
        #expect(DDC.Input(reported: 0x0112) == .hdmi2 && DDC.Input(reported: 0x05) == nil)
        // Inputs are not levels.
        #expect(state.apply(.step(.input, up: true, fine: false)) == nil)
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

    /// For when the cache may be out of date: nothing is left unwritten on its word.
    @Test func anAbsoluteCommandCanBeAppliedWithoutTrustingTheCache() {
        var state = state()
        #expect(state.apply(.set(.brightness, percent: 50))?.writes == [])
        #expect(state.apply(.set(.brightness, percent: 50), trustingCache: false)?.writes == [.init(.brightness, 50)])
        // Setting the volume unmutes, and the display may be muted without the cache knowing.
        #expect(
            state.apply(.set(.volume, percent: 13), trustingCache: false)?.writes == [
                .init(.mute, DDC.Mute.off), .init(.volume, 13),
            ])
        #expect(state.apply(.mute(.off), trustingCache: false)?.writes == [.init(.mute, DDC.Mute.off)])
        #expect(state.apply(.mute(.on), trustingCache: false)?.writes == [.init(.mute, DDC.Mute.on)])
        #expect(state.apply(.mute(.on), trustingCache: false)?.writes == [.init(.mute, DDC.Mute.on)])
        #expect(state.isMuted)
    }

    /// A step and a toggle start from the cached value, so they are worked out as ever.
    @Test func aRelativeCommandIsNeverRewritten() {
        var state = state(volume: 100)
        #expect(state.apply(.step(.volume, up: true, fine: false), trustingCache: false)?.writes == [])
        #expect(state.apply(.mute(.toggle), trustingCache: false)?.writes == [.init(.mute, DDC.Mute.on)])
    }

    /// An emulated mute exists in the cache alone, so there the cache is right at any age.
    @Test func anEmulatedMuteIsKnownWhateverTheDisplayHolds() {
        var state = state(mute: nil)
        // Unmuting what is not muted must not put the remembered volume over the display's.
        #expect(state.apply(.mute(.off), trustingCache: false)?.writes == [])
        #expect(state.apply(.mute(.on), trustingCache: false)?.writes == [.init(.volume, 0)])
        #expect(state.apply(.mute(.on), trustingCache: false)?.writes == [])
        #expect(state.apply(.set(.volume, percent: 13), trustingCache: false)?.writes == [.init(.volume, 13)])
        #expect(!state.isMuted)
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

    @Test func everyActionHasADistinctUsableDefaultInEachSet() {
        for set in Shortcut.DefaultSet.allCases {
            let defaults = Shortcut.Action.allCases.compactMap(set.shortcut)
            #expect(defaults.count == Shortcut.Action.allCases.count)
            #expect(Set(defaults.map(\.text)).count == defaults.count)
            #expect(defaults.allSatisfy { $0.isUsable })
            // Quarter steps with Cmd, the default modifier, clash with none of them.
            let shortcuts = Dictionary(uniqueKeysWithValues: zip(Shortcut.Action.allCases, defaults))
            #expect(Shortcut.firstClash(among: shortcuts, quarterStep: .command) == nil)
        }
        #expect(Shortcut.DefaultSet.arrows.text(for: .brightnessUp) == "ctrl+alt+up")
        #expect(Shortcut.DefaultSet.arrows.text(for: .mute) == "ctrl+alt+end")
        // Where Apple's keyboards have these functions.
        let functionKeys = Shortcut.Action.allCases.map(Shortcut.DefaultSet.functionKeys.text)
        #expect(functionKeys == ["ctrl+alt+f2", "ctrl+alt+f1", "ctrl+alt+f12", "ctrl+alt+f11", "ctrl+alt+f10"])
    }

    @Test func writesItselfAsTextAndSymbols() {
        #expect(Shortcut("Alt+Ctrl+Up")?.text == "ctrl+alt+up")
        #expect(Shortcut("ctrl+alt+up")?.symbols == "⌃⌥↑")
        #expect(Shortcut("cmd+shift+f5")?.symbols == "⇧⌘F5")
        // Home, End and the page keys are written as words; few people know their symbols.
        #expect(Shortcut("ctrl+alt+end")?.symbols == "⌃⌥End")
        #expect(Shortcut("ctrl+pageup")?.symbols == "⌃Page Up")
        #expect(Shortcut("shift+home")?.symbols == "⇧Home")
        #expect(Shortcut.Modifiers([.command, .control, .option]).symbols == "⌃⌥⌘")
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

    @Test func whatSendingAValueLeavesBehindGoesBeforeTheNext() {
        final class Leftover: Sendable {}
        final class Watch: @unchecked Sendable {
            weak var last: Leftover?
            var outlived = 0
        }
        let watch = Watch()
        let queue = DispatchQueue(label: "CoalescingWriterTests")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = CoalescingWriter<Target, String>(queue: queue) { _, _, value in
            if value == 1 {
                started.signal()
                release.wait()
            }
            if watch.last != nil { watch.outlived += 1 }
            let leftover = Leftover()
            watch.last = leftover
            _ = Unmanaged.passRetained(leftover).autorelease()
        }
        let target = Target()

        writer.submit(target, "first", 1)
        started.wait()
        // These wait together and are sent in the one run that the first value began.
        for key in ["second", "third", "fourth"] { writer.submit(target, key, 2) }
        release.signal()
        queue.sync {}
        #expect(watch.outlived == 0)
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
            isGranted: granted, handledSignature: handled, currentSignature: "new", askingIsDisabled: disabled)
    }

    /// An ad-hoc build is a signature of its own, so this is once per build; with a
    /// certificate, once per certificate.
    @Test func asksOncePerSignatureWhileAccessIsMissing() {
        #expect(shouldAsk(handled: nil))
        #expect(shouldAsk(handled: "old"))
        #expect(!shouldAsk(handled: "new"))
    }

    @Test func neverAsksWhenAccessIsGrantedOrAskingIsOff() {
        #expect(!shouldAsk(granted: true))
        #expect(!shouldAsk(disabled: true))
    }

    @Test func clearsOnlyAnEntryThatCanBeStale() {
        // Ad-hoc: any entry may be an earlier build's, which macOS ignores.
        func clears(adHoc: Bool, granted: String?) -> Bool {
            AccessPolicy.clearsEntryBeforeAsking(isAdHoc: adHoc, grantedSignature: granted, currentSignature: "cert")
        }
        #expect(clears(adHoc: true, granted: "cert"))
        // A certificate that was never seen with access, or another one: the entry can be stale.
        #expect(clears(adHoc: false, granted: nil))
        #expect(clears(adHoc: false, granted: "old"))
        // Access was had under this certificate: the entry is the user's, switched off or gone.
        #expect(!clears(adHoc: false, granted: "cert"))
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

    @Test func knowsWhetherItDependsOnWhatTheDisplayHolds() {
        #expect(Command.set(.brightness, percent: 40).isAbsolute && Command.set(.volume, percent: 0).isAbsolute)
        #expect(Command.mute(.on).isAbsolute && Command.mute(.off).isAbsolute)
        #expect(!Command.mute(.toggle).isAbsolute)
        #expect(!Command.step(.volume, up: false, fine: true).isAbsolute)
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

    private func check(
        _ text: String?, for action: Shortcut.Action, quarterStep: Shortcut.Modifiers? = nil
    ) -> Shortcut.Rejection? {
        Shortcut.check(text.flatMap(Shortcut.init), for: action, others: others, quarterStep: quarterStep)
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

    @Test func quarterStepsAlsoClaimTheKeysWithTheirModifier() {
        #expect(check("ctrl+alt+cmd+up", for: .volumeDown) == nil)
        #expect(check("ctrl+alt+cmd+up", for: .volumeDown, quarterStep: .command) == .usedBy(.brightnessUp))
        // With another modifier, other keys.
        #expect(check("ctrl+alt+cmd+up", for: .volumeDown, quarterStep: .shift) == nil)
        #expect(check("ctrl+alt+shift+up", for: .volumeDown, quarterStep: .shift) == .usedBy(.brightnessUp))
        // Mute does not step, so it has no quarter step.
        #expect(check("ctrl+alt+cmd+end", for: .volumeDown, quarterStep: .command) == nil)
        // A shortcut's own quarter step may not be another's shortcut either.
        #expect(check("ctrl+alt+down", for: .volumeDown, quarterStep: .command) == nil)
        #expect(check("ctrl+left", for: .volumeDown, quarterStep: .option) == nil)
        #expect(check("ctrl+right", for: .volumeDown, quarterStep: .option) == .usedBy(.volumeUp))
    }

    @Test func rejectsAShortcutMacOSUsesItself() {
        let system = [Shortcut("ctrl+up")!]
        func check(_ text: String) -> Shortcut.Rejection? {
            Shortcut.check(
                Shortcut(text), for: .volumeDown, others: others, quarterStep: nil, isUsedBySystem: system.contains)
        }
        #expect(check("ctrl+up") == .usedBySystem)
        #expect(check("ctrl+down") == nil)
        // A clash with another action is the more useful thing to say.
        #expect(
            Shortcut.check(
                Shortcut("ctrl+alt+up"), for: .volumeDown, others: others, quarterStep: nil,
                isUsedBySystem: { _ in true }) == .usedBy(.brightnessUp))
    }

    @Test func aQuarterStepAddsItsModifier() {
        #expect(Shortcut("ctrl+alt+up")?.adding(.command) == Shortcut("ctrl+alt+cmd+up"))
        #expect(Shortcut("ctrl+alt+up")?.adding(.shift) == Shortcut("ctrl+alt+shift+up"))
        #expect(Shortcut("shift+f15")?.adding(.shift) == nil)
        #expect(Shortcut("ctrl+alt+up")?.adding(.option) == nil)
    }

    @Test func aShortcutClaimsItsQuarterStepOnlyWhenThoseAreOn() throws {
        let up = try #require(Shortcut("ctrl+alt+up"))
        let quarter = try #require(Shortcut("ctrl+alt+cmd+up"))
        #expect(up.claimed(for: .brightnessUp, quarterStep: nil) == [up])
        #expect(up.claimed(for: .brightnessUp, quarterStep: .command) == [up, quarter])
        // Mute does not step, and a shortcut that has the modifier already has no quarter step.
        #expect(up.claimed(for: .mute, quarterStep: .command) == [up])
        #expect(quarter.claimed(for: .volumeUp, quarterStep: .command) == [quarter])
    }

    /// Turning quarter steps on, or choosing their modifier, is checked before it is made.
    @Test func findsTwoActionsThatQuarterStepsWouldMakeClash() throws {
        var shortcuts = others
        #expect(Shortcut.firstClash(among: shortcuts, quarterStep: .command) == nil)
        shortcuts[.volumeDown] = Shortcut("ctrl+alt+cmd+up")
        #expect(Shortcut.firstClash(among: shortcuts, quarterStep: nil) == nil)
        let clash = try #require(Shortcut.firstClash(among: shortcuts, quarterStep: .command))
        #expect(
            clash.action == .brightnessUp && clash.other == .volumeDown && clash.keys == Shortcut("ctrl+alt+cmd+up"))
        #expect(Shortcut.firstClash(among: shortcuts, quarterStep: .shift) == nil)
    }

    @Test func modifiersHaveNamesForSettingsAndForPeople() {
        #expect(Shortcut.Modifiers(name: "cmd") == .command && Shortcut.Modifiers(name: "Option") == .option)
        #expect(Shortcut.Modifiers(name: "hyper") == nil)
        #expect(Shortcut.Modifiers.quarterStepChoices.map(\.name) == ["cmd", "shift", "alt", "ctrl"])
        #expect(Shortcut.Modifiers.quarterStepChoices.map(\.title) == ["Cmd", "Shift", "Alt", "Ctrl"])
        #expect(Shortcut.Modifiers([.command, .shift]).name == nil)
        // Cmd is the default: with the default shortcuts, macOS uses Ctrl+Alt+Shift+arrows itself.
        #expect(Shortcut.Modifiers.quarterStepChoices.first == .command)
    }
}

@Suite struct IndicationTests {
    /// The indicator and VoiceOver take their words from the one place.
    @Test func hasAMessageForEverythingButALevel() {
        #expect(Indication.level(Feedback(kind: .brightness, fraction: 0.5)).message == nil)
        #expect(Indication.refused(.brightness).message == "Brightness is locked")
        #expect(Indication.unsupported(.volume).message == "No volume control")
        #expect(Indication.noDisplay.message == "No display to control")
        #expect(Indication.watchingKeys.message == "Watching special keys")
    }

    @Test func describesItselfForVoiceOver() {
        #expect(Indication.level(Feedback(kind: .brightness, fraction: 0.5625)).spoken == "Brightness 56 percent")
        #expect(Indication.level(Feedback(kind: .volume, fraction: 0.3)).spoken == "Volume 30 percent")
        #expect(Indication.level(Feedback(kind: .muted, fraction: 0.3)).spoken == "Muted")
        for indication in [Indication.refused(.volume), .unsupported(.brightness), .noDisplay, .watchingKeys] {
            #expect(indication.spoken == indication.message)
        }
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
