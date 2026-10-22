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

    /// On this Mac as it is: every external display's DDC service is paired with the screen it
    /// reaches, by what its EDID says. Nothing is written to a display, and nothing read from one.
    /// The screen of a virtual machine, as on GitHub's runners, counts as external and has no
    /// DDC service, so the test is left out there.
    @Test(.disabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "No DDC on a virtual machine"))
    func everyExternalDisplayIsPairedWithItsScreen() throws {
        let io = try #require(IOAV.shared)
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let external = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
            .map { ($0, CGDisplayVendorNumber($0), CGDisplayModelNumber($0), CGDisplaySerialNumber($0)) }
        let found = io.displays()
        #expect(found.count == external.count)
        let paired = found.compactMap { $0.identity?.screen(among: external) }
        #expect(paired.count == found.count && Set(paired).count == paired.count)
    }
}

@Suite struct DisplayIdentityTests {
    private let screens: [(id: CGDirectDisplayID, vendor: UInt32, model: UInt32, serial: UInt32)] = [
        (2, 4660, 22136, 100001), (3, 4661, 22137, 16_843_009), (4, 4660, 22136, 100002),
    ]

    private func identity(_ vendor: UInt32, _ model: UInt32, _ serial: UInt32) -> DisplayIdentity {
        DisplayIdentity(vendor: vendor, model: model, serial: serial, productName: nil)
    }

    @Test func isTheScreenWithTheSameVendorModelAndSerial() {
        #expect(identity(4660, 22136, 100001).screen(among: screens) == 2)
        #expect(identity(4660, 22136, 100002).screen(among: screens) == 4)
        #expect(identity(4661, 22137, 16_843_009).screen(among: screens) == 3)
    }

    /// Some displays report no serial, or another one over DDC than macOS has. One screen of
    /// the same make is then that one; two of them could be either.
    @Test func fallsBackOnVendorAndModelOnlyWhenThatIsUnambiguous() {
        #expect(identity(4661, 22137, 0).screen(among: screens) == 3)
        #expect(identity(4660, 22136, 0).screen(among: screens) == nil)
        #expect(identity(1, 2, 3).screen(among: screens) == nil)
    }
}

@MainActor
@Suite struct UpdatesTests {
    private let key = "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="
    private let feed = "https://github.com/MeoAnderso/DisplayKeys/releases/latest/download/appcast.xml"

    /// Without the public key, Sparkle cannot tell a real update from a forged one while the
    /// app is ad-hoc signed, so the updater stays off.
    @Test func updatesNeedTheKeyAndASecureFeed() {
        #expect(Updates.areConfigured(in: ["SUPublicEDKey": key, "SUFeedURL": feed]))
        #expect(!Updates.areConfigured(in: ["SUFeedURL": feed]))
        #expect(!Updates.areConfigured(in: ["SUPublicEDKey": "", "SUFeedURL": feed]))
        #expect(!Updates.areConfigured(in: ["SUPublicEDKey": key, "SUFeedURL": "http://example.com/appcast.xml"]))
        #expect(!Updates.areConfigured(in: ["SUPublicEDKey": key]))
        #expect(!Updates.areConfigured(in: nil))
    }

    /// The feed is the latest release's appcast, which `Scripts/release.sh` uploads.
    @Test func theFeedIsTheLatestRelease() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        #expect(info["SUFeedURL"] as? String == feed)
    }

    /// The test process is not the app, and has no key: the updater does not start, so it
    /// writes nothing and asks nothing.
    @Test func doesNotStartWithoutTheKey() {
        let updates = Updates()
        updates.start()
        #expect(!updates.areAvailable)
        #expect(updates.checksAutomatically == nil)
    }

    @Test func theMenuOffersToCheckOnlyWhenThereAreUpdates() {
        let with = StatusMenu.fixedItems(target: nil, updates: true).map(\.title)
        let without = StatusMenu.fixedItems(target: nil, updates: false).map(\.title)
        #expect(with == ["", "Settings…", "Check for Updates…", "Quit \(AppInfo.name)"])
        #expect(without == ["", "Settings…", "Quit \(AppInfo.name)"])
    }

    /// The box in Settings shows only when there are updates, and passes its state on.
    @Test func settingsShowsTheBoxOnlyWhenThereAreUpdates() throws {
        let host = StubHost()
        let settings = SettingsWindow(host: host)
        let content = settings.makeContentView()
        func box() throws -> NSButton {
            try #require(
                descendants(of: content).compactMap { $0 as? NSButton }
                    .first { $0.title == "Check for updates automatically" })
        }
        #expect(try !box().isHidden && box().state == .on)
        try box().performClick(nil)
        #expect(host.checksForUpdatesAutomatically == false)

        let without = StubHost()
        without.checksForUpdatesAutomatically = nil
        let other = SettingsWindow(host: without)
        let otherContent = other.makeContentView()
        let hidden = descendants(of: otherContent).compactMap { $0 as? NSButton }
            .first { $0.title == "Check for updates automatically" }
        #expect(hidden?.isHidden == true)
        withExtendedLifetime((settings, other, host, without)) {}
    }
}

