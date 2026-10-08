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

        /// The shortcuts a fresh install starts with. They work on any keyboard, including
        /// ones without brightness or volume keys.
        public var defaultShortcut: String? {
            switch self {
            case .brightnessUp: "ctrl+alt+up"
            case .brightnessDown: "ctrl+alt+down"
            case .volumeUp: "ctrl+alt+right"
            case .volumeDown: "ctrl+alt+left"
            case .mute: "ctrl+alt+end"
            }
        }

        public var title: String {
            switch self {
            case .brightnessUp: "Brightness up"
            case .brightnessDown: "Brightness down"
            case .volumeUp: "Volume up"
            case .volumeDown: "Volume down"
            case .mute: "Mute"
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

    /// A shortcut from a key press; nil when the key is not one a shortcut can use.
    public init?(keyCode: Int, modifiers: Modifiers) {
        guard Self.keyCodes.values.contains(keyCode) else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Why a newly chosen shortcut cannot be used.
    public enum Rejection: Equatable, Sendable {
        /// The key is not one a shortcut can use, such as a letter.
        case unsupportedKey
        /// A bare arrow or page key would be taken away from every app.
        case needsModifier
        /// Another action already uses these keys.
        case usedBy(Action)
        /// macOS has a shortcut of its own on these keys, such as Mission Control on Ctrl-Up.
        case usedBySystem
    }

    /// Checks a shortcut chosen for an action against the shortcuts of the other actions and
    /// those of macOS. `shortcut` is nil when the pressed key is not one a shortcut can use.
    /// With quarter steps on, each stepping shortcut also claims its Shift variant.
    public static func check(
        _ shortcut: Shortcut?, for action: Action, others: [Action: Shortcut], quarterSteps: Bool,
        isUsedBySystem: (Shortcut) -> Bool = { _ in false }
    ) -> Rejection? {
        guard let shortcut else { return .unsupportedKey }
        guard shortcut.isUsable else { return .needsModifier }
        func claims(_ shortcut: Shortcut, _ action: Action) -> [Shortcut] {
            guard quarterSteps, action.repeatsWhileHeld, let quarter = shortcut.quarterStepVariant else {
                return [shortcut]
            }
            return [shortcut, quarter]
        }
        let wanted = claims(shortcut, action)
        for other in Action.allCases where other != action {
            guard let taken = others[other] else { continue }
            if claims(taken, other).contains(where: wanted.contains) { return .usedBy(other) }
        }
        return isUsedBySystem(shortcut) ? .usedBySystem : nil
    }

    /// The same keys with Shift added, which is what a quarter step is registered on; nil when
    /// Shift is already part of the shortcut.
    public var quarterStepVariant: Shortcut? {
        modifiers.contains(.shift) ? nil : Shortcut(keyCode: keyCode, modifiers: modifiers.union(.shift))
    }

    /// Whether the shortcut is safe to claim system-wide. A bare arrow or page key would take
    /// that key away from every app, so those need a modifier; a function key may stand alone.
    public var isUsable: Bool {
        !modifiers.isEmpty || (Self.keyName(for: keyCode)?.hasPrefix("f") ?? false)
    }

    /// The name of a key a shortcut can use, such as `f11` or `pageup`; nil for any other key.
    public static func keyName(for keyCode: Int) -> String? {
        keyCodes.first { $0.value == keyCode }?.key
    }

    /// The text form that `init(_:)` parses, for example `ctrl+alt+up`.
    public var text: String {
        let key = Self.keyName(for: keyCode) ?? ""
        return (Self.modifierOrder.filter { modifiers.contains($0.modifier) }.map(\.name) + [key]).joined(
            separator: "+")
    }

    /// The form shown to people, for example `⌃⌥↑`.
    public var symbols: String {
        let key = Self.keyName(for: keyCode) ?? ""
        let keySymbol = Self.keySymbols[key] ?? key.uppercased()
        return Self.modifierOrder.filter { modifiers.contains($0.modifier) }.map(\.symbol).joined() + keySymbol
    }

    /// The form read aloud by VoiceOver, for example `Control Option Up Arrow`.
    public var spoken: String {
        let key = Self.keyName(for: keyCode) ?? ""
        let keyWords = Self.keyWords[key] ?? key.uppercased()
        return (Self.modifierOrder.filter { modifiers.contains($0.modifier) }.map(\.word) + [keyWords]).joined(
            separator: " ")
    }

    private static let modifierOrder: [(modifier: Modifiers, name: String, symbol: String, word: String)] = [
        (.control, "ctrl", "⌃", "Control"), (.option, "alt", "⌥", "Option"), (.shift, "shift", "⇧", "Shift"),
        (.command, "cmd", "⌘", "Command"),
    ]

    private static let keyWords: [String: String] = [
        "up": "Up Arrow", "down": "Down Arrow", "left": "Left Arrow", "right": "Right Arrow",
        "pageup": "Page Up", "pagedown": "Page Down", "home": "Home", "end": "End",
    ]

    private static let keySymbols: [String: String] = [
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "pageup": "⇞", "pagedown": "⇟", "home": "↖", "end": "↘",
    ]

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
