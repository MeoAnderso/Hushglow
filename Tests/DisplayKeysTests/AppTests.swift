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
        for indication in [Indication.noDisplay, .refused(.brightness), .unsupported(.volume), .watchingKeys] {
            let columns = filledColumns(try render(view(indication)))
            #expect(columns > 0 && columns < full)
        }
        try writePreviews(of: view(.watchingKeys), named: "indicator-watching")
    }

}

// MARK: Windows and menu

@MainActor
final class StubHost: SettingsHost {
    var keyboardKeysAreActive = false
    var keyboardAskingIsDisabled = false
    var refusesEverything = false
    var shortcutsUsedByMacOS: [Shortcut] = []
    var pauses = 0
    var resumes = 0
    func enableKeyboardKeys() {}
    func pauseShortcuts() { pauses += 1 }
    func resumeShortcuts() { resumes += 1 }
    func canRegister(_ shortcut: Shortcut) -> Bool { !refusesEverything }
    func previewIndicator() {}
}

@MainActor
private func keyPress(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
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
            field.keyDown(with: try keyPress(keyCode, flags))
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

    /// A field tells of the change before it stops recording: the shortcuts are put back when
    /// the recording ends, and the new one has to be stored by then.
    @Test func aFieldPassesAChangeOnBeforeItStopsRecording() throws {
        let field = ShortcutField(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        var events: [String] = []
        field.onChange = { events.append($0.map { "changed to \($0.text)" } ?? "removed") }
        field.onRecordingChange = { events.append($0 ? "recording" : "stopped") }

        field.keyDown(with: try keyPress(49))  // Space
        field.keyDown(with: try keyPress(0x7E, [.control, .option]))
        #expect(events == ["recording", "changed to ctrl+alt+up", "stopped"])

        events = []
        field.keyDown(with: try keyPress(49))
        field.keyDown(with: try keyPress(51))  // Delete
        #expect(events == ["recording", "removed", "stopped"])

        events = []
        field.keyDown(with: try keyPress(49))
        field.keyDown(with: try keyPress(53))  // Esc
        field.stopRecording()
        #expect(events == ["recording", "stopped"])
    }

    /// The shortcuts stay registered while Settings is open. They are out of the way only
    /// while a field waits for keys, and come back when it stops, however it stops.
    @Test func shortcutsArePausedOnlyWhileAFieldRecords() throws {
        let host = StubHost()
        let settings = SettingsWindow(host: host)
        let content = settings.makeContentView()
        let field = try #require(content.subviews.compactMap { $0 as? ShortcutField }.first)
        #expect(host.pauses == 0 && host.resumes == 0)

        field.keyDown(with: try keyPress(49))  // Space starts recording
        #expect(field.isRecording)
        #expect(host.pauses == 1 && host.resumes == 0)
        field.keyDown(with: try keyPress(0, [.control]))  // not a key a shortcut can use
        #expect(field.isRecording && host.resumes == 0)
        field.keyDown(with: try keyPress(53))  // Esc
        #expect(!field.isRecording)
        #expect(host.pauses == 1 && host.resumes == 1)

        // A recording must not be left waiting in a window that has gone to the back.
        field.keyDown(with: try keyPress(49))
        settings.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(!field.isRecording)
        #expect(host.pauses == 2 && host.resumes == 2)

        field.keyDown(with: try keyPress(49))
        settings.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(!field.isRecording)
        #expect(host.pauses == 3 && host.resumes == 3)
    }

    /// An open Settings window costs memory that closing alone does not give back, so the app
    /// lets go of the whole object once it has closed.
    @Test func tellsItsOwnerWhenItHasClosed() async {
        let host = StubHost()
        let settings = SettingsWindow(host: host)
        var closed = 0
        settings.onClose = { closed += 1 }
        let window = settings.makeWindow()
        #expect(settings.isOpen && closed == 0)

        window.close()
        #expect(!settings.isOpen)
        for _ in 0..<50 where closed == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(closed == 1)
    }

    @Test func restoringTheDefaultsAsksFirst() throws {
        let host = StubHost()
        let settings = SettingsWindow(host: host)
        let content = settings.makeContentView()
        var asked = 0
        settings.confirmRestore = { answer in
            asked += 1
            answer(false)
        }
        let buttons = content.subviews.compactMap { $0 as? NSButton }
        let button = try #require(buttons.first { $0.title == "Restore Defaults" })
        button.performClick(nil)
        #expect(asked == 1)
        // Restoring registers the shortcuts afresh; with the answer no, nothing was restored.
        #expect(host.resumes == 0)
    }

    @Test func readsEveryActionsShortcutFromTheSettings() {
        for action in Shortcut.Action.allCases {
            let shortcut = ShortcutSettings.text(for: action).flatMap(Shortcut.init)
            #expect(ShortcutSettings.shortcut(for: action) == shortcut)
            #expect(ShortcutSettings.shortcuts[action] == shortcut)
        }
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
            field.keyDown(with: try keyPress(keyCode, flags))
        }
        #expect(messages(in: content).first?.hasPrefix("macOS uses ⌃↑ itself.") == true)
        #expect(field.shortcut == before)
    }

    @Test func saysWhichCurrentShortcutsMacOSUses() throws {
        let host = StubHost()
        let shortcut = try #require(Shortcut.Action.allCases.compactMap(ShortcutSettings.shortcut).first)
        #expect(messages(in: SettingsWindow(host: host).makeContentView()).isEmpty)
        host.shortcutsUsedByMacOS = [shortcut]
        #expect(
            messages(in: SettingsWindow(host: host).makeContentView())
                == ["macOS uses \(shortcut.symbols) for shortcuts of its own, so it may not work here."])
    }
}

