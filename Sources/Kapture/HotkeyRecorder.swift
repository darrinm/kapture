// The "press a key combination" control in Settings › Shortcuts.
//
// It is a plain NSView rather than a dependency: recording a shortcut is one keyDown, and the
// event already carries the character for the active keyboard layout, which is the part that is
// annoying to derive after the fact.
import AppKit
import SwiftUI
import Carbon.HIToolbox

final class HotkeyRecorderView: NSView {
    var binding: HotkeyBinding { didSet { needsDisplay = true } }
    var onRecord: ((HotkeyBinding) -> Void)?
    var onReset: (() -> Void)?

    private var recording = false { didSet { needsDisplay = true } }

    init(binding: HotkeyBinding) {
        self.binding = binding
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)

        if event.keyCode == 53 {                       // esc — leave the binding alone
            recording = false
            window?.makeFirstResponder(nil)
            return
        }
        if event.keyCode == 51 {                       // delete — back to the default
            recording = false
            window?.makeFirstResponder(nil)
            onReset?()
            return
        }
        // A global hotkey needs a real modifier. Shift alone would swallow capital letters
        // system-wide, which is not a shortcut anyone wants.
        guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else {
            NSSound.beep()
            return
        }
        var carbon: UInt32 = 0
        if mods.contains(.command) { carbon |= UInt32(cmdKey) }
        if mods.contains(.shift) { carbon |= UInt32(shiftKey) }
        if mods.contains(.option) { carbon |= UInt32(optionKey) }
        if mods.contains(.control) { carbon |= UInt32(controlKey) }

        // charactersIgnoringModifiers, so ⌥4 records as "4" and not "¢"
        let character = (event.charactersIgnoringModifiers ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !character.isEmpty else { NSSound.beep(); return }

        recording = false
        window?.makeFirstResponder(nil)
        onRecord?(HotkeyBinding(keyCode: UInt32(event.keyCode), carbonModifiers: carbon,
                                character: character))
    }

    /// Swallow the chord's modifier-only flagsChanged so the field doesn't flicker mid-press.
    override func flagsChanged(with event: NSEvent) {}

    override func draw(_ dirty: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                   : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let text = recording ? "Type a shortcut" : binding.display
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                            y: bounds.midY - size.height / 2),
                                withAttributes: attributes)
    }
}

/// SwiftUI wrapper so the Settings form can lay it out like any other control.
struct HotkeyRecorder: NSViewRepresentable {
    let binding: HotkeyBinding
    let onRecord: (HotkeyBinding) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView(binding: binding)
        view.onRecord = onRecord
        view.onReset = onReset
        return view
    }

    func updateNSView(_ view: HotkeyRecorderView, context: Context) {
        view.binding = binding
        view.onRecord = onRecord
        view.onReset = onReset
    }
}
