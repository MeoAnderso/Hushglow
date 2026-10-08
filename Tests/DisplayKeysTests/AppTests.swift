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

// MARK: Pictures for review

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

/// A picture of a view as it draws itself, on the window background of the given appearance.
@MainActor
private func picture(of view: NSView, in name: NSAppearance.Name) throws -> NSImage {
    let appearance = try #require(NSAppearance(named: name))
    view.appearance = appearance
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return NSImage(size: view.bounds.size, flipped: false) { rect in
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
        }
        return bitmap.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }
}

@MainActor
private func writePreviews(of view: NSView, named name: String) throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        try writePreview(
            try picture(of: view, in: appearance), named: "\(name)-\(appearance == .aqua ? "light" : "dark")")
    }
}

// MARK: Indicator

@MainActor
@Suite struct OSDViewTests {
    private static let barStartFraction = 50.0 / 250.0

    private func view(_ indication: Indication, percentage: Bool = false, dark: Bool = true) -> OSDView {
        let view = OSDView(frame: NSRect(origin: .zero, size: OSD.size))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.showsPercentage = percentage
        view.show(indication, animated: false)
        return view
    }

    private func render(_ view: OSDView) throws -> NSBitmapImageRep {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Columns right of the icon that are drawn solid, sampled along the centre line.
    private func filledColumns(_ bitmap: NSBitmapImageRep) -> Int {
        let start = Int(Double(bitmap.pixelsWide) * Self.barStartFraction)
        return (start..<bitmap.pixelsWide).count { column in
            (bitmap.colorAt(x: column, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.9
        }
    }

    private func level(_ kind: Feedback.Kind, _ fraction: Double) -> Indication {
        .level(Feedback(kind: kind, fraction: fraction))
    }

    @Test func barFillFollowsTheLevel() throws {
        let empty = filledColumns(try render(view(level(.brightness, 0))))
        let half = filledColumns(try render(view(level(.brightness, 0.5))))
        let full = filledColumns(try render(view(level(.brightness, 1))))
        #expect(empty == 0)
        #expect(full > 100)
        #expect(abs(half * 2 - full) <= full / 10)
    }

    @Test func mutedBarIsDimmed() throws {
        #expect(filledColumns(try render(view(level(.muted, 1)))) == 0)
    }

    @Test func thePercentageTakesRoomFromTheBar() throws {
        let without = filledColumns(try render(view(level(.brightness, 1))))
        let with = filledColumns(try render(view(level(.brightness, 1), percentage: true)))
        #expect(with > 0 && with < without)
    }

    @Test func marksAreLightOnDarkAndDarkOnLight() throws {
        func inkBrightness(dark: Bool) throws -> CGFloat {
            let bitmap = try render(view(level(.brightness, 1), dark: dark))
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
            return try #require(color.usingColorSpace(.deviceGray)).whiteComponent
        }
        #expect(try inkBrightness(dark: true) > 0.9)
        #expect(try inkBrightness(dark: false) < 0.2)
    }

    @Test func messagesAreDrawnInsteadOfABar() throws {
        let full = filledColumns(try render(view(level(.brightness, 1))))
        for indication in [Indication.noDisplay, .refused(.brightness), .unsupported(.volume)] {
            let columns = filledColumns(try render(view(indication)))
            #expect(columns > 0 && columns < full)
        }
    }

    @Test func describesItselfForVoiceOver() {
        #expect(Announcer.words(for: level(.brightness, 0.5625)) == "Brightness 56 percent")
        #expect(Announcer.words(for: level(.muted, 0.3)) == "Muted")
        #expect(Announcer.words(for: .refused(.volume)) == "Volume is locked by the display")
    }
}

// MARK: Windows and menu

@MainActor
private final class StubHost: SettingsHost {
    var keyboardKeysAreActive = false
    var keyboardAskingIsDisabled = false
    var refusesEverything = false
    var shortcutsUsedByMacOS: [Shortcut] = []
    func enableKeyboardKeys() {}
    func pauseShortcuts() {}
    func resumeShortcuts() {}
    func canRegister(_ shortcut: Shortcut) -> Bool { !refusesEverything }
    func previewIndicator() {}
}

@MainActor
@Suite struct SettingsWindowTests {
    @Test func hasAFieldForEveryAction() throws {
        let host = StubHost()
        let content = SettingsWindow(host: host).makeContentView()
        let fields = content.subviews.compactMap { $0 as? ShortcutField }
        #expect(fields.count == Shortcut.Action.allCases.count)
        #expect(
            fields.allSatisfy { $0.isAccessibilityElement() && $0.accessibilityLabel()?.hasSuffix("shortcut") == true })
        try writePreviews(of: content, named: "settings")
    }

    @Test func aFieldExplainsWhyItRefusesAShortcut() throws {
        let field = ShortcutField(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        var messages: [String?] = []
        var changes: [Shortcut?] = []
        field.validate = { $0 == nil ? "not a usable key" : nil }
        field.onMessage = { messages.append($0) }
        field.onChange = { changes.append($0) }

        func press(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
            field.keyDown(with: event)
        }

        try press(49)  // Space starts recording
        #expect(field.isRecording)
        try press(0, [.control])  // the A key cannot be a shortcut
        #expect(field.isRecording)
        #expect(messages.last == "not a usable key")
        try press(0x7E, [.control, .option])  // Ctrl-Alt-Up is taken
        #expect(!field.isRecording)
        #expect(changes == [Shortcut("ctrl+alt+up")])
        #expect(field.accessibilityValue() as? String == "Control Option Up Arrow")
        try press(51)  // Delete removes it
        #expect(changes.count == 2 && changes.last == .some(nil))
    }

    private func messages(in content: NSView) -> [String] {
        content.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.filter { $0.hasPrefix("macOS uses") }
    }

    @Test func refusesAShortcutMacOSUsesItself() throws {
        let host = StubHost()
        host.shortcutsUsedByMacOS = [try #require(Shortcut("ctrl+up"))]
        // The fields call back into the window, so it has to outlive the key presses.
        let settings = SettingsWindow(host: host)
        let content = settings.makeContentView()
        let field = try #require(content.subviews.compactMap { $0 as? ShortcutField }.first)
        let before = field.shortcut
        for (keyCode, flags) in [(UInt16(49), NSEvent.ModifierFlags()), (0x7E, [.control])] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
            field.keyDown(with: event)
        }
        #expect(messages(in: content).first?.hasPrefix("macOS uses ⌃↑ itself.") == true)
        #expect(field.shortcut == before)
    }

    @Test func saysWhichCurrentShortcutsMacOSUses() throws {
        let host = StubHost()
        let current = try #require(Shortcut.Action.allCases.compactMap { ShortcutSettings.text(for: $0) }.first)
        let shortcut = try #require(Shortcut(current))
        #expect(messages(in: SettingsWindow(host: host).makeContentView()).isEmpty)
        host.shortcutsUsedByMacOS = [shortcut]
        #expect(
            messages(in: SettingsWindow(host: host).makeContentView())
                == ["macOS uses \(shortcut.symbols) for shortcuts of its own, so it may not work here."])
    }
}

@MainActor
@Suite struct SystemShortcutTests {
    @Test func readsMacOSsOwnShortcuts() {
        // Carbon's form sets one more flag on every arrow and function key; it is ignored.
        #expect(Hotkeys.shortcut(keyCode: 0x7E, carbonFlags: 0x021000) == Shortcut("ctrl+up"))
        #expect(Hotkeys.shortcut(keyCode: 0x7B, carbonFlags: 0x021A00) == Shortcut("ctrl+alt+shift+left"))
        #expect(Hotkeys.shortcut(keyCode: 0x67, carbonFlags: 0) == Shortcut("f11"))
        // The A key is not one a shortcut here can use.
        #expect(Hotkeys.shortcut(keyCode: 0, carbonFlags: 0x100) == nil)
        // Whatever this Mac has switched on, the list holds usable shortcuts only.
        #expect(Hotkeys.usedByMacOS().allSatisfy { Shortcut.keyName(for: $0.keyCode) != nil })
    }
}

/// Whether two parts of a view overlap, or one reaches outside it. The faint panel behind a
/// group of rows is meant to lie under them, and so is the helper's glow.
@MainActor
private func hasLayoutFault(_ view: NSView) -> Bool {
    let parts = view.subviews.filter { !($0 is WellView || $0 is AuraView) }
    for (index, part) in parts.enumerated() {
        if !view.bounds.contains(part.frame) { return true }
        if parts[(index + 1)...].contains(where: { $0.frame.intersects(part.frame) }) { return true }
        let isPlainHolder = type(of: part) == NSView.self || part is FlippedView
        if isPlainHolder, hasLayoutFault(part) { return true }
    }
    return false
}

@MainActor
@Suite struct WelcomeWindowTests {
    private static let cases: [(WelcomeWindow.Occasion, Bool)] = [
        (.firstLaunch, false), (.firstLaunch, true), (.update, false), (.update, true),
    ]

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
    }

    @Test func offersTheRightChoicesForEachOccasion() {
        for (occasion, keysAreActive) in Self.cases {
            let content = WelcomeWindow(onTurnOn: {}, onDontAsk: {})
                .makeContentView(occasion, keysAreActive: keysAreActive)
            var expected = keysAreActive ? ["OK"] : ["Not Now", "Turn On Keyboard Keys…"]
            if occasion == .update, !keysAreActive { expected.append("Don’t ask again after updates") }
            #expect(buttons(in: content).map(\.title) == expected)
        }
    }

    @Test func nothingOverlapsOrLeavesThePanel() {
        for (occasion, keysAreActive) in Self.cases {
            let content = WelcomeWindow(onTurnOn: {}, onDontAsk: {})
                .makeContentView(occasion, keysAreActive: keysAreActive)
            #expect(content.subviews.count >= 4)
            #expect(!hasLayoutFault(content))
        }
    }

    /// Both occasions use the one design: the shortcuts, and the note that they can be changed.
    @Test func showsTheShortcutsOnBothOccasions() {
        for (occasion, keysAreActive) in Self.cases {
            let content = WelcomeWindow(onTurnOn: {}, onDontAsk: {})
                .makeContentView(occasion, keysAreActive: keysAreActive)
            let texts = content.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            #expect(texts.contains { $0.hasPrefix("You can also change them, if you want.") })
            #expect(content.subviews.contains { $0 is FlippedView && $0.subviews.contains { $0 is WellView } })
        }
    }

    /// macOS 27 renamed the list, and the notices have to send people to the right one.
    @Test func namesTheListAsSystemSettingsDoes() {
        if #available(macOS 27, *) {
            #expect(AccessibilityAccess.listName == "Device Control and Data Access")
        } else {
            #expect(AccessibilityAccess.listName == "Accessibility")
        }
        for occasion in [WelcomeWindow.Occasion.firstLaunch, .update] {
            let content = WelcomeWindow(onTurnOn: {}, onDontAsk: {}).makeContentView(occasion, keysAreActive: false)
            let texts = content.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            #expect(texts.contains { $0.contains(AccessibilityAccess.listName) })
        }
    }

