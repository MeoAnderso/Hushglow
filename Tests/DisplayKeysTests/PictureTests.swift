import AppKit
import DisplayKeysCore
import Foundation
import Testing

@testable import DisplayKeys

// Tests that put windows or a menu on screen to photograph them. They run only when
// PREVIEW_DIR is set.

/// The bytes in use on the heap, over all malloc zones.
private func heapInUse() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return statistics.size_in_use
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

/// The dusk sky of the app's icon, for the picture the README shows.
private final class DuskView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        NSGradient(colors: [rgb(0x1B1D52), rgb(0x5B2A86), rgb(0xE8563C), rgb(0xFFB24A)])!.draw(in: bounds, angle: -90)
    }
}

/// How the window server is asked to take a picture; the values are CGWindowImageOption's.
private enum CaptureOption {
    static let withShadows: UInt32 = 0
    static let withoutShadows: UInt32 = 1 << 0
    static let atOnePixelPerPoint: UInt32 = 1 << 4
}

/// A picture of this process's own windows as the window server composes them, front to back.
@MainActor
private func capture(_ windows: [NSWindow], _ option: UInt32 = CaptureOption.withShadows) throws -> CGImage {
    typealias Capture = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
    let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"))
    var ids = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
    let array = try #require(CFArrayCreate(nil, &ids, ids.count, nil))
    return try #require(unsafeBitCast(symbol, to: Capture.self)(.null, array, option)?.takeRetainedValue())
}

@MainActor
private func photograph(_ windows: [NSWindow], size: NSSize, withShadows: Bool = true) throws -> NSImage {
    let option = withShadows ? CaptureOption.withShadows : CaptureOption.withoutShadows
    return NSImage(cgImage: try capture(windows, option), size: size)
}

/// A window that holds one view, to go behind what is photographed.
@MainActor
private func backdropWindow(_ frame: NSRect, _ view: NSView? = nil) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    // Windows made in code release themselves on close unless told not to.
    window.isReleasedWhenClosed = false
    window.contentView = view ?? BackdropView(frame: NSRect(origin: .zero, size: frame.size))
    return window
}