@Suite struct BundleTests {
    @Test func bundleIdentifierMatchesInfoPlist() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist))
        #expect(info["CFBundleIdentifier"] as? String == AppInfo.bundleID)
        // What Finder's Get Info and the App Store's categories show.
        #expect((info["NSHumanReadableCopyright"] as? String)?.contains("MIT") == true)
        #expect(info["LSApplicationCategoryType"] as? String == "public.app-category.utilities")
    }

    /// The catalog that translations go into has English as its source, and holds nothing the
    /// code no longer uses. That it holds everything the code uses needs the compiler to find
    /// out, which `Scripts/strings.sh` does in continuous integration.
    @Test func theStringCatalogIsCurrent() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "en")
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        #expect(strings.values.allSatisfy { $0["extractionState"] as? String != "stale" })
        // A few that the indicator, VoiceOver and the menu look up, with their placeholders.
        for key in ["No display to control", "Volume %lld percent", "Controlling %@", "Check for Updates…"] {
            #expect(strings[key] != nil, "\(key)")
        }
    }

    /// Names in a list are joined in the language of the app's text, English until it has another.
    @Test func listsAreJoinedInTheAppsLanguage() {
        #expect(ListFormatter.joinedInAppLanguage(["Rectangle", "Magnet"]) == "Rectangle and Magnet")
        #expect(ListFormatter.joinedInAppLanguage(["LG"]) == "LG")
    }

    /// Until the identifier changes there is nothing to carry over, and nothing is touched.
    @Test func settingsAreCarriedOverOnlyUnderANewIdentifier() {
        #expect(AppInfo.bundleID == SettingsCarryOver.earlierBundleID)
        #expect(!SettingsCarryOver.isNeeded)
    }

    /// Two settings suites of the tests' own stand for the earlier and the new identifier.
    @Test func carryingOverCopiesTheEarlierSettingsOnce() throws {
        let name = "local.DisplayKeys.tests.\(UUID().uuidString)"
        let current = try #require(UserDefaults(suiteName: name))
        defer { current.removePersistentDomain(forName: name) }
        current.set("ctrl+alt+f1", forKey: "shortcut.brightness-down")

        let earlier: [String: Any] = [
            "shortcut.brightness-up": "ctrl+alt+f2", "shortcut.brightness-down": "ctrl+alt+down",
            "welcomeShown": true, "indicator.style": "plain",
        ]
        #expect(SettingsCarryOver.carryOver(from: earlier, to: current) == 3)
        #expect(current.string(forKey: "shortcut.brightness-up") == "ctrl+alt+f2")
        #expect(current.bool(forKey: "welcomeShown"))
        // What the new identifier already has is its own, and stays.
        #expect(current.string(forKey: "shortcut.brightness-down") == "ctrl+alt+f1")

        // Once done, a later run copies nothing, even what has been removed since.
        current.removeObject(forKey: "indicator.style")
        #expect(SettingsCarryOver.carryOver(from: earlier, to: current) == 0)
        #expect(current.string(forKey: "indicator.style") == nil)
    }

    /// What macOS ties a permission to: the certificate, which Apple's own apps have, else the
    /// build. Nothing here is signed; signatures are only read.
    @Test func aSignatureIsTheCertificateWhereThereIsOne() throws {
        func information(at path: String) throws -> [String: Any] {
            var code: SecStaticCode?
            #expect(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess)
            let staticCode = try #require(code)
            return try #require(CodeIdentity.information(of: staticCode))
        }
        let signed = try information(at: "/System/Applications/Calculator.app")
        #expect(CodeIdentity.certificate(in: signed)?.count == 64)
        #expect(CodeIdentity.buildHash(in: signed) != nil)

        // The tests are signed by the linker, ad hoc: a build, and no certificate.
        let adHoc = try information(at: try #require(Bundle(for: StubHost.self).executablePath))
        #expect(CodeIdentity.certificate(in: adHoc) == nil)
        #expect(CodeIdentity.buildHash(in: adHoc) != nil)
    }

    /// A first install has no earlier settings; it is still marked done.
    @Test func carryingOverNothingIsDoneToo() throws {
        let name = "local.DisplayKeys.tests.\(UUID().uuidString)"
        let current = try #require(UserDefaults(suiteName: name))
        defer { current.removePersistentDomain(forName: name) }
        #expect(SettingsCarryOver.carryOver(from: nil, to: current) == 0)
        #expect(SettingsCarryOver.carryOver(from: ["welcomeShown": true], to: current) == 0)
        #expect(!current.bool(forKey: "welcomeShown"))
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

    /// The marks are layers, so there is nothing of the view's own for AppKit to call when a
    /// frame is due: the method it would call is still the one every view inherits.
    @Test func drawsNothingItself() {
        let selector = #selector(NSView.draw(_:))
        #expect(class_getInstanceMethod(OSDView.self, selector) == class_getInstanceMethod(NSView.self, selector))
    }

    /// A step is one layer changing its width, and Core Animation plays the way there, on a
    /// spring that gives a little at the end.
    @Test func aStepGlidesFromWhereTheBarWas() throws {
        let view = view(level(.brightness, 0.5))
        // The bar is 182 points: sixteen segments of 9.5 with gaps of 2. Eight end at 90.
        #expect(view.lit.bounds.width == 90)
        #expect(view.lit.animation(forKey: OSDView.glideKey) == nil)

        view.show(level(.brightness, 0.5625), animated: true)
        #expect(view.lit.bounds.width == 101.5)
        let glide = try #require(view.lit.animation(forKey: OSDView.glideKey) as? CASpringAnimation)
        #expect(glide.keyPath == "bounds.size.width")
        #expect(glide.fromValue as? CGFloat == 90 && glide.toValue as? CGFloat == 101.5)
        #expect(glide.duration == glide.settlingDuration && glide.duration < 1)

        // A step that cuts into a glide still under way settles without overshooting, so that
        // a held key moves the bar along steadily.
        view.show(level(.brightness, 0.625), animated: true)
        let next = try #require(view.lit.animation(forKey: OSDView.glideKey) as? CASpringAnimation)
        #expect(next.toValue as? CGFloat == 113)
        #expect(
            OSDView.glide(from: 0, to: 10, interrupting: true).damping
                > OSDView.glide(from: 0, to: 10, interrupting: false).damping)

        // With Reduce Motion, or when the indicator was not on screen, the bar is simply there.
        view.show(level(.brightness, 0.25), animated: false)
        #expect(view.lit.bounds.width == 44)
        #expect(view.lit.animation(forKey: OSDView.glideKey) == nil)
    }

    /// The speaker is one symbol whose waves light with the level, so that it keeps its width.
    @Test func theSpeakersWavesFollowTheLevel() {
        #expect([0, 0.1, 0.33, 0.34, 0.66, 0.67, 1].map(OSDView.litWaves) == [0, 1, 1, 2, 2, 3, 3])
        let view = view(level(.volume, 0.5))
        #expect(view.shownSymbol == "speaker.wave.3.fill@2")
        view.show(level(.volume, 0.9), animated: false)
        #expect(view.shownSymbol == "speaker.wave.3.fill@3")
        view.show(level(.volume, 0), animated: false)
        #expect(view.shownSymbol == "speaker.wave.3.fill@0")
        try? writePreviews(of: view, named: "indicator-silent")
    }

    /// Muting and unmuting on screen trade one speaker for the other with a crossfade and a
    /// pop; anything else, or with Reduce Motion, simply changes.
    @Test func mutingTradesOneSpeakerForTheOther() throws {
        let view = view(level(.volume, 0.5))
        let icon = try #require(view.layer?.sublayers?.first)
        view.show(level(.muted, 0.5), animated: true)
        #expect(view.shownSymbol == "speaker.slash.fill")
        #expect(icon.animation(forKey: OSDView.replaceKey) is CATransition)
        #expect(icon.animation(forKey: OSDView.popKey) is CASpringAnimation)

        icon.removeAllAnimations()
        view.show(level(.volume, 0.5), animated: false)
        #expect(view.shownSymbol == "speaker.wave.3.fill@2" && icon.animationKeys() == nil)

        // A level of another kind is no unmuting.
        view.show(level(.brightness, 0.5), animated: true)
        #expect(icon.animationKeys() == nil)
    }

    /// Below the display's lowest brightness the sun is a dimmer one.
    @Test func aDimmedScreenShowsADimmerSun() {
        var feedback = Feedback(kind: .brightness, fraction: 0)
        feedback.dimming = 2
        let view = view(.level(feedback))
        #expect(view.shownSymbol == "sun.min")
        view.show(level(.brightness, 0), animated: false)
        #expect(view.shownSymbol == "sun.max.fill")
        // The overlay grows darker a tenth at a time, and no darker than six tenths.
        #expect(Dimmer.opacity(for: 0) == 0 && abs(Dimmer.opacity(for: 3) - 0.3) < 0.0001)
        #expect(abs(Dimmer.opacity(for: 10) - 0.6) < 0.0001)
    }

    @Test func aLevelAfterAMessageDoesNotGlide() {
        let view = view(level(.volume, 0.25))
        view.show(.noDisplay, animated: true)
        view.show(level(.volume, 0.75), animated: true)
        #expect(view.lit.bounds.width == 136)
        #expect(view.lit.animation(forKey: OSDView.glideKey) == nil)
    }

    /// Each segment is lit by its own share, and the gaps between them count for nothing.
    @Test func aQuarterStepLightsAQuarterOfASegment() throws {
        func width(_ sixtyFourths: Double, percentage: Bool = false) -> CGFloat {
            view(level(.brightness, sixtyFourths / 64), percentage: percentage).lit.bounds.width
        }
        #expect(width(0) == 0)
        #expect(width(1) == 2.375)
        #expect(width(4) == 9.5)
        // Eight whole segments with their gaps, 92 points, and three quarters of the ninth.
        #expect(width(35) == 99.125)
        #expect(width(64) == 182)
        // Beside the percentage the segments are 7 points wide.
        #expect(width(35, percentage: true) == 77.25)
        #expect(width(64, percentage: true) == 142)
        try writePreviews(of: view(level(.brightness, 35.0 / 64), percentage: true), named: "indicator-quarter-step")
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
    func dimmingChanged() {}
    /// As a build that can update itself has it, so that the pictures show the box.
    var checksForUpdatesAutomatically: Bool? = true
}

@MainActor
private func keyPress(
    _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: keyCode))
}

/// A press of a shortcut's keys.
@MainActor
private func keyPress(_ shortcut: Shortcut, isRepeat: Bool = false) throws -> NSEvent {
    var flags: NSEvent.ModifierFlags = []
    if shortcut.modifiers.contains(.control) { flags.insert(.control) }
    if shortcut.modifiers.contains(.option) { flags.insert(.option) }
    if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
    if shortcut.modifiers.contains(.command) { flags.insert(.command) }
    return try keyPress(UInt16(shortcut.keyCode), flags, isRepeat: isRepeat)
}

/// Every view inside another, at any depth.
@MainActor
func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

@MainActor
@Suite struct SettingsWindowTests {
    @Test func hasAFieldForEveryAction() throws {
        let host = StubHost()
        let content = SettingsWindow(host: host).makeContentView()
        let fields = descendants(of: content).compactMap { $0 as? ShortcutField }
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

    /// While it waits for keys, the field shows the modifiers that are held, as they are pressed.
    @Test func aFieldShowsTheModifiersAsTheyAreHeld() throws {
        let field = ShortcutField(frame: NSRect(x: 0, y: 0, width: 196, height: 26))
        func flags(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59))
        }
        // Not recording, held keys change nothing.
        field.flagsChanged(with: try flags([.control]))
        #expect(field.shownText == "None")

        field.keyDown(with: try keyPress(49))  // Space
        #expect(field.shownText == "Press keys…")
        field.flagsChanged(with: try flags([.control]))
        #expect(field.shownText == "⌃…")
        field.flagsChanged(with: try flags([.control, .option, .command]))
        #expect(field.shownText == "⌃⌥⌘…")
        field.flagsChanged(with: try flags([]))
        #expect(field.shownText == "Press keys…")

