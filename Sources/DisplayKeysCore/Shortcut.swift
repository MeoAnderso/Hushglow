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

        /// The modifiers as macOS shows them, in its order, for example `⌃⌥`.
        public var symbols: String {
            Shortcut.modifierOrder.filter { contains($0.modifier) }.map(\.symbol).joined()
        }

        /// One modifier by the name used in settings and on the command line, such as `cmd`.
        public init?(name: String) {
            guard let modifier = Shortcut.modifierNames[name.lowercased()] else { return nil }
            self = modifier
        }

        /// The name of a single modifier, such as `cmd`; nil for none or several.
        public var name: String? {
            Shortcut.modifierOrder.first { $0.modifier == self }?.name
        }

        /// The name of a single modifier as the app writes it for people, such as `Cmd`.
        public var title: String? { name?.capitalized }

        /// The modifiers a quarter step can add, in the order they are offered. Cmd comes first
        /// and is the default: with the default shortcuts, macOS uses Ctrl+Alt+Shift with the
        /// arrows itself.
        public static let quarterStepChoices: [Modifiers] = [.command, .shift, .option, .control]
    }

    /// The shortcuts a fresh install starts with. Both work on any keyboard, including ones
    /// without brightness or volume keys.
    public enum DefaultSet: String, CaseIterable, Sendable {
        /// Ctrl+Alt with the arrows, and with End for mute: easy to reach on every keyboard.
        case arrows
        /// Ctrl+Alt with F1 and F2 for brightness, F11 and F12 for volume and F10 for mute,
        /// where Apple's keyboards have those functions. For a Mac with a window manager that
        /// uses Ctrl+Alt with the arrows itself.
        case functionKeys

        public func text(for action: Action) -> String {
            switch (self, action) {
            case (.arrows, .brightnessUp): "ctrl+alt+up"
            case (.arrows, .brightnessDown): "ctrl+alt+down"
            case (.arrows, .volumeUp): "ctrl+alt+right"
            case (.arrows, .volumeDown): "ctrl+alt+left"
            case (.arrows, .mute): "ctrl+alt+end"
            case (.functionKeys, .brightnessUp): "ctrl+alt+f2"
            case (.functionKeys, .brightnessDown): "ctrl+alt+f1"
            case (.functionKeys, .volumeUp): "ctrl+alt+f12"
            case (.functionKeys, .volumeDown): "ctrl+alt+f11"
            case (.functionKeys, .mute): "ctrl+alt+f10"
            }
        }

        public func shortcut(for action: Action) -> Shortcut? {
            Shortcut(text(for: action))
        }
    }

    /// The actions a shortcut can be bound to, by the name used in settings and on the command line.
    public enum Action: String, CaseIterable, Sendable {
        case brightnessUp = "brightness-up"
        case brightnessDown = "brightness-down"
        case volumeUp = "volume-up"
        case volumeDown = "volume-down"
        case mute

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
    /// `others` may hold the action's own shortcut too; it is not counted against itself.
    /// With quarter steps on, `quarterStep` is the modifier they add, and each stepping
    /// shortcut also claims the same keys with it.
    public static func check(
        _ shortcut: Shortcut?, for action: Action, others: [Action: Shortcut], quarterStep: Modifiers?,
        isUsedBySystem: (Shortcut) -> Bool = { _ in false }
    ) -> Rejection? {
        guard let shortcut else { return .unsupportedKey }
        guard shortcut.isUsable else { return .needsModifier }
        let wanted = shortcut.claimed(for: action, quarterStep: quarterStep)
        for other in Action.allCases where other != action {
            guard let taken = others[other] else { continue }
            if taken.claimed(for: other, quarterStep: quarterStep).contains(where: wanted.contains) {
                return .usedBy(other)
            }
        }
        return isUsedBySystem(shortcut) ? .usedBySystem : nil
    }

    /// Two actions that would claim the same keys, and those keys, were quarter steps taken
    /// with `quarterStep`; nil when no two would. For checking a change to quarter steps
    /// before it is made.
    public static func firstClash(
        among shortcuts: [Action: Shortcut], quarterStep: Modifiers?
    ) -> (action: Action, other: Action, keys: Shortcut)? {
        let actions = Action.allCases.filter { shortcuts[$0] != nil }
        for (index, action) in actions.enumerated() {
            let claimed = shortcuts[action]!.claimed(for: action, quarterStep: quarterStep)
            for other in actions[(index + 1)...] {
                let taken = shortcuts[other]!.claimed(for: other, quarterStep: quarterStep)
                if let keys = claimed.first(where: taken.contains) { return (action, other, keys) }
            }
        }
        return nil
    }

    /// The keys the shortcut takes when it is given to an action: itself and, with quarter
    /// steps on and for an action that steps, the same keys with the quarter-step modifier.
    public func claimed(for action: Action, quarterStep: Modifiers?) -> [Shortcut] {
        guard let quarterStep, action.repeatsWhileHeld, let quarter = adding(quarterStep) else { return [self] }
        return [self, quarter]
    }

    /// The same keys with a modifier added, which is what a quarter step is registered on; nil
    /// when the modifier is already part of the shortcut.
    public func adding(_ modifier: Modifiers) -> Shortcut? {
        modifiers.isSuperset(of: modifier) ? nil : Shortcut(keyCode: keyCode, modifiers: modifiers.union(modifier))
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

    /// The form shown to people, for example `⌃⌥↑` or `⌃⌥End`. The arrows are shown as arrows;
    /// Home, End and the page keys by name, since few people know their symbols.
    public var symbols: String {
        let key = Self.keyName(for: keyCode) ?? ""
        return modifiers.symbols + (Self.keySymbols[key] ?? Self.keyWords[key] ?? key.uppercased())
    }

    /// The form read aloud by VoiceOver, for example `Control Option Up Arrow`.
    public var spoken: String {
        let key = Self.keyName(for: keyCode) ?? ""
        let keyWords = Self.keyWords[key] ?? key.uppercased()
        return (Self.modifierOrder.filter { modifiers.contains($0.modifier) }.map(\.word) + [keyWords]).joined(
            separator: " ")
    }

    fileprivate static let modifierOrder: [(modifier: Modifiers, name: String, symbol: String, word: String)] = [
        (.control, "ctrl", "⌃", "Control"), (.option, "alt", "⌥", "Option"), (.shift, "shift", "⇧", "Shift"),
        (.command, "cmd", "⌘", "Command"),
    ]

    private static let keyWords: [String: String] = [
        "up": "Up Arrow", "down": "Down Arrow", "left": "Left Arrow", "right": "Right Arrow",
        "pageup": "Page Up", "pagedown": "Page Down", "home": "Home", "end": "End",
    ]

    private static let keySymbols: [String: String] = ["up": "↑", "down": "↓", "left": "←", "right": "→"]

    fileprivate static let modifierNames: [String: Modifiers] = [
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
