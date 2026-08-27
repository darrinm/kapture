// The editing model: what you just drew stays live and manipulable with the same tool in hand,
// and a press outside it starts the next element. These pin what a press does, which is the
// whole of the model.
import XCTest
import AppKit
@testable import KaptureEditor

@MainActor
final class LiveSelectionTests: XCTestCase {
    private let rect = Annotation(tool: .rect, points: [CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 120)],
                                  colorHex: "#FF0000", strokeWidth: 6)

    private func makeCanvas(tool: Tool, selecting: Bool) -> CanvasView {
        TestCanvas.make(layers: [rect], tool: tool, selectingMostRecent: selecting)
    }

    func testACornerOfTheLiveElementResizesIt() {
        let canvas = makeCanvas(tool: .rect, selecting: true)
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 40, y: 40)), .resizeLive(0))
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 140, y: 120)), .resizeLive(1))
    }

    func testTheBodyOfTheLiveElementMovesIt() {
        let canvas = makeCanvas(tool: .rect, selecting: true)
        // on the stroke, which is what a rectangle's body is when it isn't filled
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 90, y: 40)), .moveLive)
    }

    func testAPressAwayFromItStartsANewElement() {
        let canvas = makeCanvas(tool: .rect, selecting: true)
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 300, y: 300)), .newElement)
    }

    func testWithNothingLiveEveryPressStartsANewElement() {
        let canvas = makeCanvas(tool: .rect, selecting: false)
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 90, y: 40)), .newElement)
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 40, y: 40)), .newElement)
    }

    /// The redaction tools are the ones this model matters most for — a blur usually needs a
    /// nudge right after it is drawn.
    func testRedactionsAreLiveToo() {
        let blur = Annotation(tool: .blur, points: [CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 120)],
                              colorHex: "#000000", strokeWidth: 1)
        let canvas = TestCanvas.make(layers: [blur], tool: .blur, selectingMostRecent: true)

        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 140, y: 120)), .resizeLive(1))
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 90, y: 80)), .moveLive, "inside the region")
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 350, y: 350)), .newElement)
    }

    /// Select and crop keep their own dispatch, which already handled this; the new rule must
    /// not shadow them.
    func testSelectAndCropToolsAreLeftAlone() {
        for tool in [Tool.select, .crop] {
            let canvas = makeCanvas(tool: tool, selecting: true)
            XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 40, y: 40)), .newElement,
                           "\(tool.rawValue) should fall through to its own handling")
        }
    }

    func testClearingSelectionMakesEveryPressANewElement() {
        let canvas = makeCanvas(tool: .rect, selecting: true)
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 40, y: 40)), .resizeLive(0))
        canvas.clearSelection()
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 40, y: 40)), .newElement)
    }

    // MARK: pressing one of the same kind takes it up instead of drawing over it

    /// Two rectangles well apart, the second of them live.
    private func twoRects() -> (CanvasView, Annotation, Annotation) {
        let far = Annotation(tool: .rect, points: [CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 280)],
                             colorHex: "#00FF00", strokeWidth: 6)
        let canvas = TestCanvas.make(layers: [rect, far], tool: .rect, selectingMostRecent: true)
        return (canvas, rect, far)
    }

    func testPressingAnotherOfTheSameKindSelectsIt() {
        let (canvas, other, _) = twoRects()
        // the most recent one is live — its own corner still resizes it
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 200, y: 200)), .resizeLive(0))
        // on the first rectangle's stroke, which is outside the live one
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 90, y: 40)), .selectOther(other.id))
    }

    /// The point of restricting it to the same kind: an arrow drawn across a screenshot crosses
    /// the boxes already on it, and grabbing one would make the arrow tool unusable.
    func testPressingSomethingOfAnotherKindStillStartsANewElement() {
        let arrow = Annotation(tool: .arrow, points: [CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 280)],
                               colorHex: "#00FF00", strokeWidth: 6)
        let canvas = TestCanvas.make(layers: [rect, arrow], tool: .arrow, selectingMostRecent: true)
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 90, y: 40)), .newElement,
                       "a rectangle must not answer a press made with the arrow tool live")
    }

    func testTheTopmostOfTheSameKindWins() {
        let under = Annotation(tool: .rect, points: [CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 120)],
                               colorHex: "#0000FF", strokeWidth: 6)
        let over = Annotation(tool: .rect, points: [CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 120)],
                              colorHex: "#00FF00", strokeWidth: 6)
        let live = Annotation(tool: .rect, points: [CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 280)],
                              colorHex: "#FF00FF", strokeWidth: 6)
        let canvas = TestCanvas.make(layers: [under, over, live], tool: .rect, selectingMostRecent: true)
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 90, y: 40)), .selectOther(over.id),
                       "the one drawn last is the one under the pointer")
    }

    func testEmptySpaceStillStartsANewElementWithOthersPresent() {
        let (canvas, _, _) = twoRects()
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 380, y: 20)), .newElement)
    }

    /// The live element keeps priority over the rule: its own handles and body answer first, so
    /// overlapping siblings can never make it unmovable.
    func testTheLiveElementStillWinsOverASiblingBeneathIt() {
        let beneath = Annotation(tool: .rect, points: [CGPoint(x: 30, y: 30), CGPoint(x: 150, y: 130)],
                                 colorHex: "#0000FF", strokeWidth: 6)
        let canvas = TestCanvas.make(layers: [beneath, rect], tool: .rect, selectingMostRecent: true)
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 40, y: 40)), .resizeLive(0))
        XCTAssertEqual(canvas.pressTarget(at: CGPoint(x: 90, y: 40)), .moveLive)
    }
}