        field.flagsChanged(with: try flags([.control, .option]))
        field.keyDown(with: try keyPress(0x77, [.control, .option]))  // End
        #expect(!field.isRecording && field.shownText == "⌃⌥End")
    }

    /// The buttons beside a field show only while the pointer is there or the field has the
    /// focus, and only when they would change something. VoiceOver finds them whenever they would.
    @Test func theButtonsBesideAFieldShowWhenTheyApply() throws {
        let control = ShortcutControl(title: "Brightness up")
        let original = try #require(Shortcut("ctrl+alt+up"))
        var pressed: [String] = []
        control.onReset = { pressed.append("reset") }
        control.onRemove = { pressed.append("remove") }
        func shown() -> [String] {
            [("reset", control.resetButton), ("remove", control.removeButton)]
                .filter { $0.1.alphaValue > 0 }.map(\.0)
        }
        control.defaultShortcut = original
        control.shortcut = original
        // The default shortcut can only be removed, and nothing shows without the pointer.
        #expect(!control.canReset && control.canRemove)
        #expect(shown().isEmpty)
        #expect(control.removeButton.isAccessibilityElement() && !control.resetButton.isAccessibilityElement())

        let event = try #require(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
        control.mouseEntered(with: event)
        #expect(shown() == ["remove"])

        control.shortcut = Shortcut("ctrl+alt+f1")
        #expect(shown() == ["reset", "remove"])
        control.setFrameSize(control.fittingSize)
        control.layoutSubtreeIfNeeded()
        try writePreviews(of: control, named: "shortcut-control-hovered")
        #expect(control.resetButton.accessibilityLabel() == "Put back the default shortcut, Control Option Up Arrow")
        control.shortcut = nil
        #expect(shown() == ["reset"] && control.removeButton.isEnabled == false)
        control.mouseExited(with: event)
        #expect(shown().isEmpty)

        // The focus shows them too, for the keyboard.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(control)
        #expect(window.makeFirstResponder(control.field))
        #expect(shown() == ["reset"])
        control.resetButton.performClick(nil)
        control.removeButton.performClick(nil)
        #expect(pressed == ["reset"])
        #expect(window.makeFirstResponder(nil))
        #expect(shown().isEmpty)
    }

    /// The line for messages takes room only while it has one, and the window follows, with its
    /// top edge where it was. No shortcut is stored on the way.
    @Test func theWindowMakesRoomForAMessageAndGivesItBack() throws {
        let host = StubHost()
        let settings = SettingsWindow(host: host)
        let window = settings.makeWindow()
        let parts = descendants(of: try #require(window.contentView))
        let content = try #require(parts.first { $0 is FittedView })
        let labels = parts.compactMap { $0 as? NSTextField }
        let message = try #require(labels.first { $0.textColor == .systemOrange || $0.textColor == .systemRed })
        let field = try #require(parts.compactMap { $0 as? ShortcutField }.first)
        let before = window.frame
        // macOS's own shortcuts are not part of this; a clash would leave a message up.
        guard message.isHidden else { return }

        field.keyDown(with: try keyPress(49))  // Space
        field.keyDown(with: try keyPress(0, [.control]))  // the A key cannot be a shortcut
        #expect(!message.isHidden && message.stringValue.hasPrefix("That key can’t be used"))
        #expect(window.frame.height > before.height && window.frame.maxY == before.maxY)
        #expect(!hasLayoutFault(content))

        field.keyDown(with: try keyPress(53))  // Esc
        field.keyDown(with: try keyPress(49))  // Space again clears the message
        #expect(message.isHidden, "\(message.stringValue)")
        #expect(window.frame == before, "\(window.frame) \(before)")
        field.stopRecording()
        window.close()
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
        let field = try #require(descendants(of: content).compactMap { $0 as? ShortcutField }.first)
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
        let buttons = descendants(of: content).compactMap { $0 as? NSButton }
        let button = try #require(buttons.first { $0.title == "Restore Defaults" })
        button.performClick(nil)
        #expect(asked == 1)
        // Restoring registers the shortcuts afresh; with the answer no, nothing was restored.
        #expect(host.resumes == 0)
    }

    /// The groups are stacks and grids, which give each part the room it needs; nothing
    /// overlaps, and the content is as tall as its parts.
    @Test func nothingOverlapsOrLeavesTheWindow() throws {
        for keysAreActive in [false, true] {
            let host = StubHost()
            host.keyboardKeysAreActive = keysAreActive
            let settings = SettingsWindow(host: host)
            let content = settings.makeContentView()
            #expect(!hasLayoutFault(content))
            #expect(content.frame.height == ceil(content.fittingSize.height))
            let restore = try #require(
                descendants(of: content).compactMap { $0 as? NSButton }.first { $0.title == "Restore Defaults" })
            let bottom = restore.convert(restore.bounds, to: content).maxY
            #expect(bottom < content.bounds.maxY && bottom > content.bounds.maxY - 40)
        }
    }

    /// Quarter steps take a modifier of the user's choosing, Cmd first. Its menu is in use only
    /// while quarter steps are on. A choice under which two actions would take the same keys is
    /// turned down in words.
    @Test func quarterStepsTakeAModifierOfTheUsersChoosing() throws {
        let host = StubHost()
        let settings = SettingsWindow(host: host)
        let content = settings.makeContentView()
        let popup = try #require(
            descendants(of: content).compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityLabel() == "Modifier for quarter steps" })
        #expect(popup.itemTitles == ["⌘ Cmd", "⇧ Shift", "⌥ Alt", "⌃ Ctrl"])
        #expect(popup.isEnabled == ShortcutSettings.quarterSteps)
        let choices = Shortcut.Modifiers.quarterStepChoices
        #expect(popup.titleOfSelectedItem?.hasSuffix(ShortcutSettings.quarterStepModifier.title ?? "?") == true)
        #expect(choices.count == popup.numberOfItems)

        let clash = (
            action: Shortcut.Action.brightnessUp, other: Shortcut.Action.volumeDown, keys: Shortcut("ctrl+alt+cmd+up")!
        )
        #expect(
            SettingsWindow.quarterStepClash(clash, modifier: .command)
                == "With Cmd added, Brightness up and Volume down would both take ⌃⌥⌘↑. Choose another modifier, "
                + "or change one of those shortcuts.")
        withExtendedLifetime((host, settings)) {}
    }

    @Test func readsEveryActionsShortcutFromTheSettings() {
        for action in Shortcut.Action.allCases {
            let shortcut = ShortcutSettings.text(for: action).flatMap(Shortcut.init)
            #expect(ShortcutSettings.shortcut(for: action) == shortcut)
            #expect(ShortcutSettings.shortcuts[action] == shortcut)
        }
    }

    private func messages(in content: NSView) -> [String] {
        descendants(of: content).compactMap { ($0 as? NSTextField)?.stringValue }.filter { $0.hasPrefix("macOS uses") }
    }

    @Test func refusesAShortcutMacOSUsesItself() throws {
        let host = StubHost()
        host.shortcutsUsedByMacOS = [try #require(Shortcut("ctrl+up"))]
        // The fields call back into the window, so it has to outlive the key presses.
        let settings = SettingsWindow(host: host)
        let content = settings.makeContentView()
        let field = try #require(descendants(of: content).compactMap { $0 as? ShortcutField }.first)
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

/// macOS holds the app's shortcuts back while its own menu is open, so they are released for
/// that time and taken from the key presses on their way to the menu.
@MainActor
@Suite struct ShortcutsInTheMenuTests {
    @Test func aKeyPressIsMatchedToItsAction() throws {
        let shortcuts: [Shortcut.Action: Shortcut] = [
            .brightnessUp: try #require(Shortcut("ctrl+alt+up")), .mute: try #require(Shortcut("f15")),
        ]
        func binding(_ text: String, quarterStep: Shortcut.Modifiers?) throws -> String? {
            Hotkeys.binding(for: try #require(Shortcut(text)), among: shortcuts, quarterStep: quarterStep)
                .map { "\($0.action.rawValue)\($0.fine ? ", fine" : "")" }
        }
        #expect(try binding("ctrl+alt+up", quarterStep: nil) == "brightness-up")
        #expect(try binding("f15", quarterStep: .command) == "mute")
        // The keys with the modifier are a quarter step only where quarter steps are switched
        // on, with that modifier, and only for an action that steps.
        #expect(try binding("ctrl+alt+cmd+up", quarterStep: .command) == "brightness-up, fine")
        #expect(try binding("ctrl+alt+shift+up", quarterStep: .shift) == "brightness-up, fine")
        #expect(try binding("ctrl+alt+shift+up", quarterStep: .command) == nil)
        #expect(try binding("ctrl+alt+cmd+up", quarterStep: nil) == nil)
        #expect(try binding("cmd+f15", quarterStep: .command) == nil)
        #expect(try binding("ctrl+alt+down", quarterStep: .command) == nil)
    }

    @Test func aKeyPressAmountsToAShortcut() throws {
        #expect(Shortcut(keyPress: try keyPress(0x7E, [.control, .option])) == Shortcut("ctrl+alt+up"))
        #expect(Shortcut(keyPress: try keyPress(0x69, [.shift, .command])) == Shortcut("shift+cmd+f13"))
        // The A key is not one a shortcut can use.
        #expect(Shortcut(keyPress: try keyPress(0, [.control])) == nil)
    }

    /// The shortcuts as this Mac has them set. The settings are only read.
    @Test func shortcutsAreTakenFromTheMenusKeysOnlyWhileItIsOpen() throws {
        let keyboard = KeyboardInput()
        var commands: [Command] = []
        keyboard.onCommand = { commands.append($0) }
        let stepping = Shortcut.Action.allCases.filter(\.repeatsWhileHeld)
        guard let action = stepping.first(where: { ShortcutSettings.shortcut(for: $0) != nil }),
            let shortcut = ShortcutSettings.shortcut(for: action)
        else { return }

        // Closed, the press is none of the menu's business: the registered shortcut answers.
        #expect(!keyboard.takeShortcut(from: try keyPress(shortcut)))
        #expect(commands.isEmpty)

        var pressed: [Shortcut.Action] = []
        keyboard.onShortcut = { pressed.append($0) }
        keyboard.menuIsOpen = true
        #expect(keyboard.takeShortcut(from: try keyPress(shortcut)))
        // A notice that is open hears of it, to light its key cap.
        #expect(pressed == [action])
        // Held, the key repeats by itself, and each repeat is a step.
        #expect(keyboard.takeShortcut(from: try keyPress(shortcut, isRepeat: true)))
        #expect(commands == [action.command(fine: false), action.command(fine: false)])
        #expect(keyboard.input.shortcutPresses == 2)

        // With the quarter-step modifier it is a quarter step where those are switched on, and
        // the menu's otherwise.
        if let quarter = shortcut.adding(ShortcutSettings.quarterStepModifier) {
            let isOn = ShortcutSettings.quarterSteps
            #expect(keyboard.takeShortcut(from: try keyPress(quarter)) == isOn)
            #expect(commands.count == (isOn ? 3 : 2))
            if isOn { #expect(commands.last == action.command(fine: true)) }
        }

        // Keys that are no shortcut stay with the menu: Down moves through its items.
        let count = commands.count
        #expect(!keyboard.takeShortcut(from: try keyPress(0x7D)))
        #expect(!keyboard.takeShortcut(from: try keyPress(0, [.control, .option])))
        #expect(commands.count == count)
    }

    /// Mute would flip back and forth for as long as its key was held.
    @Test func aHeldMuteShortcutIsTakenOnce() throws {
        guard let shortcut = ShortcutSettings.shortcut(for: .mute) else { return }
        let keyboard = KeyboardInput()
        var commands: [Command] = []
        keyboard.onCommand = { commands.append($0) }
        keyboard.menuIsOpen = true
        #expect(keyboard.takeShortcut(from: try keyPress(shortcut)))
        #expect(keyboard.takeShortcut(from: try keyPress(shortcut, isRepeat: true)))
        #expect(commands == [.mute(.toggle)])
    }
}

@MainActor
@Suite struct ShortcutRepeatTests {
    /// A held shortcut repeats as any held key does, at the pace set in System Settings.
    @Test func aHeldShortcutRepeatsAtTheKeyboardsOwnPace() {
        #expect(Hotkeys.repeatPace(delay: 0.5, interval: 0.25) == Hotkeys.RepeatPace(delay: 0.5, interval: 0.25))
        // The slowest pace System Settings offers is still a pace.
        #expect(Hotkeys.repeatPace(delay: 2, interval: 2) == Hotkeys.RepeatPace(delay: 2, interval: 2))
        // With key repeat switched off there, an interval of more than an hour is reported.
        #expect(Hotkeys.repeatPace(delay: 0.5, interval: 5000) == nil)
        // Values that no setting produces do not send a shortcut across the range in an instant.
        let shortest = Hotkeys.shortestRepeatInterval
        #expect(Hotkeys.repeatPace(delay: 0, interval: 0) == Hotkeys.RepeatPace(delay: shortest, interval: shortest))

        // Whatever this Mac is set to is taken as it is.
        let own = Hotkeys.repeatPace()
        #expect(own == Hotkeys.repeatPace(delay: NSEvent.keyRepeatDelay, interval: NSEvent.keyRepeatInterval))
        if let own { #expect(own.interval >= shortest && own.delay >= own.interval) }
    }
}

/// Whether two parts of a view overlap, or one reaches outside it, at any depth of the views
/// that only hold others. Parts are compared by the rectangles that layout lines up, which
/// leave out the room a label or a symbol keeps around what it draws. The helper's glow is
/// meant to lie under the rest.
@MainActor
private func hasLayoutFault(_ view: NSView) -> Bool {
    let parts = view.subviews.filter { !$0.isHidden && !($0 is AuraView) }
    let rects = parts.map { $0.alignmentRect(forFrame: $0.frame) }
    for (index, part) in parts.enumerated() {
        if !view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rects[index]) { return true }
        if rects[(index + 1)...].contains(where: { $0.insetBy(dx: 0.5, dy: 0.5).intersects(rects[index]) }) {
            return true
        }
        let isHolder =
            type(of: part) == NSView.self || part is FlippedView || part is FittedView || part is NSStackView
            || part is NSGridView || part is WellView
        if isHolder, hasLayoutFault(part) { return true }
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
            var expected = keysAreActive ? ["OK"] : ["Not Now", "Turn On Brightness and Volume Keys…"]
            if occasion == .update, !keysAreActive { expected.append("Ask again after updates") }
            #expect(buttons(in: content).map(\.title) == expected)
        }
    }

    @Test func nothingOverlapsOrLeavesThePanel() {
        for (occasion, keysAreActive) in Self.cases {
            let content = WelcomeWindow(onTurnOn: {}, onDontAsk: {})
                .makeContentView(occasion, keysAreActive: keysAreActive)
            #expect(descendants(of: content).count >= 8)
            #expect(!hasLayoutFault(content))
        }
    }

    /// Both occasions use the one design: the shortcuts, and the note that they can be changed.
    @Test func showsTheShortcutsOnBothOccasions() {
        for (occasion, keysAreActive) in Self.cases {
            let content = WelcomeWindow(onTurnOn: {}, onDontAsk: {})
                .makeContentView(occasion, keysAreActive: keysAreActive)
            let texts = descendants(of: content).compactMap { ($0 as? NSTextField)?.stringValue }
            #expect(texts.contains { $0.contains("You can also change them, if you want.") })
            #expect(descendants(of: content).contains { $0 is WellView })
        }
    }

    /// When a window manager has the arrows, the first launch says why the shortcuts are on the
    /// function keys, and on an Apple keyboard whose top row sends brightness and volume, that
    /// fn is needed with them.
    @Test func saysWhyTheShortcutsAreOnTheFunctionKeys() {
        #expect(WelcomeWindow.whyFunctionKeys(set: .arrows, managers: ["Rectangle"]) == nil)
        #expect(WelcomeWindow.whyFunctionKeys(set: .functionKeys, managers: []) == nil)
        #expect(
            WelcomeWindow.whyFunctionKeys(set: .functionKeys, managers: ["Rectangle"], functionKeysAreStandard: true)
                == "Rectangle uses Ctrl+Alt with the arrow keys, so these are on the function keys.")
        #expect(
            WelcomeWindow.whyFunctionKeys(
                set: .functionKeys, managers: ["Rectangle", "Magnet"], functionKeysAreStandard: false)
                == "Rectangle and Magnet use Ctrl+Alt with the arrow keys, so these are on the function keys. "
                + "On an Apple keyboard, hold fn with them.")
    }

    /// While a notice is open, pressing a shortcut lights its key cap, the quarter step's
    /// included; once it has closed, nothing lights.
    @Test func aShortcutPressedLightsItsKeyCap() throws {
        let welcome = WelcomeWindow(onTurnOn: {}, onDontAsk: {})
        let window = welcome.makeWindow(.firstLaunch, keysAreActive: false)
        let actions = Shortcut.Action.allCases.filter { ShortcutSettings.shortcut(for: $0) != nil }
        #expect(Set(welcome.keyCaps.keys) == Set(actions))
        guard let action = actions.first, let other = actions.last, other != action else { return }
        let cap = try #require(welcome.keyCaps[action])
        #expect(cap.shortcut == ShortcutSettings.shortcut(for: action))
        #expect(!cap.isLit)
        welcome.shortcutPressed(action)
        #expect(cap.isLit && welcome.keyCaps[other]?.isLit == false)

        window.close()
        welcome.shortcutPressed(other)
        #expect(welcome.keyCaps[other]?.isLit == false)
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
            let texts = descendants(of: content).compactMap { ($0 as? NSTextField)?.stringValue }
            #expect(texts.contains { $0.contains(AccessibilityAccess.listName) })
        }
    }

    /// Presses a button of the update notice, with its checkbox ticked or not, and returns what
    /// it led to, in order.
    private func press(_ title: String, askingAgain: Bool, closingWithTheCloseButton: Bool = false) throws -> [String] {
        var calls: [String] = []
        let welcome = WelcomeWindow(onTurnOn: { calls.append("turn on") }, onDontAsk: { calls.append("stop asking") })
        let window = welcome.makeWindow(.update, keysAreActive: false)
        let all = buttons(in: try #require(window.contentView))
        let box = try #require(all.first { $0.title == "Ask again after updates" })
        // Ticked to begin with, as in Settings: asking again is what happens unless it is switched off.
        #expect(box.state == .on)
        box.state = askingAgain ? .on : .off
        if closingWithTheCloseButton {
            window.close()
        } else {
            try #require(all.first { $0.title == title }).performClick(nil)
        }
        return calls
    }

    @Test func theButtonsDoWhatTheySay() throws {
        let turnOn = "Turn On Brightness and Volume Keys…"
        #expect(try press(turnOn, askingAgain: true) == ["turn on"])
        #expect(try press("Not Now", askingAgain: true) == [])
        #expect(try press("Not Now", askingAgain: false) == ["stop asking"])
        #expect(try press("", askingAgain: false, closingWithTheCloseButton: true) == ["stop asking"])
        // Asking for access turns asking back on, so an unticked checkbox has to be applied last.
        #expect(try press(turnOn, askingAgain: false) == ["turn on", "stop asking"])
    }

    /// The menu, the notices, Settings and the command line call the keyboard's own keys by one
    /// name, and the two checkboxes about asking again say the same thing.
    @Test func theKeyboardsKeysHaveOneName() throws {
        let host = StubHost()
        let settings = descendants(of: SettingsWindow(host: host).makeContentView())
        let notice = descendants(
            of: WelcomeWindow(onTurnOn: {}, onDontAsk: {}).makeContentView(.update, keysAreActive: false))
        let menu = MenuControls(host: StubMenuHost()).items.map(\.title)
        func titles(_ views: [NSView]) -> [String] {
            views.compactMap { ($0 as? NSButton)?.title ?? ($0 as? NSTextField)?.stringValue }
        }
        #expect(menu.contains("Turn On Brightness and Volume Keys…"))
        #expect(titles(notice).contains("Turn On Brightness and Volume Keys…"))
        #expect(titles(settings).contains("Brightness and volume keys"))
        #expect(
            titles(settings).contains("Ask again after updates") && titles(notice).contains("Ask again after updates"))
        for text in titles(settings) + titles(notice) + menu {
            #expect(
                !text.contains("Keyboard Keys") && !text.contains("Volume Keys…") || text.contains("Brightness and"))
            #expect(!text.lowercased().contains("don’t ask"))
        }
        let off = AppStatus(
            version: "9.9.9", build: nil, displayControlAvailable: true, brightness: nil, volume: nil, muted: false,
            accessGranted: false, askingIsDisabled: false, keyTapActive: false, soundGoesToDisplay: true,
            quarterSteps: false, shortcuts: [], input: .init(), isWatchingKeys: false)
        #expect(CLI.describe(off).contains("Brightness and Volume Keys: OFF"))
        #expect(CLI.describe(off).contains("(choose \"Turn On Brightness and Volume Keys…\" in the menu)"))
    }
}