    /// Presses a button of the update notice and returns what it led to, in order.
    private func press(_ title: String, ticked: Bool, closingWithTheCloseButton: Bool = false) throws -> [String] {
        var calls: [String] = []
        let welcome = WelcomeWindow(onTurnOn: { calls.append("turn on") }, onDontAsk: { calls.append("stop asking") })
        let window = welcome.makeWindow(.update, keysAreActive: false)
        let all = buttons(in: try #require(window.contentView))
        try #require(all.first { $0.title.hasPrefix("Don’t ask") }).state = ticked ? .on : .off
        if closingWithTheCloseButton {
            window.close()
        } else {
            try #require(all.first { $0.title == title }).performClick(nil)
        }
        return calls
    }

    @Test func theButtonsDoWhatTheySay() throws {
        #expect(try press("Turn On Keyboard Keys…", ticked: false) == ["turn on"])
        #expect(try press("Not Now", ticked: false) == [])
        #expect(try press("Not Now", ticked: true) == ["stop asking"])
        #expect(try press("", ticked: true, closingWithTheCloseButton: true) == ["stop asking"])
        // Asking for access turns asking back on, so a ticked checkbox has to be applied last.
        #expect(try press("Turn On Keyboard Keys…", ticked: true) == ["turn on", "stop asking"])
    }
}

@MainActor
@Suite struct PermissionHelperTests {
    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1050)
    private let size = PermissionHelper.size

