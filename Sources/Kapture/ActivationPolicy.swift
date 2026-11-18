// Kapture is LSUIElement (menu bar only), which makes document windows unreachable once
// covered: no Dock icon, no ⌘-tab entry. While any real window (editor, settings, library,
// recording) is open, Kapture becomes a regular app. It drops back to accessory when the last
// one closes.
//
// Holds are keyed by window, not counted. `show()` on a window that is already open acquires
// again, and the window closes only once. A counter went up on every re-show and never came
// back to zero, which left Kapture in the Dock and the app switcher for the rest of the session.
import AppKit

@MainActor
enum ActivationPolicy {
    private static var holds = Set<ObjectIdentifier>()

    /// Become a regular app while `window` is open. Acquiring the same window again only activates.
    static func acquire(for window: NSWindow) {
        holds.insert(ObjectIdentifier(window))
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Call from the window's close. Releasing a window that holds nothing does nothing.
    static func release(for window: NSWindow) {
        guard holds.remove(ObjectIdentifier(window)) != nil, holds.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
