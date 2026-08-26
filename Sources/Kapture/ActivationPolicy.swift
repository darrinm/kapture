// Kapture is LSUIElement (menu bar only), which makes document windows unreachable once
// covered — no Dock icon, no ⌘-tab entry. While any real window (editor, settings) is open,
// temporarily become a regular app; drop back to accessory when the last one closes.
import AppKit

@MainActor
enum ActivationPolicy {
    private static var holds = 0

    static func acquire() {
        holds += 1
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func release() {
        holds = max(0, holds - 1)
        if holds == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
