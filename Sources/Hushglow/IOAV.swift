import AppKit
import Foundation
import HushglowCore
import IOKit

/// What a display's EDID says it is, as macOS keeps it for the display's framebuffer. The
/// numbers are the ones Core Graphics reports for a screen, so they tell which screen it is.
struct DisplayIdentity: Equatable, Sendable {
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    /// The name in the EDID, such as "PANEL 27".
    var productName: String?

    /// From a framebuffer's registry entry; nil when nothing is connected to it.
    init?(framebuffer entry: io_registry_entry_t) {
        guard
            let attributes = IORegistryEntryCreateCFProperty(
                entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
            let product = attributes["ProductAttributes"] as? [String: Any],
            let vendor = product["LegacyManufacturerID"] as? Int, let model = product["ProductID"] as? Int
        else { return nil }
        self.init(
            vendor: UInt32(truncatingIfNeeded: vendor), model: UInt32(truncatingIfNeeded: model),
            serial: UInt32(truncatingIfNeeded: product["SerialNumber"] as? Int ?? 0),
            productName: product["ProductName"] as? String)
    }

    init(vendor: UInt32, model: UInt32, serial: UInt32, productName: String?) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.productName = productName
    }

    /// The screen this display is, among those given: the one with the same vendor, model and
    /// serial number, or with the same vendor and model when the serial says nothing. Two
    /// screens that fit equally, as two of one model whose EDID has no serial or the same one,
    /// could be either, and the answer is nil: a wrong screen would send the keys, the
    /// indicator and the dimming to the other display.
    func screen(
        among screens: [(id: CGDirectDisplayID, vendor: UInt32, model: UInt32, serial: UInt32)]
    )
        -> CGDirectDisplayID?
    {
        let same = screens.filter { $0.vendor == vendor && $0.model == model }
        let exact = same.filter { $0.serial == serial }
        if exact.count == 1 { return exact[0].id }
        return exact.isEmpty && same.count == 1 ? same[0].id : nil
    }

    /// The screen this display is; nil when none matches.
    @MainActor var screen: NSScreen? {
        let screens = NSScreen.screens.compactMap { screen in screen.number.map { (screen, $0) } }
        let id = screen(
            among: screens.map {
                ($0.1, CGDisplayVendorNumber($0.1), CGDisplayModelNumber($0.1), CGDisplaySerialNumber($0.1))
            })
        return screens.first { $0.1 == id }?.0
    }

    /// The name macOS shows for this display, as in System Settings; the EDID's name when no
    /// screen matches.
    @MainActor var name: String? {
        screen?.localizedName ?? productName
    }

    /// Whether this is the display a sound output of this name plays through. macOS names a
    /// display's sound output after the display.
    @MainActor func playsSound(named output: String) -> Bool {
        [name, productName].contains { $0?.caseInsensitiveCompare(output) == .orderedSame }
    }
}

extension NSScreen {
    /// The screen's display, as Core Graphics numbers it.
    var number: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// A retained IOAVService reference for one external display.
final class AVService: @unchecked Sendable {
    fileprivate let reference: UnsafeMutableRawPointer
    /// Which display this is; nil when the registry did not say.
    let identity: DisplayIdentity?
    /// Whether the display has shown that it needs the long waits. Only touched on the queue
    /// that talks to the display.
    fileprivate var pace = DDC.Pace()

