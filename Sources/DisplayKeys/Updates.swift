import AppKit
import Sparkle

/// Updates through Sparkle, from the releases on GitHub.
///
/// Only a build that carries the public key its updates are signed with looks for them.
/// While the app is ad-hoc signed, that key is the only way to tell a real update from a
/// forged one, so without it the updater does not start, and the menu and Settings say
/// nothing about updates.
@MainActor
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    /// Whether this build can update itself: its Info.plist names the feed and the key.
    static func areConfigured(in info: [String: Any]?) -> Bool {
        let key = info?["SUPublicEDKey"] as? String
        let feed = (info?["SUFeedURL"] as? String).flatMap(URL.init(string:))
        return key?.isEmpty == false && feed?.scheme == "https"
    }

    var areAvailable: Bool { controller != nil }

    /// Starts the updater when this build can update itself. Sparkle asks the user once, on
    /// the second launch, whether to look for updates by itself.
    func start() {
        guard controller == nil, Self.areConfigured(in: Bundle.main.infoDictionary) else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkNow() {
        // The app has no window of its own in front; Sparkle's window must come forward.
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// Whether Sparkle looks for updates once a day by itself; nil when there are no updates.
    var checksAutomatically: Bool? {
        get { controller?.updater.automaticallyChecksForUpdates }
        set {
            guard let newValue else { return }
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    /// A menu bar app has no window to come forward with; Sparkle then shows an update it
    /// found by itself without taking the focus from what the user is doing.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
