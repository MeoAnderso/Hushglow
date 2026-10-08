import AppKit
import DisplayKeysCore
import Foundation
import Testing

@testable import DisplayKeys

@Suite struct PrivateAPITests {
    /// Canary: fails on a macOS release that removes the private IOAVService functions.
    @Test func displayControlFunctionsResolve() {
        #expect(IOAV.shared != nil)
    }
}

@Suite struct BundleTests {
    @Test func bundleIdentifierMatchesInfoPlist() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist))
        #expect(info["CFBundleIdentifier"] as? String == AppInfo.bundleID)
    }
}

/// Writes an image for visual review when PREVIEW_DIR is set; does nothing otherwise.
@MainActor
private func writePreview(_ image: NSImage, named name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { return }
    let scale: CGFloat = 2
    let bitmap = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
            pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
}

@MainActor
@Suite struct OSDViewTests {
    private static let barStartFraction = 50.0 / 250.0

    private func render(_ indication: Indication) throws -> NSBitmapImageRep {
        let view = OSDView(frame: NSRect(origin: .zero, size: OSD.size))
        view.indication = indication
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Columns right of the icon that are drawn solid, sampled along the centre line.
    private func filledColumns(_ bitmap: NSBitmapImageRep) -> Int {
        let start = Int(Double(bitmap.pixelsWide) * Self.barStartFraction)
        return (start..<bitmap.pixelsWide).count { column in
            (bitmap.colorAt(x: column, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.8
        }
    }

    private func level(_ kind: Feedback.Kind, _ fraction: Double) -> Indication {
        .level(Feedback(kind: kind, fraction: fraction))
    }

    @Test func barFillFollowsTheLevel() throws {
        let empty = filledColumns(try render(level(.brightness, 0)))
        let half = filledColumns(try render(level(.brightness, 0.5)))
        let full = filledColumns(try render(level(.brightness, 1)))
        #expect(empty == 0)
        #expect(full > 100)
        #expect(abs(half * 2 - full) <= full / 10)
    }

    @Test func mutedBarIsDimmed() throws {
        #expect(filledColumns(try render(level(.muted, 1))) == 0)
    }

    @Test func messagesAreDrawnInsteadOfABar() throws {
        let full = filledColumns(try render(level(.brightness, 1)))
        for indication in [Indication.noDisplay, .refused(.brightness), .unsupported(.volume)] {
            let columns = filledColumns(try render(indication))
            #expect(columns > 0 && columns < full)
        }
    }

    @Test func writesPreviews() throws {
        let samples: [Indication] = [
            level(.brightness, 0.5), level(.volume, 0.19), level(.muted, 0.5),
            .refused(.brightness), .unsupported(.volume), .noDisplay,
        ]
        let sheet = NSImage(
            size: NSSize(width: OSD.size.width + 24, height: (OSD.size.height + 12) * CGFloat(samples.count) + 12))
        sheet.lockFocus()
        NSColor(white: 0.45, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (index, sample) in samples.enumerated() {
            let frame = NSRect(
                x: 12, y: 12 + CGFloat(samples.count - 1 - index) * (OSD.size.height + 12),
                width: OSD.size.width, height: OSD.size.height)
            NSColor(white: 0.12, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
            try render(sample).draw(
                in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        sheet.unlockFocus()
        try writePreview(sheet, named: "osd-preview")
    }
}

@MainActor
@Suite struct ShortcutsWindowTests {
    @Test func buildsARowForEveryAction() throws {
        let window = ShortcutsWindow(onOpen: {}, onClose: {})
        let content = window.makeContentView()
        let fields = content.subviews.compactMap { $0 as? ShortcutField }
        #expect(fields.count == Shortcut.Action.allCases.count)

        // Previews in both appearances, each on the window background that appearance would give it.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            content.appearance = appearance
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let image = NSImage(size: content.bounds.size, flipped: false) { rect in
                appearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    rect.fill()
                }
                return bitmap.draw(
                    in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
            try writePreview(image, named: "shortcuts-window-\(name == .aqua ? "light" : "dark")")
        }
    }
}

@MainActor
@Suite struct CommandChannelTests {
    /// A private namespace, so these tests never reach an installed copy of the app.
    private let namespace = "local.DisplayKeys.tests.\(UUID().uuidString)"

    @MainActor
    private final class Received {
        var commands: [Command] = []
        var shortcutChanges = 0
        var keyTests = 0
        var watches: [TimeInterval] = []
    }

    /// Waits without blocking the main thread, which is where the notifications arrive.
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<150 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeStatus() -> AppStatus {
        AppStatus(
            version: "9.9.9", build: "abc1234", displayControlAvailable: true,
            brightness: .init(current: 61, maximum: 100), volume: nil, muted: false, accessGranted: true,
            askingIsDisabled: false, keyTapActive: true, soundGoesToDisplay: true, quarterSteps: false,
            shortcuts: [.init(action: "mute", keys: "ctrl+alt+end", registered: false)], input: .init(),
            lastReadMilliseconds: 31, isWatchingKeys: false, watchedKeys: ["key f11"])
    }

    @Test func carriesEveryMessageToTheApp() async {
        let received = Received()
        let channel = CommandChannel(
            namespace: namespace,
            handlers: .init(
                onCommand: { received.commands.append($0) },
                onShortcutsChanged: { received.shortcutChanges += 1 },
                onKeyTest: { received.keyTests += 1 },
                onWatchKeys: { received.watches.append($0) },
                status: makeStatus))
        defer { channel.stop() }
        let client = CommandClient(namespace: namespace)

        client.send(.step(.volume, up: true, fine: true))
        client.send(.mute(.off))
        client.notifyShortcutsChanged()
        client.requestKeyTest()
        client.watchKeys(seconds: 10)
        await wait { received.watches.count == 1 }

        #expect(received.commands == [.step(.volume, up: true, fine: true), .mute(.off)])
        #expect(received.shortcutChanges == 1)
        #expect(received.keyTests == 1)
        #expect(received.watches == [10])
    }

    @Test func returnsTheAppsStatus() async throws {
        let channel = CommandChannel(
            namespace: namespace,
            handlers: .init(
                onCommand: { _ in }, onShortcutsChanged: {}, onKeyTest: {}, onWatchKeys: { _ in }, status: makeStatus))
        defer { channel.stop() }

        let request = CommandClient(namespace: namespace).beginStatusRequest()
        defer { request.finish() }
        await wait { request.status != nil }
        let status = try #require(request.status)
        #expect(status.version == "9.9.9")
        #expect(status.build == "abc1234")
        #expect(status.brightness?.current == 61)
        #expect(status.shortcuts.first?.registered == false)
        #expect(status.lastReadMilliseconds == 31)
        #expect(status.watchedKeys == ["key f11"])
    }

    @Test func waitingForAnAnswerGivesUpWhenThereIsNone() {
        #expect(CommandClient(namespace: namespace).requestStatus(timeout: 0.2) == nil)
    }
}
