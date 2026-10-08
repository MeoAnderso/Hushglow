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
    private var appliesWrites = true

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
            if appliesWrites { values[feature] = value }
            return true
        }
    }

    func change(_ feature: DDC.Feature, to value: Int) {
        lock.withLock { values[feature] = value }
    }

    func ignoreWrites() {
        lock.withLock { appliesWrites = false }
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
    var mismatches: [String] = []
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
        displays.onMismatch = { feature, cached, actual, afterWrite in
            recorder.mismatches.append("\(feature) cached=\(cached) actual=\(actual) afterWrite=\(afterWrite)")
        }
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
        displays.apply(command) { recorder.fractions.append($0?.fraction) }
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
        await settle()
        // The write goes out first; the read is the read-back that follows a burst.
        #expect(transport.takeEvents() == ["set brightness=56", "get brightness"])
        #expect(recorder.mismatches.isEmpty)
    }

    @Test func aStaleCacheIsReadBeforeWriting() async {
        recorder.now += 6
        transport.change(.brightness, to: 80)

        press(brightnessUp)
        #expect(recorder.fractions == [0.56])  // expected result, shown at once
        await settle()
        #expect(recorder.fractions == [0.56, 0.81])  // real result, after reading the display
        #expect(transport.takeEvents() == ["get brightness", "set brightness=81", "get brightness"])
        #expect(displays.primary?.brightness?.current == 81)
        #expect(recorder.mismatches == ["brightness cached=50 actual=80 afterWrite=false"])
    }

    @Test func pressesDuringTheReadAreReplayedInOrder() async {
        recorder.now += 6
        transport.change(.brightness, to: 80)

        for _ in 0..<3 { press(brightnessUp) }
        #expect(recorder.fractions == [0.56, 0.63, 0.69])
        await settle()
        #expect(Array(recorder.fractions.suffix(3)) == [0.81, 0.88, 0.94])
        #expect(transport.value(.brightness) == 94)
    }

    @Test func volumeCommandsReadVolumeAndMute() async {
        recorder.now += 6
        press(.step(.volume, up: true, fine: false))
        await settle()
        #expect(Array(transport.takeEvents().prefix(3)) == ["get volume", "get mute", "set volume=19"])
    }

    @Test func aWriteTheDisplayIgnoredIsNoticedOnReadBack() async {
        transport.ignoreWrites()
        press(brightnessUp)
        await settle()
        #expect(displays.primary?.brightness?.current == 50)
        #expect(recorder.mismatches == ["brightness cached=56 actual=50 afterWrite=true"])
    }

    @Test func suspendDropsCommandsThatAreStillWaiting() async {
        recorder.now += 6
        press(brightnessUp)
        displays.suspend()
        await settle()
        #expect(!transport.takeEvents().contains { $0.hasPrefix("set") })
        #expect(recorder.fractions == [0.56])
    }

    @Test func aControlWithoutADisplayDoesNothing() async {
        let empty = Displays(transport: transport, queue: queue, onWriteFailure: {})
        let recorder = recorder
        empty.apply(brightnessUp) { recorder.fractions.append($0?.fraction) }
        await settle()
        #expect(recorder.fractions == [nil, nil])
        #expect(!transport.takeEvents().contains { $0.hasPrefix("set") })
    }
}
