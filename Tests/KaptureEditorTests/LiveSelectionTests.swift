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
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let canvas = CanvasView(image: ctx.makeImage()!, layers: [rect])
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        canvas.tool = tool
        if selecting { canvas.selectMostRecent() }
        return canvas
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
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let blur = Annotation(tool: .blur, points: [CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 120)],
                              colorHex: "#000000", strokeWidth: 1)
        let canvas = CanvasView(image: ctx.makeImage()!, layers: [blur])
        canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        canvas.tool = .blur
        canvas.selectMostRecent()

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
}