@MainActor
@Suite struct CommandLineTests {
    @Test func tellsACommandFromALaunch() {
        // The app is started with no arguments, or with settings as macOS and Xcode pass them.
        #expect(!CLI.handles([]))
        #expect(!CLI.handles(["-AppleLanguages", "(en)"]))
        #expect(!CLI.handles(["-NSDocumentRevisionsDebugMode", "YES"]))

        #expect(CLI.handles(["status"]))
        #expect(CLI.handles(["--help"]) && CLI.handles(["-h"]) && CLI.handles(["help"]))
        // A mistyped command is still a command, and must not start a second copy of the app.
        #expect(CLI.handles(["staus"]) && CLI.handles(["--version"]))
    }

    @Test func asksForHelpOrGetsItOnAMistake() {
        for help in ["help", "--help", "-h"] { #expect(CLI.run([help]) == 0) }
        #expect(CLI.run(["staus"]) == 64)
        #expect(CLI.run(["--version"]) == 64)
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
        #expect(row.slider.value == 56.4)
        #expect(row.button != nil)
        #expect(row.subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "56%")
        try writePreviews(of: row, named: "menu-row")
        row.slider.isDimmed = true
        try writePreviews(of: row, named: "menu-row-muted")
        row.slider.isDimmed = false
        row.slider.isHighContrast = true
        try writePreviews(of: row, named: "menu-row-contrast")
    }

    /// The menu is as wide as its widest item, which the line of shortcuts can make wider
    /// than a row asks for.
    @Test func aRowStretchesToTheMenusWidth() {
        let row = SliderRow(name: "Brightness", symbol: "sun.max.fill", hasButton: false)
        let label = row.subviews.compactMap { $0 as? NSTextField }[0]
        let margin = row.bounds.maxX - label.frame.maxX
        let gap = label.frame.minX - row.slider.frame.maxX
        #expect(row.autoresizingMask.contains(.width))

        row.setFrameSize(NSSize(width: 338, height: row.frame.height))
        #expect(abs(row.bounds.maxX - label.frame.maxX - margin) < 0.01)
        #expect(abs(label.frame.minX - row.slider.frame.maxX - gap) < 0.01)
        #expect(abs(row.slider.frame.width - (180 + 338 - 284)) < 0.01)
    }
}

@MainActor
@Suite struct LevelSliderTests {
    private let slider = LevelSlider(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
    /// A window that is never put on screen, so that the mouse has coordinates to be in.
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 220, height: 22), styleMask: [.borderless], backing: .buffered,
        defer: true)

    init() {
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(slider)
    }

