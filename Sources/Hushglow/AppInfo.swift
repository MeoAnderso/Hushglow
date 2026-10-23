import AppKit
import HushglowCore

enum AppInfo {
    static let name = "Hushglow"
    /// Must match CFBundleIdentifier in Resources/Info.plist; a test checks it.
    static let bundleID = "io.github.meoanderso.Hushglow"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Where the settings are kept: the app's own domain, in the app and on its command line,
    /// also when the binary runs outside its bundle (for example from `.build`). Any other
    /// process that runs this code, as the tests do, has a domain of its own, so that nothing
    /// it does can reach the settings of the app in use.
    static let defaultsDomain =
        Bundle.main.bundleIdentifier == bundleID || ProcessInfo.processInfo.processName == name
        ? bundleID : "\(bundleID).tests"

    /// The app's settings. Those of another process start empty each time, so that what one
    /// run of the tests leaves behind does not change the next.
    /// UserDefaults may be used from any thread, which the compiler has no way of knowing.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        if Bundle.main.bundleIdentifier == bundleID { return .standard }
        if defaultsDomain != bundleID { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        return UserDefaults(suiteName: defaultsDomain) ?? .standard
    }()

    /// The running app, when this process is not it.
    @MainActor static var otherInstance: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
}

/// What the code that copies or notes settings needs of where they are kept: the app's
/// settings, or in the tests a store that keeps them in memory, so that a test leaves no
/// settings file behind.
protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStore {}

/// The settings are kept under the bundle identifier, so a new identifier would start the app
/// with none. The first run under a new one copies them over from the identifier the app had
/// before. While the identifier is unchanged this does nothing.
enum SettingsCarryOver {
    /// The identifier every build had until the app is signed with Developer ID.
    static let earlierBundleID = "local.DisplayKeys"
    private static let doneKey = "settingsCarriedOver"

    static var isNeeded: Bool { AppInfo.bundleID != earlierBundleID }

    /// Before anything reads the settings, in the app and on the command line alike.
    static func runIfNeeded() {
        guard isNeeded else { return }
        let copied = carryOver(
            from: UserDefaults.standard.persistentDomain(forName: earlierBundleID), to: AppInfo.defaults)
        if copied > 0 { AppInfo.defaults.synchronize() }
    }

    /// Copies the earlier settings into `current` where it has no value of its own, once; later
    /// calls copy nothing. Returns how many settings were copied.
    @discardableResult
    static func carryOver(from earlier: [String: Any]?, to current: any SettingsStore) -> Int {
        guard current.object(forKey: doneKey) as? Bool != true else { return 0 }
        var copied = 0
        for (key, value) in earlier ?? [:] where current.object(forKey: key) == nil {
            current.set(value, forKey: key)
            copied += 1
        }
        current.set(true, forKey: doneKey)
        return copied
    }
}

/// What the app calls the keyboard's own brightness, volume and mute keys, and the choice of
/// being asked about them again, so that the menu, the notices, Settings and the command line
/// all say the same.
enum KeyboardKeys {
    /// As a title, in the menu and on buttons.
    static var name: String {
        String(localized: "Brightness and Volume Keys", comment: "The keyboard's own brightness, volume and mute keys")
    }
    /// Within a sentence, and as a heading in Settings with its first letter capitalised.
    static var phrase: String {
        String(localized: "brightness and volume keys", comment: "The keyboard's own keys, within a sentence")
    }
    /// The checkbox, in Settings and in the notice after an update: ticked, a new build that
    /// runs without access raises the subject again.
    static var askAgain: String { String(localized: "Ask again after updates") }
}

