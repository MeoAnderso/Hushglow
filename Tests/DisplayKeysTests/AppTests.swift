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

@MainActor
@Suite struct OSDViewTests {
    private static let barStartFraction = 50.0 / 250.0

    private func render(_ feedback: Feedback) throws -> NSBitmapImageRep {
        let view = OSDView(frame: NSRect(origin: .zero, size: OSD.size))
        view.feedback = feedback
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Columns of the level bar that are filled, sampled along its centre line.
    private func filledColumns(_ bitmap: NSBitmapImageRep) -> Int {
        let start = Int(Double(bitmap.pixelsWide) * Self.barStartFraction)
        return (start..<bitmap.pixelsWide).count { column in
            (bitmap.colorAt(x: column, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.8
        }
    }

    @Test func barFillFollowsTheLevel() throws {
        let empty = filledColumns(try render(Feedback(kind: .brightness, fraction: 0)))
        let half = filledColumns(try render(Feedback(kind: .brightness, fraction: 0.5)))
        let full = filledColumns(try render(Feedback(kind: .brightness, fraction: 1)))
        #expect(empty == 0)
        #expect(full > 100)
        #expect(abs(half * 2 - full) <= full / 10)
    }

    @Test func mutedBarIsDimmed() throws {
        #expect(filledColumns(try render(Feedback(kind: .muted, fraction: 1))) == 0)
    }

    /// Writes previews for visual review when OSD_PREVIEW_DIR is set; does nothing otherwise.
    @Test func writesPreviews() throws {
        guard let directory = ProcessInfo.processInfo.environment["OSD_PREVIEW_DIR"] else { return }
        let samples: [(String, Feedback)] = [
            ("brightness-50", Feedback(kind: .brightness, fraction: 0.5)),
            ("volume-19", Feedback(kind: .volume, fraction: 0.19)),
            ("volume-fine", Feedback(kind: .volume, fraction: 0.7031)),
            ("muted", Feedback(kind: .muted, fraction: 0.5)),
        ]
        let scale: CGFloat = 3
        let sheet = NSImage(
            size: NSSize(width: OSD.size.width + 24, height: (OSD.size.height + 12) * CGFloat(samples.count) + 12))
        sheet.lockFocus()
        NSColor(white: 0.45, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (index, sample) in samples.enumerated() {
            let frame = NSRect(
                x: 12, y: 12 + CGFloat(samples.count - 1 - index) * (OSD.size.height + 12),
                width: OSD.size.width, height: OSD.size.height
            )
            NSColor(white: 0.12, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
            try render(sample.1).draw(
                in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        sheet.unlockFocus()

        let pixels = NSSize(width: sheet.size.width * scale, height: sheet.size.height * scale)
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0
            ))
        bitmap.size = sheet.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        sheet.draw(in: NSRect(origin: .zero, size: sheet.size))
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("osd-preview.png"))
    }
}