    private func mouse(_ type: NSEvent.EventType, at x: CGFloat) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 11), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func key(_ keyCode: UInt16, _ character: Int) throws -> NSEvent {
        let characters = String(UnicodeScalar(UInt16(character)).map(Character.init) ?? " ")
        return try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// Plays a press at the first place, drags through the others and lets go.
    private func drag(_ places: [CGFloat]) throws -> [Double] {
        var values: [Double] = []
        var wasDraggingThroughout = true
        slider.onChange = { values.append($0) }
        var rest = try places.dropFirst().map { try mouse(.leftMouseDragged, at: $0) }
        rest.append(try mouse(.leftMouseUp, at: places.last ?? 0))
        slider.drag(from: try mouse(.leftMouseDown, at: places[0])) {
            wasDraggingThroughout = wasDraggingThroughout && slider.isDragging
            return rest.isEmpty ? nil : rest.removeFirst()
        }
        #expect(wasDraggingThroughout && !slider.isDragging)
        return values
    }

    /// The knob is 20 points wide and stays inside, so its centre travels from 10 to 210.
    @Test func aDragMovesTheLevelWithTheMouse() throws {
        #expect(try drag([10, 110, 160, 500, -40]) == [50, 75, 100, 0])
        #expect(slider.value == 0)
    }

    @Test func aPressOnTheTrackBringsTheKnobThere() throws {
        #expect(try drag([60]) == [25])
    }

    @Test func aPressOnTheKnobTakesItWhereItIs() throws {
        slider.show(50)
        // Taken 6 points right of its centre, the knob does not jump; it then moves as far as the mouse.
        #expect(try drag([116, 136]) == [60])
    }

    @Test func aMouseThatDoesNotMoveTheKnobChangesNothing() throws {
        slider.show(100)
        #expect(try drag([210, 300, 400, 210]).isEmpty)
    }

    @Test func theArrowKeysStepAsTheShortcutsDo() throws {
        var values: [Double] = []
        slider.onChange = { values.append($0) }
        slider.show(50)
        slider.keyDown(with: try key(0x7C, NSRightArrowFunctionKey))
        slider.keyDown(with: try key(0x7C, NSRightArrowFunctionKey))
        slider.keyDown(with: try key(0x7B, NSLeftArrowFunctionKey))
        #expect(values == [56, 63, 56])
        // A value between two steps goes to the nearest one in the direction asked for.
        slider.show(58)
        slider.keyDown(with: try key(0x7B, NSLeftArrowFunctionKey))
        #expect(slider.value == 56)
    }

    @Test func voiceOverCanReadAndChangeIt() {
        var values: [Double] = []
        slider.name = "Brightness"
        slider.onChange = { values.append($0) }
        slider.show(56.4)
        #expect(slider.isAccessibilityElement() && slider.accessibilityRole() == .slider)
        #expect(slider.accessibilityLabel() == "Brightness")
        #expect(slider.accessibilityValue() as? Double == 56.4)
        #expect(slider.accessibilityValueDescription() == "56 percent")
        #expect(slider.accessibilityMinValue() as? Double == 0 && slider.accessibilityMaxValue() as? Double == 100)

        #expect(slider.accessibilityPerformIncrement())
        #expect(slider.accessibilityPerformDecrement())
        slider.setAccessibilityValue(NSNumber(value: 140))
        #expect(values == [63, 56, 100])
    }

    @Test func aValueFromTheDisplayIsShownWithoutBeingSentBack() {
        var changes = 0
        slider.onChange = { _ in changes += 1 }
        slider.show(140)
        #expect(slider.value == 100)
        #expect(changes == 0)
    }

    /// A menu gives the focus to the first view that takes it, so the slider takes it only
    /// when the system's own controls would.
    @Test func takesTheFocusOnlyWithFullKeyboardAccess() {
        #expect(slider.acceptsFirstResponder == NSApp.isFullKeyboardAccessEnabled)
    }

    /// The reason the slider exists: what handling an event leaves in the autorelease pool goes
    /// before the next event, where NSSlider's tracking loop kept it all until the mouse was let
    /// go. Each event here leaves an object behind, and none may outlive its event.
    @Test func whatAnEventLeavesBehindGoesWithIt() throws {
        final class Leftover {}
        weak var last: Leftover?
        var outlived = 0
        var remaining = 500
        slider.drag(from: try mouse(.leftMouseDown, at: 10)) {
            if last != nil { outlived += 1 }
            let leftover = Leftover()
            last = leftover
            _ = Unmanaged.passRetained(leftover).autorelease()
            remaining -= 1
            return try? mouse(remaining > 0 ? .leftMouseDragged : .leftMouseUp, at: CGFloat(remaining % 200) + 10)
        }
        #expect(remaining == 0)
        #expect(outlived == 0)
    }
}