@MainActor
@Suite struct FeedbackSoundTests {
    /// macOS keeps the sound where the app looks for it; a release that moves it is caught here.
    @Test func theSoundIsWhereMacOSKeepsIt() {
        #expect(FileManager.default.fileExists(atPath: FeedbackSound.path))
        #expect(NSSound(contentsOfFile: FeedbackSound.path, byReference: true) != nil)
    }

    /// A volume step plays it when the setting is on and sound goes to the display; nothing
    /// else does.
    @Test func playsAfterAVolumeStepOnly() {
        let volume = Feedback(kind: .volume, fraction: 0.5)
        let up = Command.step(.volume, up: true, fine: false)
        #expect(FeedbackSound.plays(after: up, feedback: volume, soundGoesToDisplay: true, isOn: true))
        #expect(!FeedbackSound.plays(after: up, feedback: volume, soundGoesToDisplay: true, isOn: false))
        #expect(!FeedbackSound.plays(after: up, feedback: volume, soundGoesToDisplay: false, isOn: true))
        #expect(
            !FeedbackSound.plays(
                after: .step(.brightness, up: true, fine: false), feedback: Feedback(kind: .brightness, fraction: 1),
                soundGoesToDisplay: true, isOn: true))
        #expect(
            !FeedbackSound.plays(
                after: .mute(.toggle), feedback: Feedback(kind: .muted, fraction: 0.5), soundGoesToDisplay: true,
                isOn: true))
        #expect(
            !FeedbackSound.plays(
                after: .set(.volume, percent: 40), feedback: volume, soundGoesToDisplay: true, isOn: true))
        // At the top of the range it still plays, as macOS's does.
        var top = Feedback(kind: .volume, fraction: 1)
        top.pushedAgainst = .top
        #expect(FeedbackSound.plays(after: up, feedback: top, soundGoesToDisplay: true, isOn: true))
    }
}

