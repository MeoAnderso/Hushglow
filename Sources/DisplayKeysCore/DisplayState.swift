/// What the on-screen indicator shows.
public enum Indication: Equatable, Sendable {
    case level(Feedback)
    /// The display did not take a change; some picture modes lock brightness, for example.
    case refused(Command.Control)
    /// The connected display does not have this control.
    case unsupported(Command.Control)
    case noDisplay
    /// The app is recording which special keys reach it, at someone's request.
    case watchingKeys

    /// The words the indicator shows in place of a level; nil for a level.
    public var message: String? {
        switch self {
        case .level: nil
        case .refused(let control): "\(control.title) is locked"
        case .unsupported(let control): "No \(control.rawValue) control"
        case .noDisplay: "No display to control"
        case .watchingKeys: "Watching special keys"
        }
    }

    /// What VoiceOver is told: the level in words, or the same message the indicator shows.
    public var spoken: String {
        guard case .level(let feedback) = self else { return message ?? "" }
        return switch feedback.kind {
        case .brightness where feedback.dimming > 0:
            "Brightness \(feedback.percent) percent, dimmed \(Int((Double(feedback.dimming) * Level.dimPerStep * 100).rounded())) percent"
        case .brightness: "Brightness \(feedback.percent) percent"
        case .volume: "Volume \(feedback.percent) percent"
        case .muted: "Muted"
        case .contrast: "Contrast \(feedback.percent) percent"
        case .input: "Input changed"
        }
    }
}