/// A clear panel, to lay parts of the app over a backdrop.
@MainActor
private func clearPanel(_ frame: NSRect) -> NSPanel {
    let panel = NSPanel(
        contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    return panel
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
            let backdropWindow = backdropWindow(frame)

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
            let backdropWindow = backdropWindow(frame)
            backdropWindow.orderFrontRegardless()
            var panels: [NSWindow] = []
            for x in [frame.minX + 40, frame.midX + 20] {
                let panel = clearPanel(NSRect(origin: NSPoint(x: x, y: frame.minY + 40), size: panelSize))
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
        var frames: [CGImage] = []
        for _ in 0..<30 {
            frames.append(try capture(windows, CaptureOption.atOnePixelPerPoint))
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
    /// An indication that is held, as for a key watch, stays until it is released; a level
    /// shown meanwhile takes its place and gives it back. Runs only when PREVIEW_DIR is set,
    /// since it shows the indicator.
    @Test func aHeldIndicationGivesWayAndComesBack() async throws {
        guard ProcessInfo.processInfo.environment["PREVIEW_DIR"] != nil else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        let osd = OSD()
        let level = Indication.level(Feedback(kind: .volume, fraction: 0.5))

        osd.hold(.watchingKeys)
        #expect(osd.shown == .watchingKeys && osd.isOnScreen)
        // Its time on screen being up does not take away what is held.
        osd.timeIsUp()
        #expect(osd.shown == .watchingKeys && osd.isOnScreen)

        osd.show(level)
        #expect(osd.shown == level)
        osd.timeIsUp()
        #expect(osd.shown == .watchingKeys && osd.isOnScreen)

        osd.release(.watchingKeys)
        try await Task.sleep(for: .milliseconds(700))
        #expect(!osd.isOnScreen)
    }

    /// Pictures of the capsules the app really builds, composited over a page by the window
    /// server. Only this process's own windows are captured. Runs only when PREVIEW_DIR is set,
    /// since it puts a window on screen for a moment.
    @Test func picturesOfEachLook() async throws {
        guard ProcessInfo.processInfo.environment["PREVIEW_DIR"] != nil else { return }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        func look(
            _ style: IndicatorSettings.Style, reducesTransparency: Bool = false, increasesContrast: Bool = false
        ) -> IndicatorLook {
            IndicatorLook(style: style, reducesTransparency: reducesTransparency, increasesContrast: increasesContrast)
        }
        let looks: [(String, IndicatorLook, Bool)] = [
            ("Glass", look(.glass), false),
            ("Glass, percentage", look(.glass), true),
            ("See-through glass", look(.seeThrough), false),
            ("Plain tint", look(.plain), false),
            ("Reduce Transparency", look(.glass, reducesTransparency: true), false),
            ("Increase Contrast", look(.glass, increasesContrast: true), false),
        ]
        let rowHeight: CGFloat = 66
        let size = NSSize(width: 1120, height: rowHeight * CGFloat(looks.count) + 20)
        let frame = NSRect(origin: NSPoint(x: 80, y: 140), size: size)

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            application.appearance = NSAppearance(named: appearance)
            let backdrop = BackdropView(frame: NSRect(origin: .zero, size: size))
            let backdropWindow = backdropWindow(frame, backdrop)
            let overlay = clearPanel(frame)
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

            let picture = try photograph([overlay, backdropWindow], size: size)
            try writePreview(picture, named: "indicator-\(appearance == .aqua ? "light" : "dark")")
            backdropWindow.removeChildWindow(overlay)
            overlay.close()
            backdropWindow.close()
        }
        application.appearance = nil
    }

    /// The picture the README shows, docs/osd-preview.png: every state of the indicator on
    /// glass, over the dusk sky of the app's icon. Runs only when PREVIEW_DIR is set.
    @Test func pictureOfEveryState() async throws {
        guard ProcessInfo.processInfo.environment["PREVIEW_DIR"] != nil else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        let states: [Indication] = [
            .level(Feedback(kind: .brightness, fraction: 0.5)), .level(Feedback(kind: .volume, fraction: 0.1875)),
            .level(Feedback(kind: .muted, fraction: 0.5)), .refused(.brightness), .unsupported(.volume), .noDisplay,
        ]
        let margin: CGFloat = 24
        let pitch = OSD.size.height + 12
        let size = NSSize(width: OSD.size.width + margin * 2, height: pitch * CGFloat(states.count) - 12 + margin * 2)
        let frame = NSRect(origin: NSPoint(x: 80, y: 140), size: size)
        let backdropWindow = backdropWindow(frame, DuskView(frame: NSRect(origin: .zero, size: size)))
        let overlay = clearPanel(frame)
        // Set on the window, not the application: other picture tests run alongside this one.
        overlay.appearance = NSAppearance(named: .darkAqua)
        let holder = NSView(frame: NSRect(origin: .zero, size: size))
        overlay.contentView = holder
        for (index, state) in states.enumerated() {
            let indicator = OSDView(frame: NSRect(origin: .zero, size: OSD.size))
            indicator.show(state, animated: false)
            let look = IndicatorLook(style: .glass, reducesTransparency: false, increasesContrast: false)
            let capsule = OSD.capsule(around: indicator, look: look)
            capsule.setFrameOrigin(NSPoint(x: margin, y: size.height - margin - pitch * CGFloat(index + 1) + 12))
            holder.addSubview(capsule)
        }
        backdropWindow.orderFrontRegardless()
        backdropWindow.addChildWindow(overlay, ordered: .above)
        overlay.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(1200))

        try writePreview(try photograph([overlay, backdropWindow], size: size), named: "indicator-states")
        backdropWindow.removeChildWindow(overlay)
        overlay.close()
        backdropWindow.close()
    }
}

// MARK: The menu as it appears on screen

/// Opens the menu's rows in a real menu and plays a drag into the brightness slider.
///
/// A drag of an NSSlider cannot be played: it looks at the real mouse button. The app's own
/// slider takes the events it is handed, so mouse events put into this process's own queue
/// go through the menu's tracking loop and the slider's, as a real drag does. They are fed a
/// few at a time, so that events waiting in the queue are not counted as memory in use.
@MainActor
private final class MenuSession: NSObject {
    let host = StubMenuHost()
    private(set) lazy var controls = MenuControls(host: host)
    private(set) var picture: NSImage?
    private(set) var menuWidth: CGFloat?
    private(set) var rowWidth: CGFloat?
    /// The most the heap grew by while the drag went on, in bytes.
    private(set) var growth = 0
    private(set) var dragEnded = false

    private let menu = NSMenu()
    private let backdrop: NSWindow
    private let events: Int
    private var ticks = 0
    private var posted = 0
    private var heapBefore = 0
    private var endedAt: Int?
    private var origin = NSPoint.zero

    init(appearance: NSAppearance.Name, events: Int) {
        self.events = events
        backdrop = backdropWindow(NSRect(x: 80, y: 260, width: 620, height: 300))
        super.init()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: appearance)
        menu.items =
            controls.items + [
                .separator(), NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ","),
                NSMenuItem(title: "Quit \(AppInfo.name)", action: nil, keyEquivalent: "q"),
            ]
        controls.update()
    }

    /// Returns when the menu has closed again.
    func run() {
        backdrop.orderFrontRegardless()
        let timer = Timer(timeInterval: 0.01, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: backdrop.frame.minX + 110, y: backdrop.frame.maxY - 30), in: nil)
        timer.invalidate()
        backdrop.close()
    }

    private func mouse(_ type: NSEvent.EventType, at x: CGFloat) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: origin.x + x, y: origin.y + 11), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controls.brightnessRow.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    }

    private func post(_ type: NSEvent.EventType, at x: CGFloat) {
        if let event = mouse(type, at: x) { NSApp.postEvent(event, atStart: false) }
    }

    @objc private func tick() {
        let row = controls.brightnessRow
        let width = row.slider.frame.width
        ticks += 1
        // The menu takes a moment to open and to settle.
        if ticks < 60 { return }
        if ticks == 60 {
            guard let window = row.window else { return menu.cancelTracking() }
            menuWidth = window.frame.width
            rowWidth = row.frame.width
            picture = try? photograph([window, backdrop], size: backdrop.frame.size, withShadows: false)
            origin = row.slider.convert(NSPoint.zero, to: nil)
            heapBefore = heapInUse()
            return post(.leftMouseDown, at: width / 2)
        }
        if let endedAt {
            if ticks == endedAt + 30 {
                dragEnded = !row.slider.isDragging
                menu.cancelTracking()
            }
            return
        }
        for _ in 0..<20 {
            posted += 1
            // Back and forth over the whole track, 200 events each way.
            let phase = Double(posted % 400) / 400
            post(.leftMouseDragged, at: CGFloat(phase < 0.5 ? phase * 2 : 2 - phase * 2) * width)
        }
        growth = max(growth, heapInUse() - heapBefore)
        if posted >= events {
            post(.leftMouseUp, at: 0)
            endedAt = ticks
        }
    }
}

