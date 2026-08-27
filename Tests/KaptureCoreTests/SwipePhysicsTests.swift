// Swipe-to-dismiss is judged by feel, but the arithmetic under it can still be pinned down:
// tracking has to be exact, resistance has to be monotonic and bounded, and the release
// decision has to agree with what the card looked like it was about to do.
import XCTest
@testable import KaptureCore

final class SwipePhysicsTests: XCTestCase {
    private let width: CGFloat = 260

    func testTrackingTowardTheEdgeIsExact() {
        // any lag here reads as the card not keeping up with the finger
        for distance in stride(from: CGFloat(0), through: 400, by: 40) {
            XCTAssertEqual(SwipePhysics.offset(progress: distance, width: width), distance,
                           accuracy: 0.001)
        }
    }

    func testTheWrongDirectionResistsWithoutStopping() {
        var previous: CGFloat = 0
        for distance in stride(from: CGFloat(10), through: 600, by: 10) {
            let offset = SwipePhysics.offset(progress: -distance, width: width)
            XCTAssertLessThan(offset, 0, "the card still answers the gesture")
            XCTAssertGreaterThan(abs(offset), abs(previous), "and keeps moving, just less")
            XCTAssertLessThan(abs(offset), distance, "always less than the finger travelled")
            XCTAssertLessThan(abs(offset), width, "never further than its own width")
            previous = offset
        }
    }

    func testAShortSlowDragSpringsBack() {
        XCTAssertFalse(SwipePhysics.shouldDismiss(progress: 40, velocity: 120, width: width))
        XCTAssertFalse(SwipePhysics.shouldDismiss(progress: 0, velocity: 0, width: width))
    }

    func testPastAThirdOfTheCardDismisses() {
        let threshold = width * SwipePhysics.dismissFraction
        XCTAssertFalse(SwipePhysics.shouldDismiss(progress: threshold - 1, velocity: 0, width: width))
        XCTAssertTrue(SwipePhysics.shouldDismiss(progress: threshold + 1, velocity: 0, width: width))
    }

    func testAFastFlickDismissesEarly() {
        // the gesture that matters most: a short, quick push toward the edge
        XCTAssertTrue(SwipePhysics.shouldDismiss(progress: 30, velocity: 1400, width: width))
        // but speed alone isn't enough — a twitch on a stationary card is not a dismissal
        XCTAssertFalse(SwipePhysics.shouldDismiss(progress: 5, velocity: 1400, width: width))
    }

    func testDraggingBackwardsNeverDismisses() {
        XCTAssertFalse(SwipePhysics.shouldDismiss(progress: -200, velocity: 0, width: width))
        XCTAssertFalse(SwipePhysics.shouldDismiss(progress: -200, velocity: 2000, width: width))
    }

    func testFlyOffKeepsTheGesturesSpeedWithinLimits() {
        let fast = SwipePhysics.flyOffDuration(remaining: 200, velocity: 3000)
        let slow = SwipePhysics.flyOffDuration(remaining: 200, velocity: 700)
        XCTAssertLessThan(fast, slow, "a harder flick leaves faster")
        for velocity in stride(from: CGFloat(0), through: 6000, by: 250) {
            let duration = SwipePhysics.flyOffDuration(remaining: 300, velocity: velocity)
            XCTAssertGreaterThanOrEqual(duration, 0.12, "never an instant jump")
            XCTAssertLessThanOrEqual(duration, 0.3, "never a crawl")
        }
    }
}
