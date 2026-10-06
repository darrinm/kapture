// Live Text in the editor. What can go wrong: words under a redaction become selectable, the
// overlay drifts off the image under zoom or crop, or a text drag takes a press that belonged to
// an annotation or a drawing tool.
import XCTest
import AppKit
@testable import KaptureEditor

final class LiveTextSourceTests: XCTestCase {
    func testWithNoRedactionsTheBaseIsAnalyzedAsIs() throws {
        let base = TestImages.blank(fill: .white)
        XCTAssertTrue(try XCTUnwrap(AnnotationRenderer.liveTextSource(base: base, redactions: [])) === base)
    }

    /// Filled in image space (top-left origin). A rect filled bottom-up would leave the words it
    /// covers readable and black out text nobody redacted.
    func testARedactionIsFilledSolidWhereItIsAndNowhereElse() throws {
        let base = TestImages.blank(fill: .white)
        let rect = CGRect(x: 20, y: 20, width: 60, height: 60)
        let out = try XCTUnwrap(AnnotationRenderer.liveTextSource(base: base, redactions: [rect]))

        XCTAssertEqual(out.width, base.width)
        XCTAssertEqual(out.height, base.height)
        let inside = TestImages.pixel(out, x: 50, y: 50)
        XCTAssertEqual(inside.r + inside.g + inside.b, 0, "the redacted region is still readable")
        let mirrored = TestImages.pixel(out, x: 50, y: 150)
        XCTAssertGreaterThan(mirrored.r, 250, "the fill landed upside down")
        let outside = TestImages.pixel(out, x: 150, y: 50)
        XCTAssertGreaterThan(outside.r, 250, "the fill leaked outside its rect")
    }
}

@MainActor
final class LiveTextCanvasTests: XCTestCase {
    // 200×200 image in a 400×400 canvas: 2 view points per image pixel, y flipped.
    private func view(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * 2, y: 400 - y * 2) }

    private let rect = Annotation(tool: .rect, points: [CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 120)],
                                  colorHex: "#FF0000", strokeWidth: 6)

    func testSelectionStartsOnBareImageWithTheSelectTool() {
        let canvas = TestCanvas.make(layers: [rect], tool: .select)
        XCTAssertTrue(canvas.liveTextMayBegin(at: view(90, 80)), "inside an unfilled box")
        XCTAssertTrue(canvas.liveTextMayBegin(at: view(180, 180)), "away from every annotation")
    }

    func testAnAnnotationKeepsItsPress() {
        let canvas = TestCanvas.make(layers: [rect], tool: .select)
        XCTAssertFalse(canvas.liveTextMayBegin(at: view(90, 40)), "on the box's stroke")
    }

    /// An arrow drawn across a line of text has to draw an arrow.
    func testDrawingToolsNeverSelectText() {
        for tool in Tool.allCases where tool != .select {
            let canvas = TestCanvas.make(layers: [rect], tool: tool)
            XCTAssertFalse(canvas.liveTextMayBegin(at: view(180, 180)), tool.rawValue)
        }
    }

    /// An applied crop is a solid layer over the whole visible image; it must not block text.
    func testAnAppliedCropDoesNotBlockSelection() {
        var crop = Annotation(tool: .crop, points: [.zero, CGPoint(x: 100, y: 100)],
                              colorHex: "#000000", strokeWidth: 1)
        crop.applied = true
        let canvas = TestCanvas.make(layers: [crop], tool: .select)
        XCTAssertTrue(canvas.liveTextMayBegin(at: CGPoint(x: 200, y: 200)))
    }

    func testTheOverlayCoversTheImageAndIsShownOnlyForTheSelectTool() {
        let canvas = TestCanvas.make(tool: .select)
        canvas.viewWillDraw()
        XCTAssertEqual(canvas.liveTextClip.frame, CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(canvas.liveText.frame, CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertFalse(canvas.liveTextClip.isHidden)

        canvas.tool = .arrow
        canvas.viewWillDraw()
        XCTAssertTrue(canvas.liveTextClip.isHidden)
    }

    func testALetterboxedImageClipsToTheImageNotTheCanvas() {
        let canvas = TestCanvas.make(image: TestImages.blank(200, 100), tool: .select)
        canvas.viewWillDraw()
        XCTAssertEqual(canvas.liveTextClip.frame, CGRect(x: 0, y: 100, width: 400, height: 200))
        XCTAssertEqual(canvas.liveText.frame, CGRect(x: 0, y: 0, width: 400, height: 200))
    }

    /// The overlay keeps covering the whole image, so VisionKit's coordinates stay the image's;
    /// the clip shows only the cropped part, so text outside the crop cannot be selected.
    func testAnAppliedCropShowsOnlyTheCroppedPart() {
        var crop = Annotation(tool: .crop, points: [.zero, CGPoint(x: 100, y: 100)],
                              colorHex: "#000000", strokeWidth: 1)
        crop.applied = true
        let canvas = TestCanvas.make(layers: [crop], tool: .select)
        canvas.viewWillDraw()
        XCTAssertEqual(canvas.liveTextClip.frame, CGRect(x: 0, y: 0, width: 400, height: 400))
        // the top-left quarter fills the canvas: the full image is twice its size, hanging below
        XCTAssertEqual(canvas.liveText.frame, CGRect(x: 0, y: -400, width: 800, height: 800))
    }

    func testZoomMagnifiesTheOverlayWithTheImage() {
        let canvas = TestCanvas.make(tool: .select)
        canvas.setZoom(2)
        canvas.viewWillDraw()
        XCTAssertEqual(canvas.liveTextClip.frame, CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(canvas.liveText.frame, CGRect(x: -200, y: -200, width: 800, height: 800))
    }
}