@MainActor
final class StubMenuHost: StatusMenuHost {
    var displayState: DisplayState?
    var displayControlIsAvailable = true
    var keyboardKeysAreActive = false
    var commands: [Command] = []
    var indicatorRequests = 0

    init(brightness: Int? = 50, volume: Int? = 30, muted: Bool = false) {
        func value(_ current: Int?) -> DDC.Value? { current.map { DDC.Value(current: $0, maximum: 100) } }
        displayState = DisplayState(
            brightness: value(brightness), volume: value(volume),
            mute: DDC.Value(current: muted ? DDC.Mute.on : DDC.Mute.off, maximum: 2))
    }

    func run(_ command: Command, showOSD: Bool) {
        commands.append(command)
        if showOSD { indicatorRequests += 1 }
        if lastLeftover != nil { leftoversThatOutlivedTheirEvent += 1 }
        let leftover = Leftover()
        lastLeftover = leftover
        _ = Unmanaged.passRetained(leftover).autorelease()
    }
    func refreshDisplays() {}
    func refreshKeyboardAccess() {}
    func enableKeyboardKeys() {}
    func showSettings() {}

    /// Each command leaves an object in the autorelease pool, as real handling does. How many
    /// were still there at the next command says whether the pool is emptied between events.
    private final class Leftover {}
    private weak var lastLeftover: Leftover?
    private(set) var leftoversThatOutlivedTheirEvent = 0
}

@MainActor
@Suite struct MenuControlsTests {
    private func label(of row: SliderRow) -> String? {
        row.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
    }

    @Test func showsWhatTheDisplayHas() {
        let host = StubMenuHost(brightness: 50, volume: nil)
        let controls = MenuControls(host: host)
        controls.update()
        #expect(label(of: controls.brightnessRow) == "50%")
        #expect(controls.brightnessRow.slider.value == 50)
        // A control the display lacks has no row.
        let hidden = controls.items.filter(\.isHidden).compactMap(\.view)
        #expect(hidden == [controls.volumeRow])

        host.displayState = nil
        controls.update()
        #expect(controls.statusLine.title == "No controllable display found")
        host.displayControlIsAvailable = false
        controls.update()
        #expect(controls.statusLine.title == "Display control is unavailable on this macOS")
    }

    @Test func aSliderSetsItsControlWithoutTheIndicator() {
        let host = StubMenuHost()
        let controls = MenuControls(host: host)
        controls.update()
        #expect(controls.brightnessRow.slider.accessibilityPerformIncrement())
        controls.volumeRow.slider.setAccessibilityValue(NSNumber(value: 41.6))
        #expect(host.commands == [.set(.brightness, percent: 56), .set(.volume, percent: 42)])
        #expect(host.indicatorRequests == 0)
        #expect(label(of: controls.brightnessRow) == "56%" && label(of: controls.volumeRow) == "42%")
    }

    @Test func theMuteButtonTogglesAndSaysWhatItWillDo() throws {
        let host = StubMenuHost()
        let controls = MenuControls(host: host)
        controls.update()
        let button = try #require(controls.volumeRow.button)
        #expect(button.accessibilityLabel() == "Mute")
        button.performClick(nil)
        #expect(host.commands == [.mute(.on)])
        #expect(button.accessibilityLabel() == "Unmute")
        button.performClick(nil)
        #expect(host.commands == [.mute(.on), .mute(.off)])
    }

    /// A refresh that arrives while the mouse is down, as when the menu is opened with the
    /// button held, brings everything up to date except the slider under the mouse.
    @Test func aRefreshLeavesOnlyTheSliderBeingDraggedAlone() throws {
        let host = StubMenuHost(brightness: 50, volume: 30)
        let controls = MenuControls(host: host)
        controls.update()
        let slider = controls.brightnessRow.slider
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let release = try mouse(.leftMouseUp)
        var valueWhileDragged: Double?

        slider.drag(from: try mouse(.leftMouseDown)) {
            let draggedTo = slider.value
            host.displayState = StubMenuHost(brightness: 80, volume: 60).displayState
            controls.update()
            valueWhileDragged = slider.value
            #expect(slider.value == draggedTo)
            return release
        }
        #expect(valueWhileDragged != 80)
        #expect(label(of: controls.volumeRow) == "60%")

        controls.update()
        #expect(slider.value == 80 && label(of: controls.brightnessRow) == "80%")
    }

