import AppKit

/// The application object. It is a class of the app's own for one purpose: to see the key
/// presses that an open menu is about to take.
///
/// macOS holds an app's global shortcuts back for as long as one of the app's own menus is
/// open, and hands them over when the menu closes. For the shortcuts to work with the menu
/// open they are released for that time (see `KeyboardInput`), so that their keys arrive as
/// ordinary key presses. Those go to the menu, and the menu's loop asks the application for
/// every event it takes. That is the one place where a press can be taken before the menu
/// has it.
final class Application: NSApplication {
    /// Offered each key press that a menu is about to take. Returns whether the press was
    /// the app's, in which case the menu does not get it.
    var takeKeyFromMenu: ((NSEvent) -> Bool)?

    override func nextEvent(
        matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue: Bool
    ) -> NSEvent? {
        while true {
            let event = super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)
            guard let event, dequeue, mode == .eventTracking, event.type == .keyDown,
                takeKeyFromMenu?(event) == true
            else { return event }
            // The press was the app's. The menu goes on waiting for one of its own.
        }
    }
}