    @Test func sitsCentredUnderTheList() {
        let settings = NSRect(x: 400, y: 300, width: 715, height: 600)
        let frame = PermissionHelper.frame(under: settings, visible: screen)
        #expect(frame.size == size)
        #expect(frame.maxY < settings.minY)
        // The list is the part of the window right of the sidebar.
        #expect(abs(frame.midX - (settings.minX + 215 + 250)) <= 1)
    }

    @Test func staysOnScreenWhenThereIsNoRoomBelow() {
        let low = NSRect(x: 400, y: 20, width: 715, height: 600)
        let overLowerEdge = PermissionHelper.frame(under: low, visible: screen)
        #expect(screen.contains(overLowerEdge) && overLowerEdge.intersects(low))

        let offTheRight = NSRect(x: 1700, y: 300, width: 715, height: 600)
        #expect(screen.contains(PermissionHelper.frame(under: offTheRight, visible: screen)))
        let offTheLeft = NSRect(x: -600, y: 300, width: 715, height: 600)
        #expect(screen.contains(PermissionHelper.frame(under: offTheLeft, visible: screen)))
    }

    @Test func convertsWindowListFramesToAppKit() {
        // 100 points down from the top of a 1080-point screen, 600 tall.
        let frame = PermissionHelper.appKitFrame(CGRect(x: 50, y: 100, width: 700, height: 600), primaryHeight: 1080)
        #expect(frame == NSRect(x: 50, y: 380, width: 700, height: 600))
    }