/// An open menu keeps the main run loop in its event-tracking mode. What is scheduled for the
/// default mode alone waits until the menu closes, so the app's delayed calls are scheduled for
/// every mode.
@MainActor
@Suite struct DelayedCallTests {
    @Test func accessIsReadAgainWhileAMenuIsOpen() {
        // AppKit adds the event-tracking mode to the common modes when the application is made.
        _ = NSApplication.shared
        let access = AccessibilityAccess()
        var readings = 0
        access.onChange = { readings += 1 }
        access.read(now: false)
        // The run loop as a menu runs it; the first reading comes half a second later.
        let limit = Date(timeIntervalSinceNow: 1.5)
        while readings == 0, Date() < limit {
            RunLoop.main.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.05))
        }
        #expect(readings == 1)
        NSObject.cancelPreviousPerformRequests(withTarget: access)
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
        let caption = parts.first { type(of: $0) == NSView.self && $0.subviews.first is NSStackView }
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

    /// Up and to the right are more, for the fingers and the wheel alike, whichever way the
    /// scrolling setting turns the content; the larger of the two directions counts.
    @Test func aScrollGoesTheWayTheFingersGo() {
        // Natural scrolling: fingers to the right make the delta positive, fingers up negative.
        #expect(LevelSlider.scrolled(x: 10, y: 0, isInverted: true) == 10)
        #expect(LevelSlider.scrolled(x: 0, y: -10, isInverted: true) == 10)
        // Without it, both come the other way round, as from a mouse's wheel turned away.
        #expect(LevelSlider.scrolled(x: -10, y: 0, isInverted: false) == 10)
        #expect(LevelSlider.scrolled(x: 0, y: 3, isInverted: false) == 3)
        #expect(LevelSlider.scrolled(x: 2, y: -8, isInverted: true) == 8)
        #expect(LevelSlider.scrolled(x: 0, y: 0, isInverted: true) == 0)
    }

    private func scroll(_ y: Int32, _ x: Int32 = 0, precise: Bool) throws -> NSEvent {
        let event = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2, wheel1: y, wheel2: x,
                wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        return try #require(NSEvent(cgEvent: event))
    }

    @Test func aWheelStepsAsTheKeysDoAndATrackpadFollowsTheFingers() throws {
        var values: [Double] = []
        slider.onChange = { values.append($0) }
        slider.show(50)
        let notch = try scroll(1, precise: false)
        #expect(!notch.hasPreciseScrollingDeltas)
        let up =
            LevelSlider.scrolled(
                x: notch.scrollingDeltaX, y: notch.scrollingDeltaY, isInverted: notch.isDirectionInvertedFromDevice) > 0
        slider.scrollWheel(with: notch)
        #expect(values == [up ? 56 : 44])

        // On the trackpad, the distance the fingers travel over the track: here 200 points, so
        // 20 points is a tenth of the range.
        let swipe = try scroll(20, precise: true)
        #expect(swipe.hasPreciseScrollingDeltas)
        let before = slider.value
        slider.scrollWheel(with: swipe)
        let moved = LevelSlider.scrolled(
            x: swipe.scrollingDeltaX, y: swipe.scrollingDeltaY, isInverted: swipe.isDirectionInvertedFromDevice)
        #expect(abs(slider.value - (before + Double(moved) / 200 * 100)) < 0.001)
        #expect(abs(moved) == 20)
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
    /// Stands for a display, for its identity.
    private final class Display {}
    private static let first = Display()
    static let firstID = ObjectIdentifier(first)

    var menuDisplays: [MenuDisplay] = []
    var displayControlIsAvailable = true
    var keyboardKeysAreActive = false
    var commands: [Command] = []
    /// The display each command was for; nil for every display.
    var targets: [MenuDisplay.ID?] = []
    var indicatorRequests = 0

    init(brightness: Int? = 50, volume: Int? = 30, muted: Bool = false) {
        displayState = Self.state(brightness: brightness, volume: volume, muted: muted)
    }

    static func state(brightness: Int? = 50, volume: Int? = 30, muted: Bool = false) -> DisplayState {
        func value(_ current: Int?) -> DDC.Value? { current.map { DDC.Value(current: $0, maximum: 100) } }
        return DisplayState(
            brightness: value(brightness), volume: value(volume),
            mute: DDC.Value(current: muted ? DDC.Mute.on : DDC.Mute.off, maximum: 2))
    }

    /// The first display's state; nil for no display at all.
    var displayState: DisplayState? {
        get { menuDisplays.first?.state }
        set {
            guard let newValue else {
                menuDisplays = []
                return
            }
            if menuDisplays.isEmpty {
                menuDisplays = [MenuDisplay(id: Self.firstID, name: "PANEL 27", state: newValue)]
            } else {
                menuDisplays[0].state = newValue
            }
        }
    }

    func run(_ command: Command, showOSD: Bool, on display: MenuDisplay.ID?) {
        commands.append(command)
        targets.append(display)
        if showOSD { indicatorRequests += 1 }
        if lastLeftover != nil { leftoversThatOutlivedTheirEvent += 1 }
        let leftover = Leftover()
        lastLeftover = leftover
        _ = Unmanaged.passRetained(leftover).autorelease()
    }
    func stepBrightness(up: Bool, fromMenuBarOf screen: NSScreen?) {}
    func readDisplays() {}
    func refreshKeyboardAccess() {}
    func enableKeyboardKeys() {}
    func showSettings() {}
    func menuDidChange(isOpen: Bool) {}
    var updatesAreAvailable = false
    var updateChecks = 0
    func checkForUpdates() { updateChecks += 1 }

    /// Each command leaves an object in the autorelease pool, as real handling does. How many
    /// were still there at the next command says whether the pool is emptied between events.
    private final class Leftover {}
    private weak var lastLeftover: Leftover?
    private(set) var leftoversThatOutlivedTheirEvent = 0
}

