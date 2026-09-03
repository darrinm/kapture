// KaptureDesign: the glyph control that answers the pointer.
import AppKit

/// A borderless glyph button that lights up under the pointer and deepens while held.
///
/// Card chrome is a row of borderless SF Symbols sitting on a dark scrim. Borderless means no
/// bezel to shade, so nothing said which of the seven was under the pointer and nothing at all
/// confirmed a click had landed — the tooltip, half a second late, was the whole of the feedback.
/// A control you have to aim at by memory reads as a picture of a control rather than one you
/// can press.
///
/// The fill is drawn on the button's own layer rather than a sublayer so it stays behind the
/// glyph, and `Tokens.controlFill` composites it over `restingFill` instead of replacing it.
public final class HoverButton: NSButton {
    /// Fill when the pointer is elsewhere. `nil` for chrome that should stay invisible until
    /// hovered — the overlay card's buttons, which already sit on the card's own scrim band.
    public var restingFill: NSColor? {
        didSet { applyFill(animated: false) }
    }

    public var cornerRadius: CGFloat = Tokens.radiusControl {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    private var hovering = false {
        didSet { applyFill(animated: true) }
    }
    /// Instant, unlike the hover fade: a press is a confirmation, and a confirmation that eases
    /// in has already missed the moment it was confirming.
    private var pressed = false {
        didSet { applyFill(animated: false) }
    }

    public init(image: NSImage, tip: String, target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
        toolTip = tip
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        translatesAutoresizingMaskIntoConstraints = false
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       // .activeAlways: the overlay is a nonactivating panel, so
                                       // its cards are hovered while another app is frontmost.
                                       options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }

    /// Card chrome is hidden the moment the pointer leaves the card, and a view hidden out from
    /// under the pointer is never sent `mouseExited` — without this the button would come back
    /// still lit the next time the chrome appeared.
    public override func viewDidHide() {
        hovering = false
        pressed = false
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { super.mouseDown(with: event); return }
        pressed = true
        // NSButton tracks the drag and fires the action inside this call, returning on mouse-up.
        super.mouseDown(with: event)
        pressed = false
    }

    private var currentFill: NSColor? {
        guard isEnabled else { return restingFill }
        if pressed { return Tokens.controlFill(over: restingFill, brightenedBy: Tokens.controlPressAlpha) }
        if hovering { return Tokens.controlFill(over: restingFill, brightenedBy: Tokens.controlHoverAlpha) }
        return restingFill
    }

    private func applyFill(animated: Bool) {
        let color = currentFill?.cgColor
        guard animated else { layer?.backgroundColor = color; return }
        // Tokens.animate carries Reduce Motion (a duration of zero) and the implicit-animation
        // context that lets a layer property set here animate at all.
        Tokens.animate(Tokens.controlFade) { layer?.backgroundColor = color }
    }
}
