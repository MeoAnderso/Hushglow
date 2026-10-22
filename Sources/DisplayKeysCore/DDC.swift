/// DDC/CI packet encoding and decoding for MCCS VCP features.
///
/// A packet here is the byte sequence that follows the host address (0x51) on the I2C bus.
/// Checksums still cover the display address (0x6E) and the host address.
public enum DDC {
    /// 7-bit I2C address of a display's DDC/CI endpoint.
    public static let chipAddress: UInt32 = 0x37
    public static let hostAddress: UInt32 = 0x51
    public static let getReplyLength = 11

    public enum Feature: UInt8, Sendable, CaseIterable {
        case brightness = 0x10
        case volume = 0x62
        case mute = 0x8D
        case contrast = 0x12
        /// Which of its inputs the display shows.
        case input = 0x60

        /// The feature as it is written on the command line.
        public var name: String {
            switch self {
            case .brightness: "brightness"
            case .volume: "volume"
            case .mute: "mute"
            case .contrast: "contrast"
            case .input: "input"
            }
        }

        public init?(name: String) {
            guard let feature = Self.allCases.first(where: { $0.name == name }) else { return nil }
            self = feature
        }
    }

    /// Values of the mute feature (VCP 0x8D).
    public enum Mute {
        public static let on = 1
        public static let off = 2
    }

    /// The inputs a display can be switched to (VCP 0x60), as MCCS numbers them. Displays have
    /// a few of these; which ones is not asked, so all of them are offered.
    public enum Input: Int, Sendable, CaseIterable {
        case displayPort1 = 0x0F
        case displayPort2 = 0x10
        case hdmi1 = 0x11
        case hdmi2 = 0x12
        /// Not in MCCS; the number Dell, LG and others use for USB-C.
        case usbC = 0x1B

        /// The input from a value the display reports, which some put in the low byte only.
        public init?(reported value: Int) {
            self.init(rawValue: value & 0xFF)
        }

        public var title: String {
            switch self {
            case .displayPort1: String(localized: "DisplayPort 1", comment: "A display's input")
            case .displayPort2: String(localized: "DisplayPort 2", comment: "A display's input")
            case .hdmi1: String(localized: "HDMI 1", comment: "A display's input")
            case .hdmi2: String(localized: "HDMI 2", comment: "A display's input")
            case .usbC: String(localized: "USB-C", comment: "A display's input")
            }
        }

        /// The input as it is written on the command line.
        public var name: String {
            switch self {
            case .displayPort1: "dp1"
            case .displayPort2: "dp2"
            case .hdmi1: "hdmi1"
            case .hdmi2: "hdmi2"
            case .usbC: "usbc"
            }
        }

        public init?(name: String) {
            guard let input = Self.allCases.first(where: { $0.name == name }) else { return nil }
            self = input
        }
    }

    public struct Value: Equatable, Sendable {
        public var current: Int
        public var maximum: Int

        public init(current: Int, maximum: Int) {
            self.current = current
            self.maximum = maximum
        }

        public var fraction: Double {
            maximum > 0 ? Double(current) / Double(maximum) : 0
        }
    }

    public enum ReplyError: Error, Equatable, Sendable {
        case truncated
        /// The display answered with a null message: it has no reply ready yet.
        case notReady
        case malformed
        case wrongFeature
        case badChecksum
        /// The display answered, and reports that it does not implement the feature.
        case unsupported
    }

    /// Decides whether a display gets the short pauses around a request or the long ones.
    ///
    /// Every read starts with the short ones and falls back to the long ones when a reply does
    /// not come in time. One such miss says little, since displays answer late now and then.
    /// A display that misses on several reads in a row is taken to need the long pauses from
    /// the start, for as long as it stays connected.
    public struct Pace: Equatable, Sendable {
        public static let missesBeforeLongWaits = 3

        public private(set) var needsLongWaits = false
        private var missesInARow = 0

        public init() {}

        /// Takes note of how a read that began with the short pauses went.
        public mutating func readFinished(missedAReply: Bool) {
            guard !needsLongWaits else { return }
            missesInARow = missedAReply ? missesInARow + 1 : 0
            needsLongWaits = missesInARow >= Self.missesBeforeLongWaits
        }
    }

    private static let requestSeed: UInt8 = 0x6E ^ 0x51
    private static let replySeed: UInt8 = 0x50
    private static let getReplyLengthByte: UInt8 = 0x88

    public static func getRequest(_ feature: Feature) -> [UInt8] {
        sealed([0x82, 0x01, feature.rawValue])
    }

    public static func setRequest(_ feature: Feature, value: Int) -> [UInt8] {
        let value = UInt16(clamping: value)
        return sealed([0x84, 0x03, feature.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Parses the reply to a get request.
    ///
    /// Expected layout: `6E 88 02 <result> <feature> <type> <maxH> <maxL> <curH> <curL> <checksum>`.
    /// IOAVServiceReadI2C hands back the read offset in byte 1 instead of the length byte, so
    /// that byte is ignored and the checksum is validated against the length it must have had.
    public static func parseGetReply(_ reply: [UInt8], feature: Feature) throws(ReplyError) -> Value {
        guard reply.count >= getReplyLength else { throw .truncated }
        if reply[1] == 0x80, reply[2] == replySeed ^ 0x6E ^ 0x80 { throw .notReady }
        guard reply[0] == 0x6E, reply[2] == 0x02 else { throw .malformed }
        guard reply[4] == feature.rawValue else { throw .wrongFeature }
        let checksum = reply[2...9].reduce(replySeed ^ reply[0] ^ getReplyLengthByte, ^)
        guard checksum == reply[10] else { throw .badChecksum }
        guard reply[3] == 0x00 else { throw .unsupported }
        return Value(
            current: Int(reply[8]) << 8 | Int(reply[9]),
            maximum: Int(reply[6]) << 8 | Int(reply[7])
        )
    }

    private static func sealed(_ body: [UInt8]) -> [UInt8] {
        body + [body.reduce(requestSeed, ^)]
    }
}