    fileprivate init(reference: UnsafeMutableRawPointer, identity: DisplayIdentity?) {
        self.reference = reference
        self.identity = identity
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(reference).release()
    }
}

/// DDC/CI transport over the private IOAVService I2C functions in IOKit.
///
/// Apple Silicon has no public DDC API. The symbols are resolved at runtime so that a macOS
/// release that removes them leaves the app running with no displays instead of failing to launch.
struct IOAV: DisplayTransport {
    private typealias CreateWithService = @convention(c) (UnsafeRawPointer?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias ReadI2C =
        @convention(c) (
            UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32
        ) -> IOReturn
    private typealias WriteI2C =
        @convention(c) (
            UnsafeMutableRawPointer, UInt32, UInt32, UnsafeRawPointer, UInt32
        ) -> IOReturn

    /// The pauses around a request. Displays differ in how long they need: the short set is
    /// tried first and suits a display that answers quickly (the display it was tuned on answers a read in
    /// about 30 ms with it, against 90 ms); the long set is the conservative DDC/CI timing.
    private struct Waits {
        let beforeWrite: useconds_t
        let beforeRead: useconds_t

        static let short = Waits(beforeWrite: 0, beforeRead: 20_000)
        static let long = Waits(beforeWrite: 10_000, beforeRead: 50_000)
    }

    /// nil when this macOS no longer exports the IOAVService functions.
    static let shared = IOAV()

    /// Displays answer with a null message unless a request is written twice.
    private static let requestCycles = 2
    /// A value is written three times: this display drops about one write in a hundred when it
    /// is sent twice, and none in the samples taken when it is sent three times.
    private static let setCycles = 3
    private static let retryWait: useconds_t = 20_000
    private static let readAttempts = 5

    private let createWithService: CreateWithService
    private let readI2C: ReadI2C
    private let writeI2C: WriteI2C

    private init?() {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let create = dlsym(defaultHandle, "IOAVServiceCreateWithService"),
            let read = dlsym(defaultHandle, "IOAVServiceReadI2C"),
            let write = dlsym(defaultHandle, "IOAVServiceWriteI2C")
        else { return nil }
        createWithService = unsafeBitCast(create, to: CreateWithService.self)
        readI2C = unsafeBitCast(read, to: ReadI2C.self)
        writeI2C = unsafeBitCast(write, to: WriteI2C.self)
    }

    /// The external displays' DDC services, each with the display it reaches.
    ///
    /// The registry lists every display's framebuffer before the DDC service that reaches the
    /// same display, so walking it in order pairs the two; the framebuffer is what knows the
    /// display's EDID. The walk takes about 10 ms, on the queue that talks to the display.
    func displays() -> [AVService] {
        var iterator: io_iterator_t = 0
        guard
            IORegistryCreateIterator(
                kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [AVService] = []
        var framebuffer: DisplayIdentity?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            switch IOObjectCopyClass(entry)?.takeRetainedValue() as String? {
            // The first on Macs with M2 and later, the second on those with M1.
            case "IOMobileFramebufferShim", "AppleCLCD2":
                framebuffer = DisplayIdentity(framebuffer: entry)
            case "DCPAVServiceProxy":
                let location =
                    IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                guard location == "External", let reference = createWithService(nil, entry) else { continue }
                services.append(AVService(reference: reference, identity: framebuffer))
            default:
                continue
            }
        }
        return services
    }

    func get(_ service: AVService, _ feature: DDC.Feature) -> DDC.Value? {
        var waits = waits(for: service)
        var missedAReply = false
        defer { service.pace.readFinished(missedAReply: missedAReply) }
        for attempt in 0..<Self.readAttempts {
            if attempt > 0 { usleep(Self.retryWait) }
            guard send(service, DDC.getRequest(feature), waits, cycles: Self.requestCycles) else { continue }
            usleep(waits.beforeRead)
            var reply = [UInt8](repeating: 0, count: DDC.getReplyLength)
            let status = reply.withUnsafeMutableBytes { buffer in
                readI2C(service.reference, DDC.chipAddress, DDC.hostAddress, buffer.baseAddress!, UInt32(buffer.count))
            }
            guard status == kIOReturnSuccess else { continue }
            do {
                return try DDC.parseGetReply(reply, feature: feature)
            } catch .unsupported {
                return nil
            } catch {
                // The display was not ready in time; the rest of this read gets the long waits.
                missedAReply = true
                waits = .long
                continue
            }
        }
        return nil
    }

    @discardableResult
    func set(_ service: AVService, _ feature: DDC.Feature, value: Int) -> Bool {
        send(service, DDC.setRequest(feature, value: value), waits(for: service), cycles: Self.setCycles)
    }

    /// Each search makes new services, so a display is told by what its EDID says. Two of one
    /// model without distinct serials look alike, and the caller then cannot tell which is which.
    func isSame(_ display: AVService, as other: AVService) -> Bool {
        display.identity != nil && display.identity == other.identity
    }

    private func waits(for service: AVService) -> Waits {
        service.pace.needsLongWaits ? .long : .short
    }

    private func send(_ service: AVService, _ packet: [UInt8], _ waits: Waits, cycles: Int) -> Bool {
        for _ in 0..<cycles {
            if waits.beforeWrite > 0 { usleep(waits.beforeWrite) }
            let status = packet.withUnsafeBytes { buffer in
                writeI2C(service.reference, DDC.chipAddress, DDC.hostAddress, buffer.baseAddress!, UInt32(buffer.count))
            }
            guard status == kIOReturnSuccess else { return false }
        }
        return true
    }
}
