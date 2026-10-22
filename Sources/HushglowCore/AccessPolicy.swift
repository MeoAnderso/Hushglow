/// When the app asks for Accessibility access on its own, and what it does first.
///
/// macOS ties the permission to the app's signature. An ad-hoc signature is the build itself,
/// so every build is new to macOS; a certificate stays the same across builds, so a grant
/// lasts until the certificate changes. A signature here is whichever of the two the build
/// has: its own hash, or its certificate's.
public enum AccessPolicy {
    /// Ask once for every new signature that starts without access, unless asking was switched off.
    public static func shouldAskAtLaunch(
        isGranted: Bool, handledSignature: String?, currentSignature: String, askingIsDisabled: Bool
    ) -> Bool {
        !isGranted && !askingIsDisabled && handledSignature != currentSignature
    }

    /// Whether the entry macOS keeps for the app is cleared before access is asked for. An
    /// entry made under another signature still shows its switch on while macOS ignores it,
    /// and the app cannot tell, so it is cleared. One made under this certificate is the
    /// user's own: it was switched off or removed, and is left for them to switch on again.
    public static func clearsEntryBeforeAsking(
        isAdHoc: Bool, grantedSignature: String?, currentSignature: String
    ) -> Bool {
        isAdHoc || grantedSignature != currentSignature
    }
}
