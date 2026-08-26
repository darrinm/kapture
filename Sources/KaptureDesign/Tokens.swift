// KaptureDesign: the in-repo design system. Every surface draws from these tokens.
import AppKit

public enum Tokens {
    // MARK: Color
    public static let accent = NSColor(srgbRed: 0.78, green: 0.26, blue: 0.23, alpha: 1)  // record red #C7423A
    public static let overlayScrim = NSColor.black.withAlphaComponent(0.38)

    // MARK: Spacing & radius
    public static let cornerMargin: CGFloat = 16
    public static let stackGap: CGFloat = 8
    public static let radiusOverlay: CGFloat = 10

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

    // MARK: Motion; honor Reduce Motion
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static func animate(_ duration: TimeInterval, _ body: () -> Void, completion: (() -> Void)? = nil) {
        if reduceMotion {
            body(); completion?()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                body()
            }, completionHandler: completion)
        }
    }
}
