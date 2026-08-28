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

    // MARK: weight
    //
    // A card that only translates reads as a rectangle being moved. A real one pivots as it is
    // pushed and keeps turning once it is let go, and that is most of the difference between
    // "a window animated across the screen" and "an object on a desk".

    /// Degrees a card leans at full displacement.
    public static let maxDragTilt: CGFloat = 5
    /// Degrees a flung card adds on its way out, at or above `spinSaturationVelocity`.
    public static let maxFlingSpin: CGFloat = 14
    /// Past this speed a flick spins no harder — beyond it the card is leaving either way.
    public static let spinSaturationVelocity: CGFloat = 2200
    /// The most a card can ever be turned: leaned as far as a drag goes, then flung on top of it.
    /// Whatever holds the card has to have room for this much rotation.
    public static let maxRotation = maxDragTilt + maxFlingSpin
    /// How far past the edge a dismissed card travels before it is out of sight.
    public static let flyOffMargin: CGFloat = 60

    /// Symmetric clamp. Written out three times below otherwise, and `max(-x, min(x, v))` is easy
    /// to read past when it is backwards.
    private static func clamped(_ value: CGFloat, to limit: CGFloat) -> CGFloat {
        max(-limit, min(limit, value))
    }

    /// How far the card leans for a given displacement, in degrees; sign follows the push.
    ///
    /// Proportional rather than constant so the lean grows out of the gesture instead of
    /// appearing at a threshold, and clamped at the card's own width so dragging a long way
    /// past the edge does not wind it up into a pinwheel.
    public static func tilt(offset: CGFloat, width: CGFloat) -> CGFloat {
        let width = max(width, 1)
        let fraction = clamped(offset / width, to: 1)
        return fraction * maxDragTilt
    }

    /// Steepest angle a flung card leaves at — 1.0 is 45°.
    public static let maxFlyOffSlope: CGFloat = 1.0

    /// The unit vector a flung card leaves along.
    ///
    /// Hardly any swipe is purely horizontal, and a card that snaps to dead sideways on release
    /// looks like it was put on rails at the last moment — so the vertical part of the gesture is
    /// carried into the exit. The horizontal part is not: it is forced toward the edge, because
    /// leaving by that edge is what dismissing *means*. The slope is capped so a steep diagonal
    /// still departs by the side of the screen rather than the top.
    ///
    /// `dy` is in gesture terms, where negative is downward, matching `scrollingDeltaY`.
    public static func flyOffDirection(dx: CGFloat, dy: CGFloat, towardEdge: CGFloat) -> CGVector {
        let horizontal = max(abs(dx), 0.001)
        let slope = clamped(dy / horizontal, to: maxFlyOffSlope)
        let length = (1 + slope * slope).squareRoot()
        return CGVector(dx: (towardEdge < 0 ? -1 : 1) / length, dy: slope / length)
    }

    /// Extra degrees added as the card flies off, scaled by how hard it was flicked.
    ///
    /// Never zero: a card dismissed by a slow push still turns as it goes, because one that slides
    /// out perfectly square looks like it is on rails. The sense of the turn is the trailing edge
    /// lagging behind the push. A diagonal toss turns a little more than a flat one — the shove is
    /// further off the card's centre — but only by up to 12%, and not at all once the clamp bites.
    public static func spin(velocity: CGFloat, direction: CGVector) -> CGFloat {
        let speed = min(abs(velocity), spinSaturationVelocity)
        let share = 0.35 + 0.65 * (speed / spinSaturationVelocity)
        // Sense from the edge alone, size from the shove. |dy| rather than dy so the two
        // diagonals are mirror images; signed, one of them cancelled the turn instead.
        let sense: CGFloat = direction.dx < 0 ? 1 : -1
        let lag = sense * (abs(direction.dx) + abs(direction.dy) * 0.5)
        return clamped(lag * maxFlingSpin * share, to: maxFlingSpin)
    }

    /// Half the extra height a rotated card needs beyond its upright box.
    ///
    /// This is where the clipping constraint lives, and callers refer to it rather than restating
    /// it: a card is rotated inside a window, and a window clips whatever leaves its bounds, so
    /// the window must be grown by this much above and below *before* anything turns — otherwise
    /// the corners shear off at exactly the moment the rotation becomes visible.
    public static func verticalClearance(width: CGFloat, height: CGFloat, degrees: CGFloat) -> CGFloat {
        let radians = abs(degrees) * .pi / 180
        let rotatedHeight = width * sin(radians) + height * cos(radians)
        return max(0, (rotatedHeight - height) / 2)
    }
}
