import Foundation
import Testing

@testable import DisplayKeysCore

/// A display that records what it is asked, and can be changed behind the app's back.
private final class FakeTransport: DisplayTransport, @unchecked Sendable {
    final class Handle: Sendable {}

    private let lock = NSLock()
    let handle = Handle()
    private var values: [DDC.Feature: Int] = [.brightness: 50, .volume: 13, .mute: DDC.Mute.off]
    /// A second display that answers, with values of its own; its requests are written down
    /// with "2: " in front.
    private(set) var second: Handle?
    private var secondValues: [DDC.Feature: Int] = [.brightness: 30]
    private var events: [String] = []
    /// What the display does with a written value; nil means it ignores writes.
    private var onWrite: ((Int) -> Int)? = { $0 }
    private var dropsRemaining = 0
    private var unanswered: Set<DDC.Feature> = []
    /// Further external displays that never answer, as one without DDC does.
    private var silent: [Handle] = []
    private var discoveryCount = 0

    func displays() -> [Handle] {
        lock.withLock {
            discoveryCount += 1
            return [handle] + (second.map { [$0] } ?? []) + silent
        }
    }

    func get(_ display: Handle, _ feature: DDC.Feature) -> DDC.Value? {
        lock.withLock {
            if display === second {
                events.append("2: get \(feature)")
                return secondValues[feature].map { DDC.Value(current: $0, maximum: 100) }
            }
            guard display === handle else { return nil }
            events.append("get \(feature)")
            return unanswered.contains(feature) ? nil : values[feature].map { DDC.Value(current: $0, maximum: 100) }
        }
    }

    func set(_ display: Handle, _ feature: DDC.Feature, value: Int) -> Bool {
        lock.withLock {
            if display === second {
                events.append("2: set \(feature)=\(value)")
                secondValues[feature] = value
                return true
            }
            events.append("set \(feature)=\(value)")
            if dropsRemaining > 0 {
                dropsRemaining -= 1
            } else if let onWrite {
                values[feature] = onWrite(value)
            }
            return true
        }
    }

    func change(_ feature: DDC.Feature, to value: Int) {
        lock.withLock { values[feature] = value }
    }

    func ignoreWrites() {
        lock.withLock { onWrite = nil }
    }

    /// Makes the display stop answering reads of a feature, or answer them again.
    func answer(_ feature: DDC.Feature, _ answers: Bool) {
        lock.withLock { _ = answers ? unanswered.remove(feature) : unanswered.insert(feature).memberAfterInsert }
    }

    /// Adds a second display that answers, with brightness and no volume.
    func addSecondDisplay() {
        lock.withLock { second = Handle() }
    }

    func secondValue(_ feature: DDC.Feature) -> Int? {
        lock.withLock { secondValues[feature] }
    }

    func addDisplayWithoutDDC() {
        lock.withLock { silent.append(Handle()) }
    }

    /// How often the displays have been looked for.
    var discoveries: Int {
        lock.withLock { discoveryCount }
    }

    /// Makes the display lose the next write and take the ones after it.
    func dropNextWrite() {
        lock.withLock { dropsRemaining = 1 }
    }

    /// Makes the display settle one unit below whatever is written.
    func adjustWrites() {
        lock.withLock { onWrite = { $0 - 1 } }
    }

    func value(_ feature: DDC.Feature) -> Int? {
        lock.withLock { values[feature] }
    }

    /// The requests made since the last call.
    func takeEvents() -> [String] {
        lock.withLock {
            defer { events = [] }
            return events
        }
    }
}

@MainActor
private final class Recorder {
    var fractions: [Double?] = []
    var finals: [Bool] = []
    var mismatches: [DisplayMismatch] = []
    var readings: [[DDC.Value]] = []
    var now = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
@Suite struct DisplaysTests {
    private let transport = FakeTransport()
    private let queue = DispatchQueue(label: "DisplaysTests")
    private let recorder = Recorder()
    private let displays: Displays<FakeTransport>

    init() async {
        var timing = Displays<FakeTransport>.Timing()
        timing.verifyDelay = 0
        let recorder = recorder
        displays = Displays(
            transport: transport, queue: queue, timing: timing, now: { recorder.now }, onWriteFailure: {})
        displays.onMismatch = { recorder.mismatches.append($0) }
        displays.refresh()
        await settle()
        _ = transport.takeEvents()
    }

    /// Lets the display queue and the main queue finish the work they have handed each other.
    private func settle() async {
        for _ in 0..<8 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
        }
    }

