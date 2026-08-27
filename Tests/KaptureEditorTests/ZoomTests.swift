// Zoom anchoring is the kind of arithmetic that looks right and feels wrong: magnify about the
// pointer and the thing under it must not drift. Verified here rather than by squinting.
import XCTest
import AppKit
@testable import KaptureEditor

@MainActor
final class ZoomTests: XCTestCase {
    private func makeCanvas(_ width: Int = 400, _ height: Int = 300) -> CanvasView {
        TestCanvas.make(image: TestImages.blank(width, height),
                        frame: NSSize(width: 800, height: 600))
    }

    func testStartsFittedAndClampsToFitAsTheFloor() {
        let canvas = makeCanvas()
        XCTAssertEqual(canvas.zoom, 1)
        XCTAssertEqual(canvas.imageRect, canvas.fittedRect)

        // you cannot zoom out past fit — there is nothing out there to see
        canvas.setZoom(0.25)
        XCTAssertEqual(canvas.zoom, 1)
        XCTAssertEqual(canvas.imageRect, canvas.fittedRect)
    }

    func testZoomIsCappedSoTheCanvasCannotRunAway() {
        let canvas = makeCanvas()
        canvas.setZoom(1000)
        XCTAssertLessThanOrEqual(canvas.zoom, 8)
        XCTAssertGreaterThan(canvas.zoom, 1)
    }

    func testMagnifyingKeepsThePointUnderTheAnchorInPlace() {
        let canvas = makeCanvas()
        // a point off-centre, so a naive centre-anchored zoom would visibly drift
        let anchor = CGPoint(x: 250, y: 400)
        let before = canvas.imageRect
        let u = (anchor.x - before.minX) / before.width
        let v = (anchor.y - before.minY) / before.height

        canvas.setZoom(3, anchor: anchor)

        let after = canvas.imageRect
        XCTAssertEqual(after.minX + u * after.width, anchor.x, accuracy: 0.5,
                       "the image drifted horizontally under the pointer")
        XCTAssertEqual(after.minY + v * after.height, anchor.y, accuracy: 0.5,
                       "the image drifted vertically under the pointer")
    }

    func testMagnifiedCanvasAlwaysCoversTheView() {
        let canvas = makeCanvas()
        canvas.setZoom(4, anchor: CGPoint(x: 0, y: 0))
        let r = canvas.imageRect
        XCTAssertLessThanOrEqual(r.minX, canvas.bounds.minX + 0.5, "gap on the left")
        XCTAssertGreaterThanOrEqual(r.maxX, canvas.bounds.maxX - 0.5, "gap on the right")
        XCTAssertLessThanOrEqual(r.minY, canvas.bounds.minY + 0.5, "gap below")
        XCTAssertGreaterThanOrEqual(r.maxY, canvas.bounds.maxY - 0.5, "gap above")
    }

    func testReturningToFitRecentresExactly() {
        let canvas = makeCanvas()
        canvas.setZoom(5, anchor: CGPoint(x: 700, y: 100))
        canvas.setZoom(1)
        XCTAssertEqual(canvas.pan, .zero, "fit must forget where the pan was")
        XCTAssertEqual(canvas.imageRect, canvas.fittedRect)
    }

    func testActualSizeShowsOneImagePixelPerPoint() {
        // the real case: a capture bigger than the window, which fit had to shrink
        let canvas = makeCanvas(2000, 1500)
        XCTAssertEqual(canvas.imageRect.width, 800, accuracy: 0.5, "fit should shrink it to the view")
        canvas.zoomToActualSize()
        XCTAssertEqual(canvas.imageRect.width, 2000, accuracy: 0.5, "1:1 means one image pixel per point")
    }

    /// Fit is the floor, so a capture smaller than the window — which fit has already enlarged —
    /// stays where it is rather than shrinking to a stamp in the middle of an empty canvas.
    func testActualSizeNeverShrinksBelowFit() {
        let canvas = makeCanvas(400, 300)
        canvas.zoomToActualSize()
        XCTAssertEqual(canvas.zoom, 1)
        XCTAssertEqual(canvas.imageRect, canvas.fittedRect)
    }
}
