import AppKit
import DisplayKeysCore

/// Tells VoiceOver about level changes, which the on-screen indicator only shows. It speaks
/// once the level has settled, so holding a key does not produce a stream of announcements.
@MainActor
final class Announcer: NSObject {
    private static let settleDelay: TimeInterval = 0.4
    private var pending: String?

    func announce(_ indication: Indication) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        pending = indication.spoken
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(speak), object: nil)
        perform(#selector(speak), with: nil, afterDelay: Self.settleDelay)
    }

    @objc private func speak() {
        guard let pending else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: pending, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        self.pending = nil
    }
}
