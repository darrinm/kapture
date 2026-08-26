// Accessibility tier (impl spec §5): with the grant, a consuming CGEventTap routes overlay
// shortcuts (⌘W/⌘C/⌘S/⌘E/⌘⌫/space) to the hovered card with no click. Without it, the
// click-to-key tier in OverlayView remains the permanent floor. Handles tap-disabled
// re-enable; Secure Event Input silently pauses delivery (nothing to do).
import AppKit
import KaptureCore

@MainActor
final class EventTapCenter {
    static let shared = EventTapCenter()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func startIfPossible() {
        guard tap == nil, Settings.shared.hoverShortcutsEnabled, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Task { @MainActor in EventTapCenter.shared.reenable() }
                return Unmanaged.passUnretained(event)
            }
            // source is on the main run loop, so this executes on the main thread
            return MainActor.assumeIsolated { EventTapCenter.handle(event) }
        }, userInfo: nil)
        guard let tap else { Log.shell.error("event tap creation failed despite AX grant"); return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        Log.shell.info("hover-shortcut event tap running")
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private static func handle(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        guard let panel = OverlayController.shared.hoveredPanel,
              let event = NSEvent(cgEvent: cgEvent) else { return Unmanaged.passUnretained(cgEvent) }
        // caps lock is a latched state, not a chord — ignore it so shortcuts keep working
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        let handled = panel.performShortcut(command: mods == .command, keyCode: event.keyCode,
                                            characters: event.charactersIgnoringModifiers,
                                            plainSpace: mods.isEmpty)
        return handled ? nil : Unmanaged.passUnretained(cgEvent)   // pass unhandled events through
    }
}
