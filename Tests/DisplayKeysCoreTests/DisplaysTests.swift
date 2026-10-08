import Foundation
import Testing

@testable import DisplayKeysCore

/// A display that records what it is asked, and can be changed behind the app's back.
private final class FakeTransport: DisplayTransport, @unchecked Sendable {
    final class Handle: Sendable {}

    private let lock = NSLock()
    private let handle = Handle()
    private var values: [DDC.Feature: Int] = [.brightness: 50, .volume: 13, .mute: DDC.Mute.off]
    private var events: [String] = []
    /// What the display does with a written value; nil means it ignores writes.
    private var onWrite: ((Int) -> Int)? = { $0 }
    private var dropsRemaining = 0

    func displays() -> [Handle] { [handle] }

    func get(_ display: Handle, _ feature: DDC.Feature) -> DDC.Value? {
        lock.withLock {
            events.append("get \(feature)")
            return values[feature].map { DDC.Value(current: $0, maximum: 100) }
        }
    }

    func set(_ display: Handle, _ feature: DDC.Feature, value: Int) -> Bool {
        lock.withLock {
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
        #expect(recorder.fractions == [nil, nil])
        #expect(recorder.finals == [false, true])
        #expect(!transport.takeEvents().contains { $0.hasPrefix("set") })
    }
}
