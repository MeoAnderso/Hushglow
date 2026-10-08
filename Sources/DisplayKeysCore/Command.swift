/// An action on the display, shared by keys, shortcuts, the menu and the command line.
public enum Command: Equatable, Sendable {
    public enum Control: String, Sendable, CaseIterable {
        case brightness
        case volume

        /// The display features a control is made of.
        public var features: [DDC.Feature] {
            switch self {
            case .brightness: [.brightness]
            case .volume: [.volume, .mute]
            }
        }
    }

    public enum MuteAction: String, Sendable {
        case toggle
        case on
        case off
    }

    case step(Control, up: Bool, fine: Bool)
    /// Sets a control to a percentage of its range.
    case set(Control, percent: Int)
    case mute(MuteAction)

    /// Parses command-line words such as `step brightness up --fine`, `set volume 40` or `mute`.
    public init?(words: [String]) {
        var words = words
        let fine = words.contains("--fine")
        words.removeAll { $0 == "--fine" }
        guard let verb = words.first else { return nil }

        switch (verb, words.count) {
        case ("step", 3):
            guard let control = Control(rawValue: words[1]), ["up", "down"].contains(words[2]) else { return nil }
            self = .step(control, up: words[2] == "up", fine: fine)
        case ("set", 3):
            guard let control = Control(rawValue: words[1]), let percent = Int(words[2]), (0...100).contains(percent)
            else { return nil }
            self = .set(control, percent: percent)
        case ("mute", 1):
            self = .mute(.toggle)
        case ("mute", 2):
            guard let action = MuteAction(rawValue: words[1]) else { return nil }
            self = .mute(action)
        default:
            return nil
        }
    }

    /// The control this command acts on; mute belongs to volume.
    public var control: Control {
        switch self {
        case .step(let control, _, _), .set(let control, _): control
        case .mute: .volume
        }
    }

    /// What has to be read from a display before this command can be applied to a stale cache.
    public var featureToRead: DDC.Feature {
        switch self {
        case .step(.brightness, _, _), .set(.brightness, _): .brightness
        case .step(.volume, _, _), .set(.volume, _): .volume
        case .mute: .mute
        }
    }

    /// The words that `init(words:)` parses back into this command.
    public var words: [String] {
        switch self {
        case .step(let control, let up, let fine):
            ["step", control.rawValue, up ? "up" : "down"] + (fine ? ["--fine"] : [])
        case .set(let control, let percent):
            ["set", control.rawValue, String(percent)]
        case .mute(let action):
            ["mute", action.rawValue]
        }
    }
}
