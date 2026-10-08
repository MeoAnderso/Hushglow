import DisplayKeysCore
import Foundation
import IOKit

/// A retained IOAVService reference for one external display.
final class AVService: @unchecked Sendable {
    fileprivate let reference: UnsafeMutableRawPointer
    /// Whether the display has shown that it needs the long waits. Only touched on the queue
    /// that talks to the display.
    fileprivate var pace = DDC.Pace()

    fileprivate init(reference: UnsafeMutableRawPointer) {
        self.reference = reference
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

    func displays() -> [AVService] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [AVService] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location =
                IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let reference = createWithService(nil, entry) else { continue }
            services.append(AVService(reference: reference))
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