    /// Waits for something that takes a few turns between the queues, such as a retry.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func press(_ command: Command) {
        let recorder = recorder
        displays.apply(command) { feedback, isFinal in
            recorder.fractions.append(feedback?.fraction)
            recorder.finals.append(isFinal)
        }
    }

    /// Lets the cache go stale, as after a pause between bursts of key presses.
    private func pause() {
        recorder.now += 6
    }

    private let brightnessUp = Command.step(.brightness, up: true, fine: false)

    @Test func readsTheDisplayOnDiscovery() {
        #expect(displays.primary?.brightness == DDC.Value(current: 50, maximum: 100))
        #expect(displays.primary?.volume == DDC.Value(current: 13, maximum: 100))
        #expect(displays.hasBrightness && displays.hasVolume)
    }

    @Test func aFreshCacheIsWrittenWithoutReadingFirst() async {
        press(brightnessUp)
        #expect(recorder.fractions == [0.56])
        #expect(recorder.finals == [true])
        await settle()
        // The write goes out first; the read is the read-back that follows a burst.
        #expect(transport.takeEvents() == ["set brightness=56", "get brightness"])
        #expect(recorder.mismatches.isEmpty)
    }

    @Test func aStaleCacheIsReadBeforeWriting() async {
        pause()
        transport.change(.brightness, to: 80)

        press(brightnessUp)
        #expect(recorder.fractions == [0.56])  // expected result, shown at once
        #expect(recorder.finals == [false])
        await settle()
        #expect(recorder.fractions == [0.56, 0.81])  // real result, after reading the display
        #expect(recorder.finals == [false, true])
        #expect(transport.takeEvents() == ["get brightness", "set brightness=81", "get brightness"])
        #expect(displays.primary?.brightness?.current == 81)
        #expect(recorder.mismatches == [.init(feature: .brightness, cached: 50, actual: 80, kind: .changedOutside)])
    }

    @Test func pressesDuringTheReadAreReplayedInOrder() async {
        pause()
        transport.change(.brightness, to: 80)

        for _ in 0..<3 { press(brightnessUp) }
        #expect(recorder.fractions == [0.56, 0.63, 0.69])
        await settle()
        #expect(Array(recorder.fractions.suffix(3)) == [0.81, 0.88, 0.94])
        #expect(transport.value(.brightness) == 94)
    }

    @Test func aVolumeStepReadsOnlyTheVolumeFirst() async {
        pause()
        press(.step(.volume, up: true, fine: false))
        await settle()
        // One read before the write keeps the first press quick; the read-back covers mute too.
        #expect(transport.takeEvents() == ["get volume", "set volume=19", "get volume", "get mute"])
    }

    @Test func aMuteToggleReadsTheMuteStateFirst() async {
        pause()
        transport.change(.mute, to: DDC.Mute.on)
        press(.mute(.toggle))
        await settle()
        #expect(Array(transport.takeEvents().prefix(2)) == ["get mute", "set mute=\(DDC.Mute.off)"])
        #expect(displays.primary?.isMuted == false)
    }

    // MARK: Commands that say what the display is to hold

    @Test func anAbsoluteCommandIsWrittenToAStaleCacheWithoutReadingFirst() async {
        pause()
        transport.change(.brightness, to: 80)
        press(.set(.brightness, percent: 30))
        // The result does not depend on what the display holds, so it is final at once.
        #expect(recorder.fractions == [0.3])
        #expect(recorder.finals == [true])
        await settle()
        #expect(transport.takeEvents() == ["set brightness=30", "get brightness"])
        #expect(recorder.mismatches.isEmpty)
    }

    /// The cache may hold the very value that is asked for while the display holds another.
    @Test func aStaleCacheDoesNotKeepAnAbsoluteCommandFromBeingWritten() async {
        // While the cache is fresh it is believed: the display has 50 already.
        press(.set(.brightness, percent: 50))
        await settle()
        #expect(transport.takeEvents().isEmpty)

        pause()
        transport.change(.brightness, to: 80)
        press(.set(.brightness, percent: 50))
        await settle()
        #expect(transport.takeEvents() == ["set brightness=50", "get brightness"])
        #expect(transport.value(.brightness) == 50)
    }

    /// Setting the volume unmutes, and the display may have been muted with its own buttons
    /// since it was last heard from.
    @Test func settingTheVolumeOnAStaleCacheUnmutesWhateverTheCacheSays() async {
        pause()
        transport.change(.mute, to: DDC.Mute.on)
        press(.set(.volume, percent: 40))
        #expect(recorder.finals == [true])
        await settle()
        #expect(
            transport.takeEvents() == ["set mute=\(DDC.Mute.off)", "set volume=40", "get volume", "get mute"])
        #expect(transport.value(.mute) == DDC.Mute.off)
        #expect(displays.primary?.isMuted == false)
        #expect(recorder.mismatches.isEmpty)
    }

    @Test func mutingAndUnmutingAStaleCacheIsWrittenWithoutReadingFirst() async {
        pause()
        transport.change(.mute, to: DDC.Mute.on)
        // The cache says the display is not muted. It is, and has to be told.
        press(.mute(.off))
        #expect(recorder.finals == [true])
        await settle()
        #expect(transport.takeEvents() == ["set mute=\(DDC.Mute.off)", "get volume", "get mute"])
        #expect(transport.value(.mute) == DDC.Mute.off)
    }

    /// A step that is still waiting for the display to be read was asked for first.
    @Test func anAbsoluteCommandTakesItsTurnBehindOnesThatAreBeingReadFor() async {
        pause()
        transport.change(.brightness, to: 80)
        press(brightnessUp)
        press(.set(.brightness, percent: 30))
        #expect(recorder.finals == [false, false])
        await settle()
        #expect(Array(recorder.fractions.suffix(2)) == [0.81, 0.3])
        #expect(transport.takeEvents().first == "get brightness")
        #expect(transport.value(.brightness) == 30)

        // One for another control has nothing to wait for.
        pause()
        press(brightnessUp)
        press(.set(.volume, percent: 40))
        #expect(Array(recorder.finals.suffix(2)) == [false, true])
        await settle()
        #expect(transport.value(.volume) == 40 && transport.value(.brightness) == 31)
    }

    // MARK: Reading the values again

    /// What the menu asks for when it opens: the values, and not a search for the displays.
    @Test func readingTheValuesAgainPicksUpWhatWasChangedOutside() async {
        let discoveries = transport.discoveries
        var changes = 0
        displays.onChange = { changes += 1 }
        transport.change(.brightness, to: 80)
        transport.change(.mute, to: DDC.Mute.on)

        displays.readValues()
        await settle()
        #expect(transport.takeEvents() == ["get brightness", "get volume", "get mute"])
        #expect(transport.discoveries == discoveries)
        #expect(displays.primary?.brightness?.current == 80)
        #expect(displays.primary?.isMuted == true)
        #expect(changes == 1)
        #expect(recorder.mismatches.map(\.kind) == [.changedOutside, .changedOutside])

        // What was read counts as heard from: the next step is written without another read.
        pause()
        displays.readValues()
        await settle()
        _ = transport.takeEvents()
        press(brightnessUp)
        await settle()
        #expect(transport.takeEvents().first == "set brightness=81")
        #expect(changes == 1)
    }

    @Test func readingTheValuesAgainLooksForTheDisplaysWhenNoneIsKnown() async {
        let empty = Displays(transport: transport, queue: queue, onWriteFailure: {})
        let discoveries = transport.discoveries
        empty.readValues()
        await settle()
        #expect(transport.discoveries == discoveries + 1)
        #expect(empty.primary?.brightness?.current == 50)
    }

    /// A display that answers nothing may have gone, or another may have taken its place.
    @Test func aDisplayThatAnswersNothingIsLookedForAgain() async {
        let discoveries = transport.discoveries
        // One that only lacks an answer for one value is still there.
        transport.answer(.volume, false)
        displays.readValues()
        await settle()
        #expect(transport.discoveries == discoveries)
        #expect(displays.primary != nil)

        for feature in DDC.Feature.allCases { transport.answer(feature, false) }
        displays.readValues()
        await settle()
        #expect(transport.discoveries == discoveries + 1)
        #expect(displays.primary == nil)
    }

    /// The menu can open while a key press is being read for. Both reads are answered, and
    /// what the second one read before the key's write went out does not undo the step.
    @Test func readingTheValuesAgainDuringAnotherReadLeavesTheStepInPlace() async {
        pause()
        press(brightnessUp)
        displays.readValues()
        await settle()
        #expect(recorder.fractions == [0.56, 0.56])
        #expect(displays.primary?.brightness?.current == 56)
        #expect(transport.value(.brightness) == 56)
        #expect(recorder.mismatches.isEmpty)
        #expect(transport.takeEvents().filter { $0.hasPrefix("set") } == ["set brightness=56"])
    }

    /// Opening the menu straight after a key press must not take the place of the read-back:
    /// a write the display lost would then be taken for a change made with its buttons.
    @Test func readingTheValuesAgainLeavesAFreshWriteToItsReadBack() async {
        transport.dropNextWrite()
        press(brightnessUp)
        displays.readValues()
        // The read-back stands back for the read that is under way, so it takes a moment longer.
        await settle { transport.value(.brightness) == 56 }
        await settle()
        #expect(transport.value(.brightness) == 56)
        #expect(displays.primary?.brightness?.current == 56)
        #expect(recorder.mismatches.isEmpty)
        // Only the control that was not written is read for the menu.
        #expect(Array(transport.takeEvents().prefix(3)) == ["set brightness=56", "get volume", "get mute"])
    }

    @Test func aDroppedWriteIsSentAgain() async {
        transport.dropNextWrite()
        press(brightnessUp)
        await settle()
        #expect(
            transport.takeEvents() == ["set brightness=56", "get brightness", "set brightness=56", "get brightness"])
        #expect(transport.value(.brightness) == 56)
        #expect(displays.primary?.brightness?.current == 56)
        #expect(recorder.mismatches.isEmpty)
    }

    @Test func aWriteTheDisplayRefusedIsReportedAfterOneRetry() async {
        transport.ignoreWrites()
        press(brightnessUp)
        press(brightnessUp)
        await settle()
        #expect(
            transport.takeEvents().filter { $0.hasPrefix("set") }.suffix(2) == [
                "set brightness=63", "set brightness=63",
            ])
        #expect(displays.primary?.brightness?.current == 50)
        #expect(recorder.mismatches == [.init(feature: .brightness, cached: 63, actual: 50, kind: .writeRefused)])
    }

    @Test func aWriteTheDisplayAdjustedIsNotCalledRefused() async {
        transport.adjustWrites()
        press(brightnessUp)
        await settle()
        #expect(displays.primary?.brightness?.current == 55)
        #expect(recorder.mismatches == [.init(feature: .brightness, cached: 56, actual: 55, kind: .writeAdjusted)])
    }

    @Test func aReadWithoutAnAnswerDoesNotMakeTheCacheFresh() async {
        press(brightnessUp)
        recorder.now += 3
        transport.answer(.brightness, false)
        await settle()  // the read-back, three seconds after the write, gets no answer
        transport.answer(.brightness, true)
        _ = transport.takeEvents()

        // Six seconds after the display was last heard from, it is read before it is written.
        recorder.now += 3
        press(brightnessUp)
        await settle()
        #expect(Array(transport.takeEvents().prefix(2)) == ["get brightness", "set brightness=63"])
    }

    @Test func aDisplayWithoutDDCIsWaitedForOnlyOnce() async {
        let transport = FakeTransport()
        transport.addDisplayWithoutDDC()
        var timing = Displays<FakeTransport>.Timing()
        timing.retryDelays = [0.01, 0.01, 0.01]
        let displays = Displays(transport: transport, queue: queue, timing: timing, onWriteFailure: {})

        // It may only be waking up, so the displays are looked for three more times.
        displays.refresh()
        await settle { transport.discoveries == 4 }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(transport.discoveries == 4)
        #expect(displays.primary?.brightness?.current == 50)
        // Only the display that answers is under control, and named in the menu.
        #expect(displays.controlled.count == 1)

        // Having stayed silent throughout, it is not waited for again.
        displays.refresh()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(transport.discoveries == 5)

        // Another display that does not answer is a new silence, and is waited for.
        transport.addDisplayWithoutDDC()
        displays.refresh()
        await settle { transport.discoveries == 9 }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(transport.discoveries == 9)
    }

    @Test func aReadInFlightWhenTheDisplaysGoToSleepIsDropped() async {
        pause()
        press(brightnessUp)  // the display is being read as it goes to sleep
        displays.suspend()
        await settle()
        _ = transport.takeEvents()

        // What was read on the way into sleep does not make the cache fresh again.
        press(brightnessUp)
        await settle()
        #expect(Array(transport.takeEvents().prefix(2)) == ["get brightness", "set brightness=56"])
    }

    @Test func aDiscoveryInFlightWhenTheDisplaysGoToSleepIsDropped() async {
        transport.change(.brightness, to: 80)
        displays.refresh()
        displays.suspend()
        await settle()
        #expect(displays.primary?.brightness?.current == 50)
        _ = transport.takeEvents()

        press(brightnessUp)
        await settle()
        #expect(transport.takeEvents().first == "get brightness")
    }

    @Test func readsTheDisplayForTheCommandLineAndLeavesTheCacheAlone() async {
        transport.change(.brightness, to: 80)
        let recorder = recorder
        displays.values(of: .brightness) { recorder.readings.append($0) }
        await settle()
        #expect(recorder.readings == [[DDC.Value(current: 80, maximum: 100)]])
        #expect(transport.takeEvents() == ["get brightness"])
        #expect(displays.primary?.brightness?.current == 50)
    }

    @Test func suspendDropsCommandsThatAreStillWaiting() async {
        pause()
        press(brightnessUp)
        displays.suspend()
        await settle()
        #expect(!transport.takeEvents().contains { $0.hasPrefix("set") })
        #expect(recorder.fractions == [0.56])
    }

    @Test func aControlWithoutADisplayDoesNothing() async {
        let empty = Displays(transport: transport, queue: queue, onWriteFailure: {})
        let recorder = recorder
        empty.apply(brightnessUp) { feedback, isFinal in
            recorder.fractions.append(feedback?.fraction)
            recorder.finals.append(isFinal)
        }
        await settle()
        // There is nothing to read for, so the answer is final at once.
        #expect(recorder.fractions == [nil])
        #expect(recorder.finals == [true])
        #expect(!transport.takeEvents().contains { $0.hasPrefix("set") })
    }
}

