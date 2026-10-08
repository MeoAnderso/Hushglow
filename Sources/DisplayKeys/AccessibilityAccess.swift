import AppKit
import ApplicationServices
import DisplayKeysCore
import Security

/// Accessibility access, which the keyboard key tap depends on.
///
/// macOS ties the permission to the app's signature. After an update of an app that has no
/// signing certificate, System Settings still shows the switch as on while macOS ignores it,
/// and the app cannot tell that state from "never granted". So it clears its own entry before
/// asking: once for every new build, and whenever the user asks for access. Switching the app
/// on in System Settings then always works.
@MainActor
final class AccessibilityAccess: NSObject {
    /// Posted system-wide when Accessibility access changes for any app.
    private static let changedNotification = Notification.Name("com.apple.accessibility.api")
    private static let handledBuildKey = "accessibilityHandledBuild"
    private static let askingDisabledKey = "accessibilityAskingDisabled"
    private static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let pollInterval: TimeInterval = 3

    /// Called when access may have changed.
    var onChange: (() -> Void)?
    private var timer: Timer?

    var isGranted: Bool { AXIsProcessTrusted() }

    /// When set, a new build no longer asks for access on its own; the menu still can.
    var askingIsDisabled: Bool {
        get { AppInfo.defaults.bool(forKey: Self.askingDisabledKey) }
        set { AppInfo.defaults.set(newValue, forKey: Self.askingDisabledKey) }
    }

    /// Starts following changes, and asks for access when the policy says so.
    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessChanged), name: Self.changedNotification, object: nil)
        let build = CodeIdentity.current ?? "unknown"
        let shouldAsk = AccessPolicy.shouldAskAtLaunch(
            isGranted: isGranted, handledBuild: AppInfo.defaults.string(forKey: Self.handledBuildKey),
            currentBuild: build, askingIsDisabled: askingIsDisabled)
        AppInfo.defaults.set(build, forKey: Self.handledBuildKey)
        if shouldAsk { request(openSettings: false) }
    }

    /// Clears the entry macOS holds for this app, has macOS list the app again, and optionally
    /// opens the Accessibility settings. Does nothing when access is already granted.
    func request(openSettings: Bool) {
        guard !isGranted else { return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", AppInfo.bundleID]
        reset.standardOutput = FileHandle.nullDevice
        reset.standardError = FileHandle.nullDevice
        reset.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.prompt(openSettings: openSettings) }
            }
        }
        do {
            try reset.run()
        } catch {
            prompt(openSettings: openSettings)
        }
    }

    /// While access is missing, looks for it every few seconds, since the change notification
    /// is not a documented guarantee. Nothing runs once access is granted.
    func startWaiting() {
        guard timer == nil else { return }
        let timer = Timer(
            timeInterval: Self.pollInterval, target: self, selector: #selector(notify), userInfo: nil, repeats: true)
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopWaiting() {
        timer?.invalidate()
        timer = nil
    }

    private func prompt(openSettings: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options), openSettings, let url = URL(string: Self.settingsURL)
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func accessChanged() {
        // The notification can arrive slightly before the new setting is readable.
        perform(#selector(notify), with: nil, afterDelay: 0.5)
    }

    @objc private func notify() {
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