    /// Every view inside another, at any depth.
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test func offersDraggingAndAWayWithoutIt() {
        var asked = 0
        let helper = PermissionHelper(onAddWithoutDragging: { asked += 1 })
        let content = helper.makeContentView()
        // The arrow, the icon's round glass and the caption's capsule stand apart, over the glow.
        let room = PermissionHelper.glowMargin
        #expect(content.frame.size == NSSize(width: size.width + room, height: size.height + room))
        #expect(content.subviews.count == 4 && content.subviews.first is AuraView)
        #expect(!hasLayoutFault(content))
        // The glow never takes a click meant for something under it.
        #expect(content.subviews.first?.hitTest(NSPoint(x: 5, y: 5)) == nil)

        let parts = descendants(of: content)
        #expect(parts.contains { $0 is AppIconDragView })
        let texts = parts.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts.contains("Drag DisplayKeys into the list above"))
        // Inside the capsule nothing overlaps either.
        let caption = parts.first { $0 is FlippedView && $0.subviews.contains { $0 is NSTextField } }
        #expect(caption.map(hasLayoutFault) == false)
        let buttons = parts.compactMap { $0 as? NSButton }
        #expect(buttons.compactMap { $0.accessibilityLabel() }.sorted() == ["Close", "Other ways to add DisplayKeys"])

        helper.addWithoutDragging()
        #expect(asked == 1)
    }
}

@MainActor
@Suite struct MenuRowTests {
    @Test func aRowShowsItsValueAndIsLabelled() throws {
        let row = SliderRow(name: "Volume", symbol: "speaker.wave.2.fill", hasButton: true)
        row.show(percent: 56.4)
        #expect(row.slider.doubleValue == 56.4)
        #expect(row.slider.accessibilityLabel() == "Volume")
        #expect(row.button != nil)
        #expect(row.subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "56%")
        try writePreviews(of: row, named: "menu-row")
    }
}

// MARK: Command channel

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
            shortcuts: [.init(action: "mute", keys: "ctrl+alt+end", registered: false, usedByMacOS: true)],
            input: .init(),
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

// MARK: The indicator as it appears on screen

/// A busy page, bright on the left and dark on the right, for the indicator to sit over.
private final class BackdropView: NSView {
    var labels: [(String, CGFloat)] = []

    override func draw(_ dirtyRect: NSRect) {
        let half = bounds.width / 2
        NSGradient(colors: [
            .white, NSColor(srgbRed: 1, green: 0.93, blue: 0.6, alpha: 1),
            NSColor(srgbRed: 1, green: 0.7, blue: 0.75, alpha: 1),
        ])!
        .draw(in: NSRect(x: 0, y: 0, width: half, height: bounds.height), angle: 20)
        NSGradient(colors: [
            NSColor(srgbRed: 0.03, green: 0.04, blue: 0.1, alpha: 1),
            NSColor(srgbRed: 0.1, green: 0.16, blue: 0.4, alpha: 1),
        ])!
        .draw(in: NSRect(x: half, y: 0, width: half, height: bounds.height), angle: 20)
        let colors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemTeal, .systemRed]
        for index in 0..<14 {
            colors[index % colors.count].withAlphaComponent(0.85).setFill()
            let y = CGFloat((index * 97) % Int(max(bounds.height - 60, 1)))
            NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * 74 + 150, y: y, width: 54, height: 54)).fill()
        }
        for (x, color) in [(CGFloat(0), NSColor.black), (half, NSColor.white)] {
            for line in 0..<Int(bounds.height / 22) {
                NSAttributedString(
                    string: "The quick brown fox jumps over the lazy dog 0123456789",
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color.withAlphaComponent(0.8)]
                ).draw(at: NSPoint(x: x + 150, y: CGFloat(line) * 22 + 4))
            }
        }
        for (text, y) in labels {
            NSAttributedString(
                string: " \(text) ",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.black,
                    .backgroundColor: NSColor.white,
                ]
            ).draw(at: NSPoint(x: 6, y: y + 14))
        }
    }
}

