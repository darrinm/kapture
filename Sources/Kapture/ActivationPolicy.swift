// Kapture is LSUIElement (menu bar only), which makes document windows unreachable once
// covered: no Dock icon, no ⌘-tab entry. While any real window (editor, settings, library,
// recording) is open, Kapture becomes a regular app. It drops back to accessory when the last
// one closes.
//
// Holds are keyed by window and released by the window's own willClose, so callers only
// acquire. Re-showing an open window acquires again, and the window closes only once. A
// counter with a release per close went up on every re-show and never came back to zero,
// which left Kapture in the Dock and the app switcher for the rest of the session.
import AppKit

@MainActor
enum ActivationPolicy {
    /// One willClose observer per held window.
    private static var holds: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Become a regular app until `window` closes. Acquiring an open window again only activates.
    static func acquire(for window: NSWindow) {
        let id = ObjectIdentifier(window)
        if holds[id] == nil {
            holds[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { release(id) }
            }
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func release(_ id: ObjectIdentifier) {
        guard let token = holds.removeValue(forKey: id) else { return }
        NotificationCenter.default.removeObserver(token)
        if holds.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
