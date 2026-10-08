import DisplayKeysCore
import Foundation
import IOKit

/// A retained IOAVService reference for one external display.
final class AVService: @unchecked Sendable {
    fileprivate let reference: UnsafeMutableRawPointer

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
struct IOAV: Sendable {
    private typealias CreateWithService = @convention(c) (UnsafeRawPointer?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias ReadI2C = @convention(c) (
        UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32
    ) -> IOReturn
    private typealias WriteI2C = @convention(c) (
        UnsafeMutableRawPointer, UInt32, UInt32, UnsafeRawPointer, UInt32
    ) -> IOReturn

    /// nil when this macOS no longer exports the IOAVService functions.
    static let shared = IOAV()

    private static let writeWait: useconds_t = 10_000
    /// Displays answer with a null message unless a request is written twice.
    private static let writeCycles = 2
    private static let readWait: useconds_t = 50_000
    private static let retryWait: useconds_t = 20_000
    private static let readAttempts = 5

    private let createWithService: CreateWithService
    private let readI2C: ReadI2C
    private let writeI2C: WriteI2C

    private init?() {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let create = dlsym(defaultHandle, "IOAVServiceCreateWithService"),
              let read = dlsym(defaultHandle, "IOAVServiceReadI2C"),
              let write = dlsym(defaultHandle, "IOAVServiceWriteI2C")
        else { return nil }
        createWithService = unsafeBitCast(create, to: CreateWithService.self)
        readI2C = unsafeBitCast(read, to: ReadI2C.self)
        writeI2C = unsafeBitCast(write, to: WriteI2C.self)
    }

    /// One service per external display, whether or not the display speaks DDC.
    func externalServices() -> [AVService] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
            == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [AVService] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let reference = createWithService(nil, entry) else { continue }
            services.append(AVService(reference: reference))
        }
        return services
    }

    /// Reads a feature; nil when the display does not answer or does not implement it.
    func get(_ service: AVService, _ feature: DDC.Feature) -> DDC.Value? {
        for attempt in 0..<Self.readAttempts {
            if attempt > 0 { usleep(Self.retryWait) }
            guard send(service, DDC.getRequest(feature)) else { continue }
            usleep(Self.readWait)
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
                continue
            }
        }
        return nil
    }

    /// Writes a feature. Success means the bytes were sent, not that the display honoured them.
    @discardableResult
    func set(_ service: AVService, _ feature: DDC.Feature, value: Int) -> Bool {
        send(service, DDC.setRequest(feature, value: value))
    }

    func state(of service: AVService) -> DisplayState {
        DisplayState(
            brightness: get(service, .brightness),
            volume: get(service, .volume),
            mute: get(service, .mute)
        )
    }

    private func send(_ service: AVService, _ packet: [UInt8]) -> Bool {
        for _ in 0..<Self.writeCycles {
            usleep(Self.writeWait)
            let status = packet.withUnsafeBytes { buffer in
                writeI2C(service.reference, DDC.chipAddress, DDC.hostAddress, buffer.baseAddress!, UInt32(buffer.count))
            }
            guard status == kIOReturnSuccess else { return false }
        }
        return true
    }
}
