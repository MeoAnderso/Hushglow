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
        pending = Self.words(for: indication)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(speak), object: nil)
        perform(#selector(speak), with: nil, afterDelay: Self.settleDelay)
    }

    static func words(for indication: Indication) -> String {
        switch indication {
        case .level(let feedback):
            switch feedback.kind {
            case .brightness: "Brightness \(feedback.percent) percent"
            case .volume: "Volume \(feedback.percent) percent"
            case .muted: "Muted"
            }
        case .refused(let control): "\(control.rawValue.capitalized) is locked by the display"
        case .unsupported(let control): "This display has no \(control.rawValue) control"
        case .noDisplay: "No display to control"
        case .watchingKeys: "Watching special keys"
        }
    }

    @objc private func speak() {
        guard let pending else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: pending, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        self.pending = nil
    }
}