/// Two displays that answer DDC, each with a session of its own.
@MainActor
@Suite struct TwoDisplaysTests {
    private let transport = FakeTransport()
    private let queue = DispatchQueue(label: "TwoDisplaysTests")
    private let recorder = Recorder()
    private let displays: Displays<FakeTransport>

    init() async {
        transport.addSecondDisplay()
        var timing = Displays<FakeTransport>.Timing()
        timing.verifyDelay = 0
        let recorder = recorder
        displays = Displays(
            transport: transport, queue: queue, timing: timing, now: { recorder.now }, onWriteFailure: {})
        displays.refresh()
        await settle()
        _ = transport.takeEvents()
    }

    private func settle() async {
        for _ in 0..<8 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
        }
    }

    private func press(_ command: Command, on targets: [FakeTransport.Handle]? = nil) {
        let recorder = recorder
        displays.apply(command, to: targets) { feedback, isFinal in
            recorder.fractions.append(feedback?.fraction)
            recorder.finals.append(isFinal)
        }
    }

    private let brightnessUp = Command.step(.brightness, up: true, fine: false)

    @Test func eachDisplayHasASession() throws {
        let second = try #require(transport.second)
        #expect(displays.controlled.count == 2)
        #expect(displays.state(of: transport.handle)?.brightness?.current == 50)
        #expect(displays.state(of: second)?.brightness?.current == 30)
        // The second has no volume; the first does.
        #expect(displays.state(of: second)?.volume == nil && displays.hasVolume)
    }

    @Test func aCommandForOneDisplayLeavesTheOtherAlone() async throws {
        let second = try #require(transport.second)
        press(brightnessUp, on: [second])
        #expect(recorder.fractions == [0.31])
        await settle()
        #expect(transport.takeEvents() == ["2: set brightness=31", "2: get brightness"])
        #expect(displays.state(of: second)?.brightness?.current == 31)
        #expect(displays.state(of: transport.handle)?.brightness?.current == 50)
    }

    /// A command for every display goes to each, and the first display's level is shown.
    @Test func aCommandForEveryDisplayGoesToEach() async {
        press(brightnessUp)
        #expect(recorder.fractions == [0.56] && recorder.finals == [true])
        await settle()
        #expect(transport.value(.brightness) == 56 && transport.secondValue(.brightness) == 31)
    }

    /// Each display keeps its own account of when it was heard from: writing to one does not
    /// make the other's cache fresh.
    @Test func eachDisplayIsHeardFromOnItsOwn() async throws {
        let second = try #require(transport.second)
        recorder.now += 6
        press(brightnessUp, on: [transport.handle])
        await settle()
        _ = transport.takeEvents()
        press(brightnessUp, on: [second])
        await settle()
        #expect(Array(transport.takeEvents().prefix(2)) == ["2: get brightness", "2: set brightness=31"])
    }

    /// A display without the control is left out, and when none of those asked has it, there is
    /// nothing to do.
    @Test func aDisplayWithoutTheControlIsLeftOut() async throws {
        let second = try #require(transport.second)
        press(.step(.volume, up: true, fine: false))
        await settle()
        #expect(!transport.takeEvents().contains { $0.hasPrefix("2:") })
        press(.step(.volume, up: true, fine: false), on: [second])
        #expect(recorder.fractions.last == .some(nil) && recorder.finals.last == true)
    }
}
