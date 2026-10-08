import AppKit
import DisplayKeysCore

enum AppInfo {
    static let name = "DisplayKeys"
    /// Must match CFBundleIdentifier in Resources/Info.plist; a test checks it.
    static let bundleID = "local.DisplayKeys"

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
    private static let quarterStepsKey = "shortcut.quarterSteps"

    /// Whether each stepping shortcut is also registered with Shift added, for quarter steps.
    /// Off by default: macOS uses some of those combinations itself, such as Ctrl-Alt-Shift-arrows.
    static var quarterSteps: Bool {
        get { AppInfo.defaults.bool(forKey: quarterStepsKey) }
        set { store { $0.set(newValue, forKey: quarterStepsKey) } }
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
        store { defaults in
            if let text {
                defaults.set(text, forKey: key(for: action))
            } else {
                defaults.removeObject(forKey: key(for: action))
            }
        }
    }

    private static func key(for action: Shortcut.Action) -> String {
        "shortcut.\(action.rawValue)"
    }

    private static func store(_ change: (UserDefaults) -> Void) {
        change(AppInfo.defaults)
        // The command line exits right after changing a setting, so write it out now.
        AppInfo.defaults.synchronize()
    }
}