    /// As with macOS's own volume slider, a muted one can still be moved, and moving it unmutes.
    @Test func movingTheVolumeSliderWhileMutedUnmutes() {
        let host = StubMenuHost(muted: true)
        let controls = MenuControls(host: host)
        controls.update()
        #expect(controls.showsMuted && controls.volumeRow.slider.isDimmed)
        #expect(controls.volumeRow.button?.accessibilityLabel() == "Unmute")

        #expect(controls.volumeRow.slider.accessibilityPerformIncrement())
        // Setting the volume is what unmutes the display; no separate command is needed.
        #expect(host.commands == [.set(.volume, percent: 31)])
        #expect(!controls.showsMuted && !controls.volumeRow.slider.isDimmed)
        #expect(controls.volumeRow.button?.accessibilityLabel() == "Mute")
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
        var reads: [DDC.Feature] = []
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
            lastReadMilliseconds: 31, memoryFootprint: 24_536_000, isWatchingKeys: false, watchedKeys: ["key f11"])
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
                readValues: { _, _ in },
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
                onCommand: { _ in }, onShortcutsChanged: {}, onKeyTest: {}, onWatchKeys: { _ in },
                readValues: { _, _ in }, status: makeStatus))
        defer { channel.stop() }

        let request = CommandClient(namespace: namespace).beginStatusRequest()
        defer { request.finish() }
        await wait { request.answer != nil }
        let status = try #require(request.answer)
        #expect(status.version == "9.9.9")
        #expect(status.build == "abc1234")
        #expect(status.brightness?.current == 61)
        #expect(status.shortcuts.first?.registered == false)
        #expect(status.lastReadMilliseconds == 31)
        #expect(status.memoryFootprint == 24_536_000)
        #expect(status.watchedKeys == ["key f11"])
    }

    @Test func theStatusReportsMemory() throws {
        // The process's own figure is real: a test process is charged far more than a megabyte.
        #expect(try #require(ProcessMemory.footprint) > 1_048_576)
        let lines = CLI.describe(makeStatus()).split(separator: "\n")
        #expect(lines.contains("Memory: 23.4 MB"))
        var older = makeStatus()
        older.memoryFootprint = nil
        #expect(!CLI.describe(older).contains("Memory"))
    }

    /// `DisplayKeys get` has the running app read the display, and gets what it answered.
    @Test func hasTheAppReadAValue() async throws {
        let received = Received()
        let channel = CommandChannel(
            namespace: namespace,
            handlers: .init(
                onCommand: { _ in }, onShortcutsChanged: {}, onKeyTest: {}, onWatchKeys: { _ in },
                readValues: { feature, answer in
                    received.reads.append(feature)
                    answer([.init(current: 13, maximum: 100)])
                }, status: makeStatus))
        defer { channel.stop() }

        let request = CommandClient(namespace: namespace).beginValueRequest(of: .volume)
        defer { request.finish() }
        await wait { request.answer != nil }
        let values = try #require(request.answer)
        #expect(received.reads == [.volume])
        #expect(values.map(\.current) == [13] && values.map(\.maximum) == [100])
    }

    @Test func waitingForAnAnswerGivesUpWhenThereIsNone() {
        let client = CommandClient(namespace: namespace)
        #expect(client.requestStatus(timeout: 0.2) == nil)
        #expect(client.requestValues(of: .brightness, timeout: 0.2) == nil)
    }
}

@MainActor
@Suite struct KeyWatchTests {
    /// The end of a watch takes the indicator's notice of it away, so only a watch that ran
    /// may report one.
    @Test func onlyAWatchThatRanReportsItsEnd() {
        let watch = KeyWatch()
        var ended = 0
        watch.onEnd = { ended += 1 }
        watch.stop()
        #expect(ended == 0 && !watch.isWatching)
    }
}