@Suite struct MenuOnScreenTests {
    /// Pictures of the open menu, and a drag played into it to see what it costs. Runs only
    /// when PREVIEW_DIR is set, since it opens a menu on screen for a few seconds.
    ///
    /// It runs in a process of its own. Once a process has used AppKit's event loop, which a
    /// menu does, every event from the window server stops the main run loop to hand it over,
    /// and the test runner takes its run loop stopping to mean that the tests are over.
    @Test func aDragInTheOpenMenu() async {
        guard ProcessInfo.processInfo.environment["PREVIEW_DIR"] != nil else { return }
        await #expect(processExitsWith: .success) {
            try await MainActor.run {
                NSApplication.shared.setActivationPolicy(.accessory)
                for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                    let session = MenuSession(appearance: appearance, events: 4000)
                    session.run()
                    // A real click anywhere closes the menu, as it would for anyone.
                    guard let picture = session.picture else {
                        Issue.record("The menu was closed before it had opened; a click elsewhere does that.")
                        return
                    }
                    try writePreview(picture, named: "menu-\(appearance == .aqua ? "light" : "dark")")

                    // The rows are as wide as the menu, which the line of shortcuts can make
                    // wider than they ask for.
                    let rowWidth = try #require(session.rowWidth)
                    #expect(rowWidth == session.menuWidth)
                    // 4,000 events end where they began, at the left end, with every move passed on.
                    #expect(session.dragEnded, "the menu closed before the drag was over")
                    #expect(session.controls.brightnessRow.slider.value == 0)
                    #expect(session.host.commands.count > 3000)
                    #expect(session.host.commands.last == .set(.brightness, percent: 0))
                    #expect(session.host.leftoversThatOutlivedTheirEvent == 0)
                    #expect(session.growth < 1_048_576, "the heap grew by \(session.growth / 1024) KB during the drag")
                }
            }
        }
    }
}
