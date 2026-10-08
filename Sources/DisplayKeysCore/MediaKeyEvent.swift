/// A brightness, volume or mute key press decoded from a system-defined (NX_SYSDEFINED) event.
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

    /// Subtype of system-defined events that carry auxiliary control buttons.
    public static let auxControlButtonsSubtype = 8

    /// Decodes `NSEvent.subtype` and `NSEvent.data1`; nil for any other key or event.
    public init?(subtype: Int, data1: Int) {
        guard subtype == Self.auxControlButtonsSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0x0000_FFFF
        let state = (flags & 0xFF00) >> 8

        // NX_KEYTYPE_* codes from IOKit/hidsystem/ev_keymap.h
        switch keyCode {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        case 7: key = .mute
        default: return nil
        }
        switch state {
        case 0xA: isDown = true
        case 0xB: isDown = false
        default: return nil
        }
        isRepeat = flags & 0x1 != 0
    }
}
