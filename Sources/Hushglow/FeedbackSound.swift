import AppKit
import HushglowCore

/// The sound macOS plays when a volume key changes the volume and "Play feedback when volume
/// is changed" is on in System Settings → Sound. The app plays the same sound, from the same
/// file, when it takes a volume key or a shortcut for the display.
@MainActor
final class FeedbackSound {
    /// Where macOS keeps the sound it plays.
    static let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
    /// The setting in the global domain; it is not written until it is first switched on.
    private static let settingKey = "com.apple.sound.beep.feedback"

    /// Loaded the first time it is played, so a Mac with the setting off never loads it.
    private lazy var sound = NSSound(contentsOfFile: Self.path, byReference: true)

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: settingKey)
    }

    /// Whether a command's outcome calls for the sound: a volume step that left the display
    /// with sound, while sound goes to the display and the setting is on. At either end of the
    /// range it plays all the same, as macOS's does.
    static func plays(after command: Command, feedback: Feedback, soundGoesToDisplay: Bool, isOn: Bool) -> Bool {
        guard isOn, soundGoesToDisplay, case .step(.volume, _, _) = command else { return false }
        return feedback.kind == .volume
    }

    /// Starts the sound again from the beginning, so that a held key does not pile it up.
    func play() {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }
}