/// With several displays, each has its own rows in the menu, headed by its name, and changes
/// alone; the keys follow the pointer, and the volume the sound.
@MainActor
@Suite struct SeveralDisplaysTests {
    private final class Display {}
    private let second = Display()

    @Test func eachDisplayHasItsOwnRows() throws {
        let host = StubMenuHost(brightness: 50, volume: 30)
        let controls = MenuControls(host: host)
        controls.update()
        #expect(controls.groups.count == 1 && controls.groups[0].header.isHidden)
        #expect(controls.brightnessRow.slider.name == "Brightness")

        let secondID = ObjectIdentifier(second)
        host.menuDisplays.append(
            MenuDisplay(id: secondID, name: "PANEL 32", state: StubMenuHost.state(brightness: 80, volume: nil)))
        controls.update()
        #expect(controls.groups.count == 2)
        #expect(controls.groups.map(\.header.title) == ["PANEL 27", "PANEL 32"])
        #expect(controls.groups.allSatisfy { !$0.header.isHidden })
        #expect(controls.groups[1].brightnessRow.slider.value == 80)
        #expect(controls.groups[1].brightnessRow.slider.name == "PANEL 32 brightness")
        #expect(controls.statusLine.title == "Controlling PANEL 27 and PANEL 32")
        // The second display has no volume, so it has no volume row.
        let hidden = controls.items.filter(\.isHidden).compactMap(\.view)
        #expect(hidden.contains(controls.groups[1].volumeRow) && !hidden.contains(controls.volumeRow))
        // The menu takes every group's items, in order.
        let items = controls.items
        #expect(items.firstIndex(of: controls.groups[0].header)! < items.firstIndex(of: controls.groups[1].header)!)

        // Each display's slider changes that display alone.
        #expect(controls.groups[1].brightnessRow.slider.accessibilityPerformIncrement())
        #expect(controls.brightnessRow.slider.accessibilityPerformDecrement())
        #expect(host.targets == [secondID, StubMenuHost.firstID])
        #expect(host.commands == [.set(.brightness, percent: 81), .set(.brightness, percent: 44)])

        // Back to one display, one group without a name.
        host.menuDisplays.removeLast()
        controls.update()
        #expect(controls.groups.count == 1 && controls.groups[0].header.isHidden)
        #expect(controls.statusLine.title == "Controlling PANEL 27")
    }

    /// The keys change the display under the pointer, and the volume the display the sound
    /// plays through; with one display, or set to change every display, they change all.
    /// A display with contrast and inputs has a contrast row and its inputs in a submenu, the
    /// one it shows ticked; choosing another switches that display alone.
    @Test func contrastAndInputsArePerDisplay() throws {
        let host = StubMenuHost()
        host.displayState = DisplayState(
            brightness: DDC.Value(current: 50, maximum: 100), volume: nil, mute: nil,
            contrast: DDC.Value(current: 70, maximum: 100), input: DDC.Value(current: 0x11, maximum: 0x1B))
        let controls = MenuControls(host: host)
        controls.update()
        let rows = controls.groups[0]
        #expect(rows.contrastRow.slider.value == 70)
        #expect(!controls.items.filter(\.isHidden).compactMap(\.view).contains(rows.contrastRow))
        #expect(!rows.inputItem.isHidden && rows.inputItem.title == "Input: HDMI 1")
        let inputs = try #require(rows.inputItem.submenu?.items)
        #expect(inputs.map(\.title) == ["DisplayPort 1", "DisplayPort 2", "HDMI 1", "HDMI 2", "USB-C"])
        #expect(inputs.filter { $0.state == .on }.map(\.title) == ["HDMI 1"])

        let usbC = try #require(inputs.last)
        _ = usbC.target?.perform(usbC.action, with: usbC)
        #expect(rows.contrastRow.slider.accessibilityPerformIncrement())
        #expect(host.commands == [.input(.usbC), .set(.contrast, percent: 75)])
        #expect(host.targets == [StubMenuHost.firstID, StubMenuHost.firstID])
    }

    /// A scroll over the menu bar icon steps the brightness: a wheel a step a notch, a trackpad
    /// a step for every twelve points the fingers travel, with the rest kept.
    @Test func aScrollOverTheIconStepsTheBrightness() {
        var wheel = ScrollSteps()
        #expect(wheel.steps(for: 3, isPrecise: false) == 1 && wheel.steps(for: -1, isPrecise: false) == -1)
        #expect(wheel.steps(for: 0, isPrecise: false) == 0)
        var trackpad = ScrollSteps()
        #expect(trackpad.steps(for: 5, isPrecise: true) == 0)
        #expect(trackpad.steps(for: 8, isPrecise: true) == 1)
        #expect(trackpad.steps(for: 30, isPrecise: true) == 2)
        #expect(trackpad.steps(for: -10, isPrecise: true) == 0)
        #expect(trackpad.steps(for: -13, isPrecise: true) == -1)
    }

    @Test func theKeysFollowThePointerAndTheSound() {
        func targets(
            _ control: Command.Control, _ setting: ControlSettings.Target = .pointer, count: Int = 2,
            sound: String? = "sound", pointer: String? = "pointer"
        ) -> [String]? {
            AppDelegate.keyTargets(
                for: control, setting: setting, count: count, soundDisplay: sound, displayUnderPointer: pointer)
        }
        #expect(targets(.brightness) == ["pointer"])
        #expect(targets(.volume) == ["sound"])
        // Sound that plays through no display under control: the display under the pointer.
        #expect(targets(.volume, sound: nil) == ["pointer"])
        // The pointer on a screen that is not under control: every display.
        #expect(targets(.brightness, pointer: nil) == nil)
        #expect(targets(.brightness, .every) == nil && targets(.volume, .every) == nil)
        #expect(targets(.brightness, count: 1) == nil)
    }

    @Test func theCommandLineNamesADisplayByNumber() {
        #expect(CLI.displayOption(in: ["set", "brightness", "50"])?.display == nil)
        let option = CLI.displayOption(in: ["set", "brightness", "50", "--display", "2"])
        #expect(option?.arguments == ["set", "brightness", "50"] && option?.display == 2)
        #expect(CLI.displayOption(in: ["mute", "--display", "1", "on"])?.arguments == ["mute", "on"])
        for bad in [["mute", "--display"], ["mute", "--display", "0"], ["mute", "--display", "two"]] {
            #expect(CLI.displayOption(in: bad) == nil)
        }
    }

    @Test func statusListsEveryDisplayByNumber() {
        var status = AppStatus(
            version: "9.9.9", build: nil, displayControlAvailable: true, brightness: .init(current: 41, maximum: 100),
            volume: .init(current: 6, maximum: 100), muted: false, accessGranted: true, askingIsDisabled: false,
            keyTapActive: true, soundGoesToDisplay: true, quarterSteps: false, shortcuts: [], input: .init(),
            isWatchingKeys: false)
        #expect(CLI.describe(status).contains("Display: brightness 41/100, volume 6/100, mute off"))
        status.displays = [
            .init(
                name: "PANEL 27", brightness: .init(current: 41, maximum: 100),
                volume: .init(current: 6, maximum: 100), muted: false),
            .init(name: "PANEL 32", brightness: .init(current: 80, maximum: 100), volume: nil, muted: false),
        ]
        let text = CLI.describe(status)
        #expect(text.contains("Display 1, PANEL 27: brightness 41/100, volume 6/100, mute off"))
        #expect(text.contains("Display 2, PANEL 32: brightness 80/100, volume not supported, mute off"))
        status.displays?[1].contrast = .init(current: 75, maximum: 100)
        status.displays?[1].input = 0x11
        #expect(CLI.describe(status).contains("mute off, contrast 75/100, input HDMI 1"))
    }
}

