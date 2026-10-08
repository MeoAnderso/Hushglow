import AppKit
import DisplayKeysCore

enum AppInfo {
    static let name = "DisplayKeys"
    /// Must match CFBundleIdentifier in Resources/Info.plist; a test checks it.
    static let bundleID = "local.DisplayKeys"

    /// Carries a command's words from the command line to the running app.
    static let commandNotification = Notification.Name("local.DisplayKeys.command")
    static let shortcutsChangedNotification = Notification.Name("local.DisplayKeys.shortcutsChanged")

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// The app's settings, also when the binary runs outside its bundle (for example from `.build`).
    static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == bundleID ? .standard : UserDefaults(suiteName: bundleID) ?? .standard
    }

    /// The running app, when this process is not it.
    @MainActor static var otherInstance: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
}

enum ShortcutSettings {
    static func key(for action: Shortcut.Action) -> String {
        "shortcut.\(action.rawValue)"
    }

    /// The shortcut text for an action: the stored value, else the default; nil when disabled.
    static func text(for action: Shortcut.Action) -> String? {
        switch AppInfo.defaults.string(forKey: key(for: action)) {
        case nil: action.defaultShortcut
        case "": nil
        case let stored: stored
        }
    }

    /// Stores a shortcut; an empty text disables the action and nil restores its default.
    static func set(_ text: String?, for action: Shortcut.Action) {
        if let text {
            AppInfo.defaults.set(text, forKey: key(for: action))
        } else {
            AppInfo.defaults.removeObject(forKey: key(for: action))
        }
        // The command line exits right after storing a shortcut, so write it out now.
        AppInfo.defaults.synchronize()
    }
}
