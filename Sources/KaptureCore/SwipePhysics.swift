// The arithmetic behind swipe-to-dismiss, kept apart from the view so it can be tested without
// a trackpad. The behavior it aims at is a macOS notification banner: the card follows the
// finger exactly toward the edge, resists in the other direction, and on release either carries
// on off the screen or springs back.
import Foundation
import CoreGraphics

public enum SwipePhysics {
    /// Past this fraction of the card's width, letting go dismisses.
    public static let dismissFraction: CGFloat = 0.32
    /// …or this speed, in points per second, so a quick flick doesn't have to travel far.
    public static let dismissVelocity: CGFloat = 650
    /// A flick still has to be a deliberate movement rather than a twitch.
    public static let minimumFlickTravel: CGFloat = 12

    /// Where the card sits for a given gesture distance. `progress` is positive toward the edge.
    ///
    /// Toward the edge it tracks 1:1 — anything else feels like lag. Away from it the movement
    /// is rubber-banded: it never blocks the gesture outright, but it asymptotes, so pulling a
    /// card away from its edge can't be mistaken for dismissing it.
    public static func offset(progress: CGFloat, width: CGFloat) -> CGFloat {
        guard progress < 0 else { return progress }
        let width = max(width, 1)
        return -(1 - 1 / (-progress / width * 0.55 + 1)) * width
    }

    /// Whether letting go here should dismiss the card.
    public static func shouldDismiss(progress: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        if velocity > dismissVelocity && progress > minimumFlickTravel { return true }
        return progress > width * dismissFraction
    }

    /// How long the card should take to clear the edge, carrying the speed it already had: a
    /// hard flick leaves fast, a slow push drifts out. Clamped so it is never a jump or a crawl.
    public static func flyOffDuration(remaining: CGFloat, velocity: CGFloat) -> TimeInterval {
        let seconds = TimeInterval(max(remaining, 0) / max(velocity, 900))
        return min(max(seconds, 0.12), 0.3)
    }
}
