import AppKit
import ApplicationServices
import DisplayKeysCore
import Security
import notify

/// Accessibility access, which the keyboard key tap depends on.
///
/// macOS ties the permission to the app's signature. After an update of an app that has no
/// signing certificate, System Settings still shows the switch as on while macOS ignores it,
/// and the app cannot tell that state from "never granted". So it clears its own entry
/// whenever access is asked for, and the user adds the app to the list afresh.
@MainActor
final class AccessibilityAccess: NSObject {
    /// What System Settings calls the list under Privacy & Security; macOS 27 renamed it.
    nonisolated static var listName: String {
        if #available(macOS 27, *) { "Device Control and Data Access" } else { "Accessibility" }
    }

    /// Posted by macOS right after it has stored a change to any app's permissions.
    private static let storedNotification = "com.apple.tcc.access.changed"
    /// Posted by System Settings when Accessibility access changes for any app, sometimes
    /// before the change is stored.
    private static let changedNotification = Notification.Name("com.apple.accessibility.api")
    /// A reading taken right at a notification can still be the old one, so it is taken again.
    /// After System Settings' notification there is no immediate reading at all: one taken
    /// before the change is stored can leave the old answer cached.
    private static let rereadDelays: [TimeInterval] = [0.5, 2]
    private static let handledBuildKey = "accessibilityHandledBuild"
    private static let askingDisabledKey = "accessibilityAskingDisabled"
    private static let listURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    /// Called when access may have changed.
    var onChange: (() -> Void)?
    private var storedToken: Int32 = 0
    private var helper: PermissionHelper?

    var isGranted: Bool { AXIsProcessTrusted() }

    /// When set, a new build no longer asks for access on its own; the menu still can.
    var askingIsDisabled: Bool {
        get { AppInfo.defaults.bool(forKey: Self.askingDisabledKey) }
        set { AppInfo.defaults.set(newValue, forKey: Self.askingDisabledKey) }
    }

    /// Starts following changes. Returns whether this launch should raise the subject with the
    /// user: once for every new build that runs without access, unless asking is switched off.
    ///
    /// Changes are followed through two notifications and nothing runs in between. Neither is
    /// documented, so access is also read again whenever the menu opens.
    func start() -> Bool {
        notify_register_dispatch(Self.storedNotification, &storedToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read(now: true) }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changeAnnounced), name: Self.changedNotification, object: nil)
        let build = CodeIdentity.current ?? "unknown"
        let shouldAsk = AccessPolicy.shouldAskAtLaunch(
            isGranted: isGranted, handledBuild: AppInfo.defaults.string(forKey: Self.handledBuildKey),
            currentBuild: build, askingIsDisabled: askingIsDisabled)
        AppInfo.defaults.set(build, forKey: Self.handledBuildKey)
        return shouldAsk
    }

    /// Clears the entry macOS holds for this app, opens the list in System Settings, and shows
    /// a helper under it with the app's icon to drag in. Does nothing when access is already
    /// granted.
    ///
    /// Only two things put an app in that list: the user adding it, or macOS's own alert. The
    /// helper offers the alert as the way to add the app without dragging.
    func request() {
        guard !isGranted else { return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", AppInfo.bundleID]
        reset.standardOutput = FileHandle.nullDevice
        reset.standardError = FileHandle.nullDevice
        reset.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.guide() }
            }
        }
        do {
            try reset.run()
        } catch {
            guide()
        }
    }

    private func guide() {
        log.notice("Opening the list in System Settings, with the helper")
        if let url = URL(string: Self.listURL) { NSWorkspace.shared.open(url) }
        let helper = helper ?? PermissionHelper(onAddWithoutDragging: { [unowned self] in raiseSystemAlert() })
        self.helper = helper
        helper.show()
    }

    /// macOS's own alert, which lists the app switched off.
    private func raiseSystemAlert() {
        log.notice("Asking macOS to add the app to the list")
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @objc private func changeAnnounced() {
        read(now: false)
    }

    private func read(now: Bool) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notify), object: nil)
        if now { notify() }
        for delay in Self.rereadDelays { perform(#selector(notify), with: nil, afterDelay: delay) }
    }

    @objc private func notify() {
        if isGranted {
            helper?.dismiss()
            helper = nil
        }
        onChange?()
    }
}

enum CodeIdentity {
    /// The hash of this build's code, which is what macOS binds a permission to when the app
    /// has no signing certificate. nil when the signature cannot be read.
    static let current: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
            let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }()

    /// A short form for people, in the way git abbreviates a commit.
    static var short: String? {
        current.map { String($0.prefix(7)) }
    }
}
