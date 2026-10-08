import AppKit
import Foundation
import Testing

// Pictures for review. They are written only when PREVIEW_DIR names a folder to write them to.

/// Writes an image for visual review when PREVIEW_DIR is set; does nothing otherwise.
@MainActor
func writePreview(_ image: NSImage, named name: String) throws {
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
func picture(of view: NSView, in name: NSAppearance.Name) throws -> NSImage {
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
func writePreviews(of view: NSView, named name: String) throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        try writePreview(
            try picture(of: view, in: appearance), named: "\(name)-\(appearance == .aqua ? "light" : "dark")")
    }
}
