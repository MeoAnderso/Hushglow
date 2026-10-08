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

enum ProcessMemory {
    /// The memory this process is charged for, in bytes: the figure Activity Monitor shows.
    static var footprint: UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
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

/// How the on-screen indicator looks and where it appears.
enum IndicatorSettings {
    enum Style: String, CaseIterable {
        /// The system's glass, which follows the Liquid Glass setting in System Settings.
        case glass
        /// The same glass at reduced strength, so what is behind it shows through.
        case seeThrough
        /// A plain dark tint with no blur: the most transparent, and the lightest to draw.
        case plain

        var title: String {
            switch self {
            case .glass: "Glass"
            case .seeThrough: "See-through glass"
            case .plain: "Plain tint"
            }
        }
    }

    enum Position: String, CaseIterable {
        case underMenuBarIcon
        case corner

        var title: String {
            switch self {
            case .underMenuBarIcon: "Under the menu bar icon"
            case .corner: "Top-right corner"
            }
        }
    }

    static var style: Style {
        get { AppInfo.defaults.string(forKey: "indicator.style").flatMap(Style.init) ?? .glass }
        set { AppInfo.defaults.set(newValue.rawValue, forKey: "indicator.style") }
    }

    static var position: Position {
        get { AppInfo.defaults.string(forKey: "indicator.position").flatMap(Position.init) ?? .underMenuBarIcon }
        set { AppInfo.defaults.set(newValue.rawValue, forKey: "indicator.position") }
    }

    static var showsPercentage: Bool {
        get { AppInfo.defaults.bool(forKey: "indicator.showsPercentage") }
        set { AppInfo.defaults.set(newValue, forKey: "indicator.showsPercentage") }
    }
}