/// Photographs this process's own windows, composited by the window server, front to back.
@MainActor
private func photograph(_ windows: [NSWindow], size: NSSize) throws -> NSImage {
    typealias Capture = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
    let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"))
    let capture = unsafeBitCast(symbol, to: Capture.self)
    var ids = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
    let array = try #require(CFArrayCreate(nil, &ids, ids.count, nil))
    let image = try #require(capture(.null, array, 0)?.takeRetainedValue())
    return NSImage(cgImage: image, size: size)
}

@MainActor
@Suite struct GlassWindowTests {
    /// Pictures of the Settings panel and the two notices over a page that is bright on one side
    /// and dark on the other. Runs only when PREVIEW_DIR is set.
    @Test func picturesOfTheWindows() async throws {
        guard ProcessInfo.processInfo.environment["PREVIEW_DIR"] != nil else { return }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let host = StubHost()

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let settings = SettingsWindow(host: host).makeWindow()
            let welcome = WelcomeWindow(onTurnOn: {}, onDontAsk: {})
            let update = WelcomeWindow(onTurnOn: {}, onDontAsk: {})
            let first = welcome.makeWindow(.firstLaunch, keysAreActive: false)
            let updated = update.makeWindow(.update, keysAreActive: false)
            // Set on the windows, not the application: other picture tests run alongside this one.
            for window in [settings, first, updated] { window.appearance = NSAppearance(named: appearance) }

            let size = NSSize(
                width: settings.frame.width + first.frame.width + updated.frame.width + 200,
                height: max(settings.frame.height, first.frame.height, updated.frame.height) + 80)
            let frame = NSRect(origin: NSPoint(x: 40, y: 60), size: size)
            let backdropWindow = NSWindow(
                contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            backdropWindow.isReleasedWhenClosed = false
            backdropWindow.contentView = BackdropView(frame: NSRect(origin: .zero, size: size))

            var x = frame.minX + 40
            for window in [settings, first, updated] {
                window.setFrameOrigin(NSPoint(x: x, y: frame.maxY - window.frame.height - 40))
                x += window.frame.width + 40
            }
            backdropWindow.orderFrontRegardless()
            for window in [settings, first, updated] { window.orderFrontRegardless() }
            try await Task.sleep(for: .milliseconds(1400))

            let picture = try photograph([updated, first, settings, backdropWindow], size: size)
            try writePreview(picture, named: "windows-\(appearance == .aqua ? "light" : "dark")")
            for window in [updated, first, settings, backdropWindow] { window.close() }
        }
    }
}

extension GlassWindowTests {
    /// Pictures of the permission helper over the same page, and a short film of its glow.
    /// Runs only when PREVIEW_DIR is set.
    @Test func pictureOfTheHelper() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        let helper = PermissionHelper(onAddWithoutDragging: {})
        let panelSize = PermissionHelper.panelFrame(around: NSRect(origin: .zero, size: PermissionHelper.size)).size
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let size = NSSize(width: panelSize.width * 2 + 120, height: panelSize.height + 80)
            let frame = NSRect(origin: NSPoint(x: 40, y: 60), size: size)
            let backdropWindow = NSWindow(
                contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            backdropWindow.isReleasedWhenClosed = false
            backdropWindow.contentView = BackdropView(frame: NSRect(origin: .zero, size: size))
            backdropWindow.orderFrontRegardless()
            var panels: [NSWindow] = []
            for x in [frame.minX + 40, frame.midX + 20] {
                let panel = NSPanel(
                    contentRect: NSRect(origin: NSPoint(x: x, y: frame.minY + 40), size: panelSize),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.appearance = NSAppearance(named: appearance)
                panel.contentView = helper.makeContentView()
                panel.orderFrontRegardless()
                panels.append(panel)
            }
            try await Task.sleep(for: .milliseconds(900))
            let picture = try photograph(panels + [backdropWindow], size: size)
            try writePreview(picture, named: "helper-\(appearance == .aqua ? "light" : "dark")")
            if appearance == .darkAqua {
                try await film(panels + [backdropWindow], to: URL(fileURLWithPath: directory))
            }
            for window in panels + [backdropWindow] { window.close() }
        }
    }

