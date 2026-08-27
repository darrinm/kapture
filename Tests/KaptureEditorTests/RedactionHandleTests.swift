// A redaction you cannot resize is one you have to delete and redraw to nudge. These pin the
// handles onto the rect family and check that a resize actually re-renders.
import XCTest
import AppKit
@testable import KaptureEditor

@MainActor
final class RedactionHandleTests: XCTestCase {
    private func makeCanvas() -> CanvasView { TestCanvas.make() }

    private func layer(_ tool: Tool) -> Annotation {
        Annotation(tool: tool, points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 80)],
                   colorHex: "#000000", strokeWidth: 4)
    }

    func testRedactionsHaveResizeHandles() {
        let canvas = makeCanvas()
        for tool in [Tool.blur, .pixelate] {
            XCTAssertEqual(canvas.handlePositions(of: layer(tool)).count, 2,
                           "\(tool.rawValue) has no resize handles")
        }
    }

    func testTheRestOfTheRectFamilyIsUnchanged() {
        let canvas = makeCanvas()
        for tool in [Tool.rect, .ellipse, .highlight, .arrow, .line] {
            XCTAssertEqual(canvas.handlePositions(of: layer(tool)).count, 2, tool.rawValue)
        }
        XCTAssertTrue(canvas.handlePositions(of: layer(.freehand)).isEmpty,
                      "freehand is a path, not a box")
    }

    /// Resizing must re-render. The effect cache is keyed by rect, and a stale patch would leave
    /// the old region showing at the new size — a redaction that no longer covers what it did.
    func testResizingProducesADifferentPatch() throws {
        let base = TestImages.blank(200, 200, fill: .systemRed)

        let small = try XCTUnwrap(AnnotationEffects.render(
            tool: .pixelate, rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            intensity: 16, base: base))
        let grown = try XCTUnwrap(AnnotationEffects.render(
            tool: .pixelate, rect: CGRect(x: 10, y: 10, width: 120, height: 90),
            intensity: 16, base: base))

        XCTAssertNotEqual(small.width, grown.width, "the resized redaction reused the old patch")
        XCTAssertEqual(grown.width, 120)
        XCTAssertEqual(grown.height, 90)
    }
}
