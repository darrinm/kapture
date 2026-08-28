// Swipe-to-dismiss is judged by feel, but the arithmetic under it can still be pinned down:
// tracking has to be exact, resistance has to be monotonic and bounded, and the release
// decision has to agree with what the card looked like it was about to do.
import XCTest
@testable import KaptureCore

final class SwipePhysicsTests: XCTestCase {
    private let width: CGFloat = 260
    /// A card, for the tests that need both dimensions.
    private let card = CGSize(width: 320, height: 200)

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

    // MARK: weight
    //
    // The lean and the spin are judged by eye, but their arithmetic still has to hold: bounded so
    // the card never pinwheels, signed so it leans the way it is pushed, and — the one that shows
    // up as a visual bug rather than a wrong number — the window clearance a rotation needs.

    func testTheLeanFollowsThePushAndIsBounded() {
        for distance in stride(from: CGFloat(-600), through: 600, by: 50) {
            let tilt = SwipePhysics.tilt(offset: distance, width: width)
            XCTAssertLessThanOrEqual(abs(tilt), SwipePhysics.maxDragTilt,
                                     "a dragged card must never wind up into a pinwheel")
            if distance > 0 { XCTAssertGreaterThan(tilt, 0, "leans the way it is pushed") }
            if distance < 0 { XCTAssertLessThan(tilt, 0) }
        }
        XCTAssertEqual(SwipePhysics.tilt(offset: 0, width: width), 0, accuracy: 0.001)
    }

    func testTheLeanGrowsWithTheGesture() {
        // proportional, not a threshold: the tilt should emerge from the drag, not appear at once
        var previous = SwipePhysics.tilt(offset: 0, width: width)
        for distance in stride(from: CGFloat(10), through: width, by: 10) {
            let tilt = SwipePhysics.tilt(offset: distance, width: width)
            XCTAssertGreaterThan(tilt, previous)
            previous = tilt
        }
    }

    // MARK: the exit is diagonal, because the gesture was

    func testAFlungCardLeavesAlongTheGestureNotTheAxis() {
        // thrown right and upward: it must not snap to dead sideways on release
        let up = SwipePhysics.flyOffDirection(dx: 120, dy: 60, towardEdge: 1)
        XCTAssertGreaterThan(up.dx, 0, "still leaves by the edge it was pushed toward")
        XCTAssertGreaterThan(up.dy, 0, "and carries the upward part of the throw")

        let down = SwipePhysics.flyOffDirection(dx: 120, dy: -60, towardEdge: 1)
        XCTAssertLessThan(down.dy, 0, "a downward throw leaves downward")
        XCTAssertEqual(up.dx, down.dx, accuracy: 0.001)
    }

    func testAFlatSwipeStillLeavesFlat() {
        let flat = SwipePhysics.flyOffDirection(dx: 200, dy: 0, towardEdge: 1)
        XCTAssertEqual(flat.dy, 0, accuracy: 0.001)
        XCTAssertEqual(flat.dx, 1, accuracy: 0.001)
    }

    func testTheExitAlwaysHeadsForTheEdgeItWasDismissedToward() {
        // dismissal is defined by the edge, so the horizontal sign comes from the edge and never
        // from the gesture — otherwise a sloppy swipe could fly the card the wrong way
        for dx in [CGFloat(-300), -50, 50, 300] {
            XCTAssertLessThan(SwipePhysics.flyOffDirection(dx: dx, dy: 40, towardEdge: -1).dx, 0)
            XCTAssertGreaterThan(SwipePhysics.flyOffDirection(dx: dx, dy: 40, towardEdge: 1).dx, 0)
        }
    }

    func testASteepThrowIsCappedSoItLeavesBySideNotTop() {
        let steep = SwipePhysics.flyOffDirection(dx: 20, dy: 900, towardEdge: 1)
        XCTAssertLessThanOrEqual(abs(steep.dy / steep.dx), SwipePhysics.maxFlyOffSlope + 0.001)
        XCTAssertGreaterThan(steep.dx, 0.5, "still substantially sideways")
    }

    func testTheExitDirectionIsAUnitVector() {
        // the panel multiplies it by a travel distance, so any other length changes how far the
        // card actually goes
        for (dx, dy) in [(CGFloat(100), CGFloat(0)), (100, 100), (10, 500), (-80, -40)] {
            let v = SwipePhysics.flyOffDirection(dx: dx, dy: dy, towardEdge: 1)
            XCTAssertEqual((v.dx * v.dx + v.dy * v.dy).squareRoot(), 1, accuracy: 0.001)
        }
    }

    func testAFlungCardAlwaysTurnsAndHarderWhenFlickedHarder() {
        let flat = SwipePhysics.flyOffDirection(dx: 200, dy: 0, towardEdge: 1)
        let gentle = abs(SwipePhysics.spin(velocity: 200, direction: flat))
        let hard = abs(SwipePhysics.spin(velocity: 2000, direction: flat))
        XCTAssertGreaterThan(gentle, 0, "even a slow dismissal turns — square is 'on rails'")
        XCTAssertGreaterThan(hard, gentle)

    }