extension String {
    /// The text with its first letter capitalised, for a phrase used as a heading.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension ListFormatter {
    /// Names joined as the language of the app's text joins them, such as "A and B". That is
    /// the language the sentence around them is in, which need not be the system's region.
    static func joinedInAppLanguage(_ names: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return formatter.string(from: names) ?? names.joined(separator: ", ")
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
    private static let quarterStepModifierKey = "shortcut.quarterStepModifier"
    private static let defaultSetKey = "shortcut.defaultSet"

    /// Whether each stepping shortcut is also registered with the quarter-step modifier added.
    /// Off by default.
    static var quarterSteps: Bool {
        get { AppInfo.defaults.bool(forKey: quarterStepsKey) }
        set { store { $0.set(newValue, forKey: quarterStepsKey) } }
    }

    /// What a quarter step adds to a stepping shortcut: Cmd unless another is chosen, since
    /// macOS uses Ctrl+Alt+Shift with the arrows itself.
    static var quarterStepModifier: Shortcut.Modifiers {
        get {
            AppInfo.defaults.string(forKey: quarterStepModifierKey).flatMap(Shortcut.Modifiers.init(name:))
                ?? .command
        }
        set { store { $0.set(newValue.name, forKey: quarterStepModifierKey) } }
    }

    /// The modifier quarter steps add; nil while they are off.
    static var quarterStep: Shortcut.Modifiers? {
        quarterSteps ? quarterStepModifier : nil
    }

    /// The shortcuts an action has when none has been chosen for it. Settled when the app
    /// first runs, so that installing a window manager later does not change shortcuts under
    /// the user's fingers; until then, the set that suits this Mac.
    static var defaultSet: Shortcut.DefaultSet {
        AppInfo.defaults.string(forKey: defaultSetKey).flatMap(Shortcut.DefaultSet.init) ?? suitedDefaultSet
    }

    /// The function keys when a window manager that takes Ctrl+Alt with the arrows is installed,
    /// else the arrows.
    static var suitedDefaultSet: Shortcut.DefaultSet {
        WindowManagers.installed.isEmpty ? .arrows : .functionKeys
    }

    /// Settles the defaults the first time the app runs: the set that suits this Mac for a new
    /// install, and the arrows it has always had for one from before there was a choice.
    static func settleDefaultSet(isNewInstall: Bool) {
        guard AppInfo.defaults.string(forKey: defaultSetKey) == nil else { return }
        let set = isNewInstall ? suitedDefaultSet : .arrows
        store { $0.set(set.rawValue, forKey: defaultSetKey) }
        log.notice("Default shortcuts: \(set.rawValue, privacy: .public)")
    }

    /// Chooses the defaults afresh for this Mac as it is now, as Restore Defaults does.
    static func chooseDefaultSetAfresh() {
        store { $0.set(suitedDefaultSet.rawValue, forKey: defaultSetKey) }
    }

    static func defaultShortcut(for action: Shortcut.Action) -> Shortcut? {
        defaultSet.shortcut(for: action)
    }

    /// The shortcut text for an action: the stored value, else the default; nil when disabled.
    static func text(for action: Shortcut.Action) -> String? {
        switch AppInfo.defaults.string(forKey: key(for: action)) {
        case nil: defaultSet.text(for: action)
        case "": nil
        case let stored: stored
        }
    }

    /// The shortcut for an action; nil when it has none.
    static func shortcut(for action: Shortcut.Action) -> Shortcut? {
        text(for: action).flatMap(Shortcut.init)
    }

    /// Every action's shortcut, for checking a new one against them.
    static var shortcuts: [Shortcut.Action: Shortcut] {
        var shortcuts: [Shortcut.Action: Shortcut] = [:]
        for action in Shortcut.Action.allCases { shortcuts[action] = shortcut(for: action) }
        return shortcuts
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

/// Window managers whose shortcuts are Ctrl+Alt with the arrows, as this app's would otherwise
/// be. macOS lets two apps register the same keys and tells neither, so the clash cannot be
/// seen; the app looks for the apps instead.
enum WindowManagers {
    private static let known: [(name: String, bundleID: String)] = [
        ("Rectangle", "com.knollsoft.Rectangle"), ("Rectangle Pro", "com.knollsoft.Hookshot"),
        ("Magnet", "com.crowdcafe.windowmagnet"),
    ]

    /// The names of those installed on this Mac.
    static var installed: [String] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }.map(\.name)
    }
}

/// Which display the keyboard's keys and the shortcuts change, when there are several.
enum ControlSettings {
    enum Target: String, CaseIterable {
        /// The display under the pointer, the one being looked at; the volume keys change the
        /// display that sound plays through.
        case pointer
        /// Every display at once.
        case every

        var title: String {
            switch self {
            case .pointer: String(localized: "The one under the pointer", comment: "Which display the keys change")
            case .every: String(localized: "Every display", comment: "Which display the keys change")
            }
        }
    }

    static var keysChange: Target {
        get { AppInfo.defaults.string(forKey: "control.keysChange").flatMap(Target.init) ?? .pointer }
        set { AppInfo.defaults.set(newValue.rawValue, forKey: "control.keysChange") }
    }
}

/// Whether the brightness keys go on dimming the screen once the display is at its lowest.
enum DimmingSettings {
    /// On unless switched off.
    static var isOn: Bool {
        get { AppInfo.defaults.object(forKey: "dimming.isOn") as? Bool ?? true }
        set { AppInfo.defaults.set(newValue, forKey: "dimming.isOn") }
    }

    /// How many steps a screen may be dimmed, as the displays take it.
    static var maximumSteps: Int { isOn ? Level.dimSteps : 0 }
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
            case .glass: String(localized: "Glass", comment: "A style of the indicator")
            case .seeThrough: String(localized: "See-through glass", comment: "A style of the indicator")
            case .plain: String(localized: "Plain tint", comment: "A style of the indicator")
            }
        }
    }

    enum Position: String, CaseIterable {
        case underMenuBarIcon
        case corner

        var title: String {
            switch self {
            case .underMenuBarIcon: String(localized: "Under the menu bar icon", comment: "Where the indicator appears")
            case .corner: String(localized: "Top-right corner", comment: "Where the indicator appears")
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
