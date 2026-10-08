/// What the on-screen indicator should show after a command.
public struct Feedback: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case brightness
        case volume
        case muted
    }

    public var kind: Kind
    public var fraction: Double

    public init(kind: Kind, fraction: Double) {
        self.kind = kind
        self.fraction = fraction
    }
}

/// The cached state of one display. Commands are applied to the cache and produce the DDC
/// writes to send, so the display is never read on a key press.
public struct DisplayState: Equatable, Sendable {
    public struct Write: Equatable, Sendable {
        public var feature: DDC.Feature
        public var value: Int

        public init(_ feature: DDC.Feature, _ value: Int) {
            self.feature = feature
            self.value = value
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var writes: [Write]
        public var feedback: Feedback
    }

    public var brightness: DDC.Value?
    public var volume: DDC.Value?
    /// Whether the display implements the mute feature; otherwise mute is emulated with volume 0.
    public var hasHardwareMute: Bool
    public var isMuted: Bool

    public init(brightness: DDC.Value?, volume: DDC.Value?, mute: DDC.Value?) {
        self.brightness = brightness
        self.volume = volume
        hasHardwareMute = mute != nil
        isMuted = mute?.current == DDC.Mute.on
    }

    /// Whether the display answered for at least one control.
    public var isControllable: Bool {
        brightness != nil || volume != nil
    }

    /// Applies a command; nil when the display lacks the control.
    public mutating func apply(_ command: Command) -> Outcome? {
        switch command {
        case let .step(.brightness, up, fine):
            guard let value = brightness else { return nil }
            return setBrightness(Level.stepped(value, up: up, fine: fine))
        case let .set(.brightness, percent):
            guard let value = brightness else { return nil }
            return setBrightness(Level.value(percent: percent, maximum: value.maximum))
        case let .step(.volume, up, fine):
            guard let value = volume else { return nil }
            return setVolume(Level.stepped(value, up: up, fine: fine))
        case let .set(.volume, percent):
            guard let value = volume else { return nil }
            return setVolume(Level.value(percent: percent, maximum: value.maximum))
        case let .mute(action):
            return setMuted(action == .toggle ? !isMuted : action == .on)
        }
    }

    /// A value that did not change is not written again, so a key held at either end of the
    /// range sends nothing.
    private mutating func setBrightness(_ current: Int) -> Outcome {
        let changed = brightness?.current != current
        brightness?.current = current
        return Outcome(
            writes: changed ? [Write(.brightness, current)] : [],
            feedback: Feedback(kind: .brightness, fraction: brightness?.fraction ?? 0)
        )
    }

    /// Changing the volume also unmutes, as the system volume keys do.
    private mutating func setVolume(_ current: Int) -> Outcome {
        var writes: [Write] = []
        if isMuted, hasHardwareMute { writes.append(Write(.mute, DDC.Mute.off)) }
        // An emulated mute left the display at volume 0, so the value must be written back.
        if volume?.current != current || (isMuted && !hasHardwareMute) { writes.append(Write(.volume, current)) }
        isMuted = false
        volume?.current = current
        return Outcome(writes: writes, feedback: Feedback(kind: .volume, fraction: volume?.fraction ?? 0))
    }

    private mutating func setMuted(_ muted: Bool) -> Outcome? {
        guard let volume else { return nil }
        let feedback = Feedback(kind: muted ? .muted : .volume, fraction: volume.fraction)
        guard muted != isMuted else { return Outcome(writes: [], feedback: feedback) }
        isMuted = muted
        let write = hasHardwareMute
            ? Write(.mute, muted ? DDC.Mute.on : DDC.Mute.off)
            : Write(.volume, muted ? 0 : volume.current)
        return Outcome(writes: [write], feedback: feedback)
    }
}
