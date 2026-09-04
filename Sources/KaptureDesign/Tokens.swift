// KaptureDesign: the in-repo design system. Every surface draws from these tokens.
import AppKit

public enum Tokens {
    // MARK: Color
    public static let accent = NSColor(srgbRed: 0.78, green: 0.26, blue: 0.23, alpha: 1)  // record red #C7423A
    public static let overlayScrim = NSColor.black.withAlphaComponent(0.38)
    /// Backing for the floating bottom-center pills (the toast, the keystroke HUD). One value:
    /// they can appear one above the other, and two near-identical blacks read as a mistake.
    public static let pillScrim = NSColor.black.withAlphaComponent(0.72)

    // MARK: Duration
    /// m:ss for every duration Kapture shows (live recording timer, overlay card pill).
    /// Truncating, not rounding: the live timer must never read 1:00 while it is still
    /// recording second 59, and the card has to agree with the timer that produced it.
    public static func duration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Spacing & radius
    public static let cornerMargin: CGFloat = 16
    public static let stackGap: CGFloat = 8
    public static let radiusOverlay: CGFloat = 10
    /// Library thumbnails. Smaller than the overlay's: these sit at a dozen sizes in a grid, and
    /// a radius that reads as "rounded" on a full-size card reads as "lozenge" on a small tile.
    public static let radiusThumb: CGFloat = 6
    /// Space between library thumbnails, and around the grid. Wide enough that the images read as
    /// separate things rather than one sheet — the gap is what makes a grid look like a library.
    public static let gridGutter: CGFloat = 16
    /// Row heights the library zoom steps through.
    public static let gridRowHeights: [CGFloat] = [116, 168, 240, 332]
    /// How far a bottom-center pill sits above the bottom of the screen.
    public static let pillBottomInset: CGFloat = 90

    // MARK: Aspect math
    /// Rect that fits `imageSize` inside `bounds` preserving aspect ratio (letterboxed, centered).
    public static func aspectFit(_ imageSize: CGSize, in bounds: CGRect) -> CGRect {
        aspectRect(imageSize, in: bounds, scale: min)
    }

    /// Rect that fills `bounds` with `imageSize` preserving aspect ratio (cropped, centered).
    public static func aspectFill(_ imageSize: CGSize, in bounds: CGRect) -> CGRect {
        aspectRect(imageSize, in: bounds, scale: max)
    }

    private static func aspectRect(_ imageSize: CGSize, in bounds: CGRect,
                                   scale pick: (CGFloat, CGFloat) -> CGFloat) -> CGRect {
        let scale = pick(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: bounds.minX + (bounds.width - w) / 2,
                      y: bounds.minY + (bounds.height - h) / 2, width: w, height: h)
    }

    // MARK: Overlay sizing (3 steps; index by settings)
    public static let overlaySizes: [CGSize] = [
        CGSize(width: 136, height: 85),
        CGSize(width: 168, height: 105),
        CGSize(width: 208, height: 130),
    ]

    /// Circular scrim behind a small glyph badge — the share badge and the pin's close button.
    public static let badgeScrim = NSColor.black.withAlphaComponent(0.45)

    // MARK: Glyph controls (see HoverButton)
    /// Corner radius of the fill behind a 22pt glyph button. Small enough to read as a squircle
    /// under the symbol rather than a pill around it.
    public static let radiusControl: CGFloat = 5
    /// How much white a glyph control's fill picks up under the pointer, and while held. Both are
    /// read against the card's own scrim, which is what the buttons sit on.
    public static let controlHoverAlpha: CGFloat = 0.22
    public static let controlPressAlpha: CGFloat = 0.36
    /// Hover fade. Long enough not to strobe as the pointer crosses a row of seven buttons,
    /// short enough that the fill arrives with the pointer rather than after it.
    public static let controlFade: TimeInterval = 0.12

    /// A glyph control's fill, brightened by `alpha` over the fill it rests on.
    ///
    /// Composites rather than replaces, because the two card surfaces disagree about what a
    /// resting control looks like: the overlay's chrome is invisible until hovered and wants
    /// plain white, while the pin's close button rests on a scrim that is the only reason its
    /// glyph is legible over arbitrary pinned content — replacing that with translucent white
    /// would brighten the button by erasing the thing that made it readable.
    ///
    /// Only the colour lifts. `NSColor.blended` mixes alpha as well, which would have made that
    /// scrim steadily more opaque as it lit up; how much it weighs is a deliberate token, and
    /// only its colour should answer the pointer.
    public static func controlFill(over resting: NSColor?, brightenedBy alpha: CGFloat) -> NSColor {
        guard let resting else { return NSColor.white.withAlphaComponent(alpha) }
        // Conversion only fails for a pattern colour, which nothing here uses. Keeping the scrim
        // and losing the highlight is the safe way to fail: the reverse erases what it is for.
        guard let base = resting.usingColorSpace(.sRGB) else { return resting }
        func lift(_ c: CGFloat) -> CGFloat { c + (1 - c) * alpha }
        return NSColor(srgbRed: lift(base.redComponent), green: lift(base.greenComponent),
                       blue: lift(base.blueComponent), alpha: base.alphaComponent)
    }

    // MARK: Motion; honor Reduce Motion
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Overshoots slightly at the end — what a settling spring looks like. Used where something
    /// snaps back to a resting position rather than travelling to a new one.
    public static let springBack = CAMediaTimingFunction(controlPoints: 0.22, 1.35, 0.36, 1)

    public static func animate(_ duration: TimeInterval,
                               timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut),
                               _ body: () -> Void, completion: (() -> Void)? = nil) {
        // Reduce Motion is a duration of zero, not a different code path. Every caller drives an
        // `animator()` proxy, which animates against the ambient NSAnimationContext — 0.25s by
        // default — so running the body outside a group honoured the setting in none of them.
        // One group either way also keeps the mechanism identical: a body relying on implicit
        // layer animation must not quietly take a different route when the setting is on.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : duration
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            body()
        }, completionHandler: completion)
    }
}
