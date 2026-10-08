import AppKit

/// Display sleep, wake and reconfiguration, reported through closures.
@MainActor
final class SystemEvents: NSObject {
    var onDisplaysSlept: (() -> Void)?
    var onDisplaysWoke: (() -> Void)?
    /// A display was plugged in, unplugged or changed mode. Arrives in bursts.
    var onDisplaysReconfigured: (() -> Void)?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspace.addObserver(self, selector: #selector(displaysWoke), name: name, object: nil)
        }
        workspace.addObserver(
            self, selector: #selector(displaysSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysReconfigured),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func displaysWoke() {
        log.info("Displays woke")
        onDisplaysWoke?()
    }

    @objc private func displaysSlept() {
        log.info("Displays went to sleep")
        onDisplaysSlept?()
    }

    @objc private func displaysReconfigured() {
        log.info("Display configuration changed")
        onDisplaysReconfigured?()
    }
}