    func testTheTurnSaturatesRatherThanRunningAway() {
        let directions = [(CGFloat(100), CGFloat(0)), (100, 400), (100, -400), (-100, 90)]
            .map { SwipePhysics.flyOffDirection(dx: $0.0, dy: $0.1, towardEdge: $0.0 < 0 ? -1 : 1) }
        for velocity in stride(from: CGFloat(0), through: 8000, by: 250) {
            for direction in directions {
                XCTAssertLessThanOrEqual(abs(SwipePhysics.spin(velocity: velocity, direction: direction)),
                                         SwipePhysics.maxFlingSpin)
            }
        }
    }

    func testTheTurnMirrorsWithTheEdge() {
        let right = SwipePhysics.flyOffDirection(dx: 200, dy: 0, towardEdge: 1)
        let left = SwipePhysics.flyOffDirection(dx: -200, dy: 0, towardEdge: -1)
        XCTAssertEqual(SwipePhysics.spin(velocity: 900, direction: right),
                       -SwipePhysics.spin(velocity: 900, direction: left), accuracy: 0.001)
    }

    func testADiagonalThrowTurnsMoreThanAFlatOne() {
        // the shove is further off the card's centre, so it should tumble more, not the same
        let flat = SwipePhysics.flyOffDirection(dx: 200, dy: 0, towardEdge: 1)
        let up = SwipePhysics.flyOffDirection(dx: 200, dy: 200, towardEdge: 1)
        let down = SwipePhysics.flyOffDirection(dx: 200, dy: -200, towardEdge: 1)
        for diagonal in [up, down] {
            XCTAssertGreaterThan(abs(SwipePhysics.spin(velocity: 900, direction: diagonal)),
                                 abs(SwipePhysics.spin(velocity: 900, direction: flat)),
                                 "a diagonal toss is further off centre, so it must turn more")
        }
        // and either diagonal turns the same amount: up and down are mirror images of one throw
        XCTAssertEqual(SwipePhysics.spin(velocity: 900, direction: up),
                       SwipePhysics.spin(velocity: 900, direction: down), accuracy: 0.001)
    }

    /// The one that bites visually: too little clearance and the window shears the card's corners
    /// off at exactly the moment the rotation becomes visible.
    func testClearanceCoversTheRotatedCard() {
        XCTAssertEqual(SwipePhysics.verticalClearance(width: card.width, height: card.height, degrees: 0),
                       0, accuracy: 0.001, "an upright card needs no room")

        // Checked by rotating the card's four actual corners, not by re-deriving the formula: an
        // assertion that recomputes the implementation compares it to itself and cannot fail.
        for degrees in stride(from: CGFloat(1), through: 30, by: 1) {
            let pad = SwipePhysics.verticalClearance(width: card.width, height: card.height,
                                                     degrees: degrees)
            let rotation = CGAffineTransform(rotationAngle: degrees * .pi / 180)
            let corners = [CGPoint(x: -card.width / 2, y: -card.height / 2),
                           CGPoint(x: card.width / 2, y: -card.height / 2),
                           CGPoint(x: card.width / 2, y: card.height / 2),
                           CGPoint(x: -card.width / 2, y: card.height / 2)]
            let highest = corners.map { abs($0.applying(rotation).y) }.max()!
            XCTAssertEqual(pad, highest - card.height / 2, accuracy: 0.001,
                           "\(degrees)deg: the padding must reach the corner that sticks out")
        }

        XCTAssertEqual(SwipePhysics.verticalClearance(width: card.width, height: card.height, degrees: -12),
                       SwipePhysics.verticalClearance(width: card.width, height: card.height, degrees: 12),
                       accuracy: 0.001, "leaning either way needs the same room")
    }

    /// `maxRotation` is what the panel reserves window space for, so nothing the card can do may
    /// exceed it — otherwise the corners are clipped at the moment the rotation becomes visible.
    func testNothingTheCardCanDoExceedsTheReservedRotation() {
        for dy in stride(from: CGFloat(-400), through: 400, by: 50) {
            for velocity in stride(from: CGFloat(0), through: 10_000, by: 500) {
                for edge in [CGFloat(-1), 1] {
                    let direction = SwipePhysics.flyOffDirection(dx: 200 * edge, dy: dy, towardEdge: edge)
                    let total = SwipePhysics.tilt(offset: card.width * edge, width: card.width)
                        + SwipePhysics.spin(velocity: velocity, direction: direction)
                    XCTAssertLessThanOrEqual(abs(total), SwipePhysics.maxRotation + 0.001,
                                             "dy \(dy) at \(velocity) turns further than the window allows")
                }
            }
        }
    }
}
