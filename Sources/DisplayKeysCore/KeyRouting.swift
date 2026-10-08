/// Decides what a media key press does, given what the display supports and where sound is going.
public enum KeyRouting {
    public struct Context: Sendable {
        public var hasBrightness: Bool
        public var hasVolume: Bool
        /// Sound is going to a display that has no volume control of its own.
        public var soundGoesToDisplay: Bool
        /// The main display is built in, so macOS already handles the brightness keys.
        public var mainDisplayIsBuiltIn: Bool

        public init(hasBrightness: Bool, hasVolume: Bool, soundGoesToDisplay: Bool, mainDisplayIsBuiltIn: Bool) {
            self.hasBrightness = hasBrightness
            self.hasVolume = hasVolume
            self.soundGoesToDisplay = soundGoesToDisplay
            self.mainDisplayIsBuiltIn = mainDisplayIsBuiltIn
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Not the display's key: leave it to macOS.
        case passThrough
        /// The display's key, with nothing to do: a key release, or a mute key being held.
        case swallow
        case run(Command)
    }

    public static func decide(_ event: MediaKeyEvent, fine: Bool, in context: Context) -> Decision {
        let command: Command
        switch event.key {
        case .brightnessUp, .brightnessDown:
            guard context.hasBrightness, !context.mainDisplayIsBuiltIn else { return .passThrough }
            command = .step(.brightness, up: event.key == .brightnessUp, fine: fine)
        case .volumeUp, .volumeDown:
            guard context.hasVolume, context.soundGoesToDisplay else { return .passThrough }
            command = .step(.volume, up: event.key == .volumeUp, fine: fine)
        case .mute:
            guard context.hasVolume, context.soundGoesToDisplay else { return .passThrough }
            if event.isRepeat { return .swallow }
            command = .mute(.toggle)
        }
        return event.isDown ? .run(command) : .swallow
    }
}
