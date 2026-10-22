import AppKit
import ApplicationServices
import CryptoKit
import DisplayKeysCore
import Security
import notify

/// Accessibility access, which the keyboard key tap depends on.
///
/// macOS ties the permission to the app's signature. After an update of an app that has no
/// signing certificate, System Settings still shows the switch as on while macOS ignores it,
/// and the app cannot tell that state from "never granted". So such a build clears its own
/// entry whenever access is asked for, and the user adds the app to the list afresh. A build
/// signed with a certificate keeps its grant across updates; it clears the entry only when it
/// has not had access under that certificate yet (`AccessPolicy`).
@MainActor
final class AccessibilityAccess: NSObject {
    /// What System Settings calls the list under Privacy & Security; macOS 27 renamed it.
    /// A translation must use the name System Settings shows in that language.
    nonisolated static var listName: String {
        if #available(macOS 27, *) {
            String(localized: "Device Control and Data Access", comment: "The list's name in System Settings, macOS 27")
        } else {
            String(localized: "Accessibility", comment: "The list's name in System Settings, macOS 26")
        }
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
    /// The signature that last raised the subject; the key is from when it was always the build.
    private static let handledBuildKey = "accessibilityHandledBuild"
    /// The signature access was last seen granted under.
    private static let grantedSignatureKey = "accessibilityGrantedSignature"
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
        let signature = CodeIdentity.signature ?? "unknown"
        noteGrant()
        let shouldAsk = AccessPolicy.shouldAskAtLaunch(
            isGranted: isGranted, handledSignature: AppInfo.defaults.string(forKey: Self.handledBuildKey),
            currentSignature: signature, askingIsDisabled: askingIsDisabled)
        AppInfo.defaults.set(signature, forKey: Self.handledBuildKey)
        return shouldAsk
    }

    /// Clears the entry macOS holds for this app where it can be stale, opens the list in
    /// System Settings, and shows a helper under it with the app's icon to drag in. Does
    /// nothing when access is already granted.
    ///
    /// Only two things put an app in that list: the user adding it, or macOS's own alert. The
    /// helper offers the alert as the way to add the app without dragging.
    func request() {
        guard !isGranted else { return }
        guard
            AccessPolicy.clearsEntryBeforeAsking(
                isAdHoc: !CodeIdentity.isSignedWithCertificate,
                grantedSignature: AppInfo.defaults.string(forKey: Self.grantedSignatureKey),
                currentSignature: CodeIdentity.signature ?? "unknown")
        else { return guide() }
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

    /// The readings that follow are scheduled for every mode of the run loop, as the other
    /// delayed calls are, so that an open menu does not hold them back.
    func read(now: Bool) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notify), object: nil)
        if now { notify() }
        for delay in Self.rereadDelays {
            perform(#selector(notify), with: nil, afterDelay: delay, inModes: [.common])
        }
    }

    @objc private func notify() {
        if isGranted {
            helper?.dismiss()
            helper = nil
            noteGrant()
        }
        onChange?()
    }

    /// Remembers the signature access is granted under, so that a later build signed alike
    /// knows the entry in the list to be its own.
    private func noteGrant() {
        guard isGranted, let signature = CodeIdentity.signature,
            AppInfo.defaults.string(forKey: Self.grantedSignatureKey) != signature
        else { return }
        AppInfo.defaults.set(signature, forKey: Self.grantedSignatureKey)
    }
}

/// The app's signature, as macOS sees it when it grants a permission.
enum CodeIdentity {
    /// This build's hash and its certificate's, read once; nil where they cannot be read.
    private static let own: (build: String?, certificate: String?) = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            let information = information(of: staticCode)
        else { return (nil, nil) }
        return (buildHash(in: information), certificate(in: information))
    }()

    static func information(of code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }

    /// The hash of this build's code, which is what macOS binds a permission to when the app
    /// has no signing certificate. nil when the signature cannot be read.
    static var current: String? { own.build }

    /// A short form for people, in the way git abbreviates a commit.
    static var short: String? {
        current.map { String($0.prefix(7)) }
    }

    /// Whether this build is signed with a certificate, which stays the same across builds.
    static var isSignedWithCertificate: Bool { own.certificate != nil }

    /// What macOS ties a permission to: the certificate when the build has one, else the build.
    static var signature: String? { own.certificate ?? own.build }

    static func buildHash(in information: [String: Any]) -> String? {
        (information[kSecCodeInfoUnique as String] as? Data).map(hex)
    }

    /// A hash of the certificate the code is signed with; nil for an ad-hoc signature.
    static func certificate(in information: [String: Any]) -> String? {
        guard let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { return nil }
        return hex(Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
