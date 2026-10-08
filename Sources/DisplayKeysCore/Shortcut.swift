/// A global keyboard shortcut written as text, for example `ctrl+alt+up` or `shift+f15`.
public struct Shortcut: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// The actions a shortcut can be bound to, by the name used in settings and on the command line.
    public enum Action: String, CaseIterable, Sendable {
        case brightnessUp = "brightness-up"
        case brightnessDown = "brightness-down"
        case volumeUp = "volume-up"
        case volumeDown = "volume-down"
        case mute

        /// Shortcuts that work without any setup; volume and mute use the keyboard's own keys.
        public var defaultShortcut: String? {
            switch self {
            case .brightnessUp: "ctrl+alt+up"
            case .brightnessDown: "ctrl+alt+down"
            case .volumeUp, .volumeDown, .mute: nil
            }
        }

        public func command(fine: Bool) -> Command {
            switch self {
            case .brightnessUp: .step(.brightness, up: true, fine: fine)
            case .brightnessDown: .step(.brightness, up: false, fine: fine)
            case .volumeUp: .step(.volume, up: true, fine: fine)
            case .volumeDown: .step(.volume, up: false, fine: fine)
            case .mute: .mute(.toggle)
            }
        }

        /// Whether holding the shortcut should keep stepping.
        public var repeatsWhileHeld: Bool {
            self != .mute
        }
    }

    /// macOS virtual key code (kVK_*).
    public let keyCode: Int
    public let modifiers: Modifiers

    public init?(_ text: String) {
        var modifiers: Modifiers = []
        var keyCode: Int?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            if let modifier = Self.modifierNames[part] {
                modifiers.insert(modifier)
            } else if keyCode == nil, let code = Self.keyCodes[part] {
                keyCode = code
            } else {
                return nil
            }
        }
        guard let keyCode else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command,
        "shift": .shift,
        "alt": .option, "opt": .option, "option": .option,
        "ctrl": .control, "control": .control,
    ]

    /// Layout-independent keys only, so a shortcut means the same on every keyboard layout.
    private static let keyCodes: [String: Int] = [
        "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
        "pageup": 0x74, "pagedown": 0x79, "home": 0x73, "end": 0x77,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F,
        "f19": 0x50, "f20": 0x5A,
    ]
}