    /// Photographs the windows over one turn of the spreading ring and writes the frames as an
    /// animated picture, with three of them as stills.
    private func film(_ windows: [NSWindow], to directory: URL) async throws {
        typealias Capture = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        let function = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"))
        let capture = unsafeBitCast(function, to: Capture.self)
        var ids = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        let array = try #require(CFArrayCreate(nil, &ids, ids.count, nil))
        let nominalResolution: UInt32 = 1 << 4
        var frames: [CGImage] = []
        for _ in 0..<30 {
            frames.append(try #require(capture(.null, array, nominalResolution)?.takeRetainedValue()))
            try await Task.sleep(for: .milliseconds(80))
        }
        let film = try #require(
            CGImageDestinationCreateWithURL(
                directory.appendingPathComponent("helper-glow.gif") as CFURL, "com.compuserve.gif" as CFString,
                frames.count, nil))
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(film, loop)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(film, frame, delay) }
        #expect(CGImageDestinationFinalize(film))
        for index in [0, 10, 20] {
            let still = NSBitmapImageRep(cgImage: frames[index])
            try #require(still.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("helper-glow-\(index).png"))
        }
    }
}

@MainActor
@Suite struct IndicatorOnScreenTests {
    /// Pictures of the capsules the app really builds, composited over a page by the window
    /// server. Only this process's own windows are captured. Runs only when PREVIEW_DIR is set,
    /// since it puts a window on screen for a moment.
    @Test func picturesOfEachLook() async throws {
        guard ProcessInfo.processInfo.environment["PREVIEW_DIR"] != nil else { return }
        typealias Capture = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"))
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let looks: [(String, IndicatorLook, Bool)] = [
            ("Glass", .preview(.glass), false),
            ("Glass, percentage", .preview(.glass), true),
            ("See-through glass", .preview(.seeThrough), false),
            ("Plain tint", .preview(.plain), false),
            ("Reduce Transparency", .preview(.glass, reducesTransparency: true), false),
            ("Increase Contrast", .preview(.glass, increasesContrast: true), false),
        ]
        let rowHeight: CGFloat = 66
        let size = NSSize(width: 1120, height: rowHeight * CGFloat(looks.count) + 20)
        let frame = NSRect(origin: NSPoint(x: 80, y: 140), size: size)

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            application.appearance = NSAppearance(named: appearance)
            let backdropWindow = NSWindow(
                contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            // Windows made in code release themselves on close unless told not to.
            backdropWindow.isReleasedWhenClosed = false
            let backdrop = BackdropView(frame: NSRect(origin: .zero, size: size))
            backdropWindow.contentView = backdrop
            let overlay = NSPanel(
                contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            overlay.isReleasedWhenClosed = false
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false
            let holder = NSView(frame: NSRect(origin: .zero, size: size))
            overlay.contentView = holder

            for (index, (name, look, percentage)) in looks.enumerated() {
                let y = size.height - 10 - rowHeight * CGFloat(index + 1) + 11
                backdrop.labels.append((name, y))
                for x in [CGFloat(210), size.width / 2 + 210] {
                    let indicator = OSDView(frame: NSRect(origin: .zero, size: OSD.size))
                    indicator.isHighContrast = look.increasesContrast
                    indicator.showsPercentage = percentage
                    indicator.show(.level(Feedback(kind: .brightness, fraction: 0.5625)), animated: false)
                    let capsule = OSD.capsule(around: indicator, look: look)
                    capsule.setFrameOrigin(NSPoint(x: x, y: y))
                    holder.addSubview(capsule)
                }
            }
            backdropWindow.orderFrontRegardless()
            backdropWindow.addChildWindow(overlay, ordered: .above)
            overlay.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(1200))

            var ids = [overlay, backdropWindow].map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
            let array = try #require(CFArrayCreate(nil, &ids, ids.count, nil))
            let image = try #require(capture(.null, array, 0)?.takeRetainedValue())
            let picture = NSImage(cgImage: image, size: size)
            try writePreview(picture, named: "indicator-\(appearance == .aqua ? "light" : "dark")")
            backdropWindow.removeChildWindow(overlay)
            overlay.close()
            backdropWindow.close()
        }
        application.appearance = nil
    }
}
