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
    public static let radiusButton: CGFloat = 6

    // MARK: Overlay sizing (3 steps; index by settings)
    public static let overlaySizes: [CGSize] = [
        CGSize(width: 136, height: 85),
        CGSize(width: 168, height: 105),
        CGSize(width: 208, height: 130),
    ]

    // MARK: Motion (spring response/damping); honor Reduce Motion
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    public static let springResponse: Double = 0.35
    public static let springDamping: Double = 0.8

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