/// The level the on-screen indicator should show after a command.
public struct Feedback: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case brightness
        case volume
        case muted
        case contrast
        /// The display was switched to another input; there is no level to show.
        case input
    }

    /// An end of the range.
    public enum End: Equatable, Sendable {
        case bottom
        case top
    }

    public var kind: Kind
    /// The level as a share of the display's range.
    public var fraction: Double
    /// Where the level bar should be filled to; see `Level.barPosition`.
    public var barPosition: Double
    /// The end of the range a step pushed against and could not pass, so that it changed
    /// nothing; nil for anything else.
    public var pushedAgainst: End?
    /// How many steps the screen is dimmed below the display's lowest brightness.
    public var dimming = 0

    public init(kind: Kind, fraction: Double) {
        self.kind = kind
        self.fraction = fraction
        barPosition = fraction
    }

    public init(kind: Kind, value: DDC.Value) {
        self.kind = kind
        fraction = value.fraction
        barPosition = Level.barPosition(value)
    }

    /// The level as a whole percentage.
    public var percent: Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
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
    public var contrast: DDC.Value?
    /// The input the display shows, as it reports it; nil when it does not say.
    public var input: Int?
    /// How many steps the screen is dimmed below the display's lowest brightness, by an
    /// overlay; the display itself is at its lowest meanwhile.
    public var dimming = 0

    public init(
        brightness: DDC.Value?, volume: DDC.Value?, mute: DDC.Value?, contrast: DDC.Value? = nil,
        input: DDC.Value? = nil
    ) {
        self.brightness = brightness
        self.volume = volume
        hasHardwareMute = mute != nil
        isMuted = mute?.current == DDC.Mute.on
        self.contrast = contrast
        self.input = input?.current
    }

    /// Whether the display has a control.
    public func has(_ control: Command.Control) -> Bool {
        switch control {
        case .brightness: brightness != nil
        case .volume: volume != nil
        case .contrast: contrast != nil
        case .input: input != nil
        }
    }

    /// The cached value of a feature, in the display's own units.
    public func value(of feature: DDC.Feature) -> Int? {
        switch feature {
        case .brightness: brightness?.current
        case .volume: volume?.current
        case .mute: hasHardwareMute ? (isMuted ? DDC.Mute.on : DDC.Mute.off) : nil
        case .contrast: contrast?.current
        case .input: input
        }
    }

    /// Whether the display answered for at least one control.
    public var isControllable: Bool {
        brightness != nil || volume != nil
    }

    /// Applies a command; nil when the display lacks the control.
    ///
    /// A value the cache already holds is not written again. With `trustingCache` off it is,
    /// for a command that says what the display is to hold: such a command can be applied
    /// while the cache may be out of date, as long as nothing is left out on the cache's word.
    ///
    /// Below the display's lowest brightness, a step down dims the screen instead, up to
    /// `maximumDimming` steps; a step up takes the dimming off before it raises the display
    /// again. A brightness set outright takes the dimming off.
    public mutating func apply(_ command: Command, trustingCache: Bool = true, maximumDimming: Int = 0) -> Outcome? {
        let rewrites = !trustingCache && command.isAbsolute
        switch command {
        case .step(.brightness, let up, let fine):
            guard let value = brightness else { return nil }
            if up, dimming > 0 {
                dimming -= 1
                return setBrightness(value.current, rewrites: false)
            }
            let stepped = Level.stepped(value, up: up, fine: fine)
            if !up, stepped == value.current, dimming < maximumDimming {
                dimming += 1
                return setBrightness(value.current, rewrites: false)
            }
            return Self.noting(up, setBrightness(stepped, rewrites: false))
        case .set(.brightness, let percent):
            guard let value = brightness else { return nil }
            dimming = 0
            return setBrightness(Level.value(percent: percent, maximum: value.maximum), rewrites: rewrites)
        case .step(.volume, let up, let fine):
            guard let value = volume else { return nil }
            return Self.noting(up, setVolume(Level.stepped(value, up: up, fine: fine), rewrites: false))
        case .set(.volume, let percent):
            guard let value = volume else { return nil }
            return setVolume(Level.value(percent: percent, maximum: value.maximum), rewrites: rewrites)
        case .mute(let action):
            return setMuted(action == .toggle ? !isMuted : action == .on, rewrites: rewrites)
        case .step(.contrast, let up, let fine):
            guard let value = contrast else { return nil }
            return Self.noting(up, setContrast(Level.stepped(value, up: up, fine: fine), rewrites: false))
        case .set(.contrast, let percent):
            guard let value = contrast else { return nil }
            return setContrast(Level.value(percent: percent, maximum: value.maximum), rewrites: rewrites)
        case .input(let wanted):
            guard input != nil else { return nil }
            let changed = rewrites || input.map(DDC.Input.init(reported:)) != wanted
            input = wanted.rawValue
            return Outcome(
                writes: changed ? [Write(.input, wanted.rawValue)] : [], feedback: Feedback(kind: .input, fraction: 0))
        case .step(.input, _, _), .set(.input, _):
            return nil
        }
    }

    /// A step always moves, except at an end of the range, so a step that writes nothing was
    /// pushed against the end it was heading for. A step that unmutes writes the unmute.
    private static func noting(_ up: Bool, _ outcome: Outcome) -> Outcome {
        guard outcome.writes.isEmpty else { return outcome }
        var outcome = outcome
        outcome.feedback.pushedAgainst = up ? .top : .bottom
        return outcome
    }

    /// Replaces a cached feature with what the display reports. Returns the cached value it
    /// replaced when the two differed, nil when they agreed.
    @discardableResult
    public mutating func reconcile(_ feature: DDC.Feature, with reading: DDC.Value) -> Int? {
        switch feature {
        case .brightness:
            let cached = brightness?.current
            brightness = reading
            return cached == reading.current ? nil : cached
        case .volume:
            // An emulated mute holds the display at 0 while the cache remembers the real level.
            if isMuted, !hasHardwareMute {
                if reading.current == 0 { return nil }
                isMuted = false
            }
            let cached = volume?.current
            volume = reading
            return cached == reading.current ? nil : cached
        case .mute:
            let muted = reading.current == DDC.Mute.on
            let wasMuted = isMuted
            hasHardwareMute = true
            isMuted = muted
            return wasMuted == muted ? nil : (wasMuted ? DDC.Mute.on : DDC.Mute.off)
        case .contrast:
            let cached = contrast?.current
            contrast = reading
            return cached == reading.current ? nil : cached
        case .input:
            // Only the input's number counts; some displays report other bits beside it.
            let cached = input
            input = reading.current
            return cached.map { $0 & 0xFF } == reading.current & 0xFF ? nil : cached
        }
    }

    /// A value that did not change is not written again, so a key held at either end of the
    /// range sends nothing.
    private mutating func setBrightness(_ current: Int, rewrites: Bool) -> Outcome {
        let changed = rewrites || brightness?.current != current
        brightness?.current = current
        var feedback = Feedback(kind: .brightness, value: brightness ?? DDC.Value(current: 0, maximum: 0))
        feedback.dimming = dimming
        return Outcome(writes: changed ? [Write(.brightness, current)] : [], feedback: feedback)
    }

    private mutating func setContrast(_ current: Int, rewrites: Bool) -> Outcome {
        let changed = rewrites || contrast?.current != current
        contrast?.current = current
        return Outcome(
            writes: changed ? [Write(.contrast, current)] : [],
            feedback: Feedback(kind: .contrast, value: contrast ?? DDC.Value(current: 0, maximum: 0)))
    }

    /// Changing the volume also unmutes, as the system volume keys do.
    private mutating func setVolume(_ current: Int, rewrites: Bool) -> Outcome {
        var writes: [Write] = []
        // The display may have been muted without the cache knowing.
        if hasHardwareMute, isMuted || rewrites { writes.append(Write(.mute, DDC.Mute.off)) }
        // An emulated mute left the display at volume 0, so the value must be written back.
        if rewrites || volume?.current != current || (isMuted && !hasHardwareMute) {
            writes.append(Write(.volume, current))
        }
        isMuted = false
        volume?.current = current
        return Outcome(
            writes: writes, feedback: Feedback(kind: .volume, value: volume ?? DDC.Value(current: 0, maximum: 0)))
    }

    private mutating func setMuted(_ muted: Bool, rewrites: Bool) -> Outcome? {
        guard let volume else { return nil }
        let feedback = Feedback(kind: muted ? .muted : .volume, value: volume)
        // An emulated mute exists in the cache alone, so there the cache is right at any age.
        // Writing it again would put the remembered volume over whatever the display has now.
        guard muted != isMuted || (rewrites && hasHardwareMute) else { return Outcome(writes: [], feedback: feedback) }
        isMuted = muted
        let write =
            hasHardwareMute
            ? Write(.mute, muted ? DDC.Mute.on : DDC.Mute.off)
            : Write(.volume, muted ? 0 : volume.current)
        return Outcome(writes: [write], feedback: feedback)
    }
}
