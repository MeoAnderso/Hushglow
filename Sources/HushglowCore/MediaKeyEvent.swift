/// A press or release of one of the keys that a system-defined (NX_SYSDEFINED) event carries:
/// brightness, volume, mute and the playback keys.
public struct AuxiliaryKey: Equatable, Sendable {
    /// Subtype of the system-defined events that carry these keys.
    public static let eventSubtype = 8

    /// The key's NX_KEYTYPE_* code, from IOKit/hidsystem/ev_keymap.h.
    public let code: Int
    public let isDown: Bool
    public let isRepeat: Bool

    /// Decodes `NSEvent.subtype` and `NSEvent.data1`; nil for any other event.
    public init?(subtype: Int, data1: Int) {
        guard subtype == Self.eventSubtype else { return nil }
        let flags = data1 & 0x0000_FFFF
        switch (flags & 0xFF00) >> 8 {
        case 0xA: isDown = true
        case 0xB: isDown = false
        default: return nil
        }
        code = (data1 & 0xFFFF_0000) >> 16
        isRepeat = flags & 0x1 != 0
    }

    /// What the key is called, for telling someone which keys arrived.
    public var name: String {
        Self.names[code] ?? "code \(code)"
    }

    private static let names = [
        0: "volume up", 1: "volume down", 2: "brightness up", 3: "brightness down", 7: "mute",
        16: "play/pause", 17: "next", 18: "previous", 19: "fast forward", 20: "rewind",
    ]
}

/// A brightness, volume or mute key press: the auxiliary keys the app acts on.
public struct MediaKeyEvent: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case volumeUp
        case volumeDown
        case brightnessUp
        case brightnessDown
        case mute
    }

    public let key: Key
    public let isDown: Bool
    public let isRepeat: Bool

    /// Decodes `NSEvent.subtype` and `NSEvent.data1`; nil for any other key or event.
    public init?(subtype: Int, data1: Int) {
        guard let press = AuxiliaryKey(subtype: subtype, data1: data1) else { return nil }
        switch press.code {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        case 7: key = .mute
        default: return nil
        }
        isDown = press.isDown
        isRepeat = press.isRepeat
    }
}