@MainActor
@Suite struct MenuBarIconTests {
    /// For a muted display the sun has a crossed-out speaker in its corner; both are templates
    /// of one size, so the menu bar gives them its colour and nothing moves.
    @Test func showsAMutedDisplay() throws {
        let plain = StatusMenu.icon(muted: false)
        let muted = StatusMenu.icon(muted: true)
        #expect(plain.isTemplate && muted.isTemplate && plain.size == muted.size)
        #expect(muted.accessibilityDescription == "DisplayKeys, display muted")

        func inked(_ image: NSImage) throws -> [Bool] {
            let scale: CGFloat = 4
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                    pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            return (0..<bitmap.pixelsHigh).flatMap { y in
                (0..<bitmap.pixelsWide).map { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
            }
        }
        let plainInk = try inked(plain)
        let mutedInk = try inked(muted)
        #expect(zip(plainInk, mutedInk).filter { $0 != $1 }.count > 20)
        // Large enough to look at.
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 96, height: 48))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = muted
        try writePreviews(of: view, named: "menu-bar-icon-muted")
    }
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
        // Nor has a display without contrast a contrast row.
        #expect(hidden == [controls.volumeRow, controls.groups[0].contrastRow])
        #expect(controls.groups[0].inputItem.isHidden)

        // The display under control is named, which need not be the first screen.
        #expect(controls.statusLine.title == "Controlling PANEL 27")
        // And the version, which nothing else in the interface shows.
        #expect(controls.items.contains { $0.title == "DisplayKeys \(AppInfo.version)" && !$0.isEnabled })

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

    /// A key pressed while the menu is open changes the display, and the menu has to show it.
    /// A closed menu need not: it is brought up to date when it opens.
    @Test func rowsOnScreenFollowALevelChangedElsewhere() {
        let host = StubMenuHost(brightness: 50, volume: 30)
        let controls = MenuControls(host: host)
        controls.update()

        host.displayState = StubMenuHost(brightness: 80, volume: 60, muted: true).displayState
        controls.levelsChanged()
        #expect(label(of: controls.brightnessRow) == "50%" && label(of: controls.volumeRow) == "30%")

        // In a window, as the rows of an open menu are.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(controls.volumeRow)
        controls.levelsChanged()
        #expect(label(of: controls.brightnessRow) == "80%" && label(of: controls.volumeRow) == "60%")
        #expect(controls.volumeRow.slider.value == 60)
        #expect(controls.showsMuted && controls.volumeRow.button?.accessibilityLabel() == "Unmute")
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
    /// A channel of the tests' own, so that they never reach an installed copy of the app. The
    /// name is short, since a socket's path has room for about a hundred bytes.
    private let name = "dk-test-\(UUID().uuidString.prefix(8))"

    @MainActor
    private final class Received {
        var commands: [Command] = []
        var shortcutChanges = 0
        var keyTests = 0
        var watches: [TimeInterval] = []
        var reads: [DDC.Feature] = []
        var displays: [Int?] = []
    }

    private func makeStatus() -> AppStatus {
        AppStatus(
            version: "9.9.9", build: "abc1234", displayControlAvailable: true,
            brightness: .init(current: 61, maximum: 100), volume: nil, muted: false, accessGranted: true,
            askingIsDisabled: false, keyTapActive: true, soundGoesToDisplay: true, quarterSteps: false,
            shortcuts: [.init(action: "mute", keys: "ctrl+alt+end", registered: false, usedByMacOS: true)],
            input: .init(),
            lastReadMilliseconds: 31, lastReadValues: 1, memoryFootprint: 24_536_000, isWatchingKeys: false,
            watchedKeys: ["key f11"])
    }

    @MainActor
    private func makeChannel(
        _ received: Received = Received(), requirement: CallerRequirement? = .own
    ) throws -> CommandChannel {
        try #require(
            CommandChannel(
                name: name, requirement: requirement,
                handlers: .init(
                    onCommand: { command, display in
                        received.commands.append(command)
                        received.displays.append(display)
                    },
                    onShortcutsChanged: { received.shortcutChanges += 1 },
                    onKeyTest: { received.keyTests += 1 },
                    onWatchKeys: { received.watches.append($0) },
                    readValues: { feature, answer in
                        received.reads.append(feature)
                        answer([.init(current: 13, maximum: 100)])
                    },
                    status: makeStatus)))
    }

    /// The app answers on the main thread, so the asking is done on another, as the command
    /// line, in a process of its own, does. The on-screen tests that run beside these can keep
    /// the main thread for seconds, as they do on GitHub's runners, so the wait is far longer
    /// than the command line's.
    nonisolated private static let patience: TimeInterval = 30

    private func ask(_ request: ChannelRequest, timeout: TimeInterval = patience) async -> ChannelReply? {
        let client = CommandClient(name: name)
        return await Task.detached { client.ask(request, timeout: timeout) }.value
    }

    @MainActor
    @Test func carriesEveryMessageToTheApp() async throws {
        let received = Received()
        let channel = try makeChannel(received)
        defer { channel.stop() }

        #expect(await ask(.command(.step(.volume, up: true, fine: true)))?.refusal == nil)
        #expect(await ask(.command(.mute(.off), display: 2)) != nil)
        #expect(await ask(.keyTest) != nil)
        #expect(await ask(.watchKeys(seconds: 10)) != nil)
        // Registering the shortcuts again is answered with what became of them.
        #expect(await ask(.shortcutsChanged)?.status?.shortcuts.first?.keys == "ctrl+alt+end")

        #expect(received.commands == [.step(.volume, up: true, fine: true), .mute(.off)])
        // A command for one display carries its number; one for every display, none.
        #expect(received.displays == [nil, 2])
        #expect(received.shortcutChanges == 1)
        #expect(received.keyTests == 1)
        #expect(received.watches == [10])
    }

    @MainActor
    @Test func turnsDownWhatIsNoRequest() async throws {
        let received = Received()
        let channel = try makeChannel(received)
        defer { channel.stop() }
        #expect(await ask(ChannelRequest(kind: .command, words: ["step", "loudness", "up"]))?.refusal != nil)
        #expect(await ask(.watchKeys(seconds: 600))?.refusal != nil)
        #expect(await ask(ChannelRequest(kind: .values, feature: "colour"))?.refusal != nil)
        #expect(received.commands.isEmpty && received.watches.isEmpty && received.reads.isEmpty)
    }

    @MainActor
    @Test func returnsTheAppsStatus() async throws {
        let channel = try makeChannel()
        defer { channel.stop() }
        let status = try #require(await ask(.status)?.status)
        #expect(status.version == "9.9.9")
        #expect(status.build == "abc1234")
        #expect(status.brightness?.current == 61)
        #expect(status.shortcuts.first?.registered == false)
        #expect(status.lastReadMilliseconds == 31)
        #expect(status.memoryFootprint == 24_536_000)
        #expect(status.watchedKeys == ["key f11"])
    }

    /// `DisplayKeys get` has the running app read the display, and gets what it answered.
    @MainActor
    @Test func hasTheAppReadAValue() async throws {
        let received = Received()
        let channel = try makeChannel(received)
        defer { channel.stop() }
        let values = try #require(await ask(.values(of: .volume))?.values)
        #expect(received.reads == [.volume])
        #expect(values.map(\.current) == [13] && values.map(\.maximum) == [100])
    }

    /// The command line is the app's own executable, so it meets the app's own requirement;
    /// a caller that does not is told why, and nothing it asked for is done.
    @MainActor
    @Test func answersOnlyACallerThatMeetsTheRequirement() async throws {
        let received = Received()
        let channel = try makeChannel(received, requirement: CallerRequirement(#"identifier "com.example.other""#))
        defer { channel.stop() }
        let reply = await ask(.command(.mute(.on)))
        #expect(reply?.refusal == CommandChannel.notTheApp)
        #expect(await ask(.status)?.status == nil)
        #expect(received.commands.isEmpty)
    }

    /// Another program on the Mac, here the system's own `nc`, is turned down by a channel
    /// that answers the tests' own process.
    @MainActor
    @Test func anotherProgramIsTurnedDown() async throws {
        let received = Received()
        let channel = try makeChannel(received)
        defer { channel.stop() }
        let reply = try JSONDecoder().decode(ChannelReply.self, from: await askThroughNC(channel.path))
        #expect(reply.refusal == CommandChannel.notTheApp)
        #expect(received.commands.isEmpty)
    }

    /// A process of its own is answered when its signature meets the requirement, as the
    /// command line meets the app's: here `nc` with a channel that asks for `nc`'s signature.
    @MainActor
    @Test func aProgramThatMeetsTheRequirementIsAnswered() async throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        #expect(SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/usr/bin/nc") as CFURL, [], &code) == errSecSuccess)
        let nc = try #require(code)
        #expect(SecCodeCopyDesignatedRequirement(nc, [], &requirement) == errSecSuccess)
        let received = Received()
        let channel = try makeChannel(received, requirement: CallerRequirement(requirement: try #require(requirement)))
        defer { channel.stop() }
        let reply = try JSONDecoder().decode(ChannelReply.self, from: await askThroughNC(channel.path))
        #expect(reply.refusal == nil)
        #expect(received.commands == [.mute(.on)])
    }

    /// Sends a request to mute through `nc`, and returns what came back.
    private func askThroughNC(_ path: String) async -> Data {
        await Task.detached { () -> Data in
            let nc = Process()
            nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            nc.arguments = ["-U", "-w", String(Int(Self.patience)), path]
            let input = Pipe()
            let output = Pipe()
            nc.standardInput = input
            nc.standardOutput = output
            guard (try? nc.run()) != nil else { return Data() }
            let request = try? JSONEncoder().encode(ChannelRequest.command(.mute(.on)))
            input.fileHandleForWriting.write((request ?? Data()) + Data("\n".utf8))
            let answer = output.fileHandleForReading.readDataToEndOfFile()
            try? input.fileHandleForWriting.close()
            nc.waitUntilExit()
            return answer
        }.value
    }

    /// Only this user can open the socket, and it goes when the channel stops.
    @MainActor
    @Test func theSocketIsTheUsersAlone() throws {
        let channel = try makeChannel()
        var info = stat()
        #expect(stat(channel.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == getuid())
        channel.stop()
        #expect(!FileManager.default.fileExists(atPath: channel.path))
    }

    @Test func waitingForAnAnswerGivesUpWhenThereIsNone() async {
        #expect(await ask(.status, timeout: 0.2) == nil)
        #expect(CommandClient(name: name).requestStatus(timeout: 0.2) == nil)
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

    /// The menu reads three values at once where a key press reads one, so the time a read
    /// took is reported with the number of values it was for.
    @Test func theStatusSaysHowManyValuesTheLastReadWasFor() {
        var status = makeStatus()
        #expect(CLI.describe(status).split(separator: "\n").contains("Last read of the display: 31 ms for 1 value"))
        status.lastReadMilliseconds = 92
        status.lastReadValues = 3
        #expect(CLI.describe(status).split(separator: "\n").contains("Last read of the display: 92 ms for 3 values"))
        status.lastReadValues = nil
        #expect(CLI.describe(status).split(separator: "\n").contains("Last read of the display: 92 ms"))
    }
}

// MARK: The keyboard's own keys

@MainActor
@Suite struct KeyRouterTests {
    @MainActor
    private final class Told {
        var keys: [MediaKeyEvent.Key] = []
        var decisions: [KeyRouting.Decision] = []
        var disabled = 0
    }

    private let told = Told()
    private let router: KeyRouter

    init() {
        let told = told
        router = KeyRouter(
            handler: { event, decision in
                told.keys.append(event.key)
                told.decisions.append(decision)
            }, onDisabled: { told.disabled += 1 })
    }

    /// `NSEvent.data1` for a key: 0 and 1 are the volume keys, 2 and 3 brightness, 7 mute.
    private nonisolated static func data(_ code: Int, isDown: Bool = true, isRepeat: Bool = false) -> Int {
        code << 16 | (isDown ? 0xA : 0xB) << 8 | (isRepeat ? 1 : 0)
    }

    private func context(soundGoesToDisplay: Bool = true) -> KeyRouting.Context {
        KeyRouting.Context(
            hasBrightness: true, hasVolume: true, soundGoesToDisplay: soundGoesToDisplay, mainDisplayIsBuiltIn: false)
    }

    /// Has the router decide about events on a thread that is not the main one, as the tap's is.
    private func route(_ events: [(data1: Int, fine: Bool)], subtype: Int = AuxiliaryKey.eventSubtype) async -> [Bool] {
        let router = router
        let answers = await Task.detached {
            events.map { router.route(subtype: subtype, data1: $0.data1, fine: $0.fine) }
        }.value
        // What the router sent to the main thread arrives before anything sent after it.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        return answers
    }

    @Test func decidesWithoutTheMainThreadAndTellsItAfterwards() async {
        router.context = context()
        let answers = await route([
            (Self.data(0), true), (Self.data(0, isDown: false), false), (Self.data(3), false),
            (Self.data(7), false), (Self.data(7, isRepeat: true), false),
        ])
        // Every one is a key of the display's, and none of them reaches macOS.
        #expect(answers == [true, true, true, true, true])
        // The main thread hears of the presses in the order they came, not of the release.
        #expect(told.keys == [.volumeUp, .brightnessDown, .mute, .mute])
        #expect(
            told.decisions == [
                .run(.step(.volume, up: true, fine: true)), .run(.step(.brightness, up: false, fine: false)),
                .run(.mute(.toggle)), .swallow,
            ])
    }

    @Test func leavesToMacOSWhatIsNotTheDisplays() async {
        router.context = context(soundGoesToDisplay: false)
        // A volume key while sound goes elsewhere, a playback key, and an event that is no key.
        let keys = await route([(Self.data(0), false), (Self.data(16), false)])
        let other = await route([(Self.data(0), false)], subtype: 7)
        #expect(keys == [false, false] && other == [false])
        // The volume key is still counted, as one left to macOS.
        #expect(told.keys == [.volumeUp] && told.decisions == [.passThrough])
    }

    /// The tap's thread works from a copy, which counts from the moment it is replaced.
    @Test func decidesFromTheContextItWasLastGiven() async {
        #expect(await route([(Self.data(0), false)]) == [false])
        #expect(told.keys.isEmpty)

        router.context = context()
        #expect(router.context?.soundGoesToDisplay == true)
        #expect(await route([(Self.data(0), false)]) == [true])

        router.context = context(soundGoesToDisplay: false)
        #expect(await route([(Self.data(0), false)]) == [false])
        router.context = nil
        #expect(await route([(Self.data(2), false)]) == [false])
        #expect(told.decisions == [.run(.step(.volume, up: true, fine: false)), .passThrough])
    }

    @Test func passesOnThatMacOSSwitchedTheTapOff() async {
        let router = router
        await Task.detached { router.tapWasDisabled() }.value
        _ = await route([])
        #expect(told.disabled == 1)
    }
}

@Suite struct RunLoopThreadTests {
    /// Stands in for a tap: a run loop source that notes on which thread it was served.
    private final class Probe: @unchecked Sendable {
        let wasServed = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var runLoop: CFRunLoop?
        private var servedOnMainThread: Bool?

        var scheduledOn: CFRunLoop? {
            get { lock.withLock { runLoop } }
            set { lock.withLock { runLoop = newValue } }
        }

        var wasServedOnMainThread: Bool? {
            get { lock.withLock { servedOnMainThread } }
            set { lock.withLock { servedOnMainThread = newValue } }
        }
    }

    private static func source(for probe: Probe) -> CFRunLoopSource {
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(probe).toOpaque()
        context.schedule = { info, runLoop, _ in
            guard let info else { return }
            Unmanaged<Probe>.fromOpaque(info).takeUnretainedValue().scheduledOn = runLoop
        }
        context.perform = { info in
            guard let info else { return }
            let probe = Unmanaged<Probe>.fromOpaque(info).takeUnretainedValue()
            probe.wasServedOnMainThread = Thread.isMainThread
            probe.wasServed.signal()
        }
        return CFRunLoopSourceCreate(nil, 0, &context)
    }

    /// The thread serves its source away from the main thread, keeps what the source's
    /// callback works with, and ends when the source is taken away.
    @Test func servesItsSourceOnItsOwnUntilItIsStopped() throws {
        weak var kept: Probe?
        let source: CFRunLoopSource
        let thread: RunLoopThread
        do {
            let probe = Probe()
            kept = probe
            source = Self.source(for: probe)
            thread = RunLoopThread(serving: source, keeping: probe, name: "Test")
        }
        thread.startServing()
        #expect(thread.isExecuting)
        // Nothing here holds the probe any more; the thread does.
        let probe = try #require(kept)
        let runLoop = try #require(probe.scheduledOn)

        CFRunLoopSourceSignal(source)
        CFRunLoopWakeUp(runLoop)
        #expect(probe.wasServed.wait(timeout: .now() + 2) == .success)
        #expect(probe.wasServedOnMainThread == false)

        thread.stopServing()
        for _ in 0..<400 where !thread.isFinished { Thread.sleep(forTimeInterval: 0.005) }
        #expect(thread.isFinished)
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
