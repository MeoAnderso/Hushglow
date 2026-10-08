/// When the app asks for Accessibility access on its own.
public enum AccessPolicy {
    /// Ask once for every new build that starts without access, unless asking was switched off.
    /// A new build needs asking again because macOS ties the permission to the app's signature.
    public static func shouldAskAtLaunch(
        isGranted: Bool, handledBuild: String?, currentBuild: String, askingIsDisabled: Bool
    ) -> Bool {
        !isGranted && !askingIsDisabled && handledBuild != currentBuild
    }
}
