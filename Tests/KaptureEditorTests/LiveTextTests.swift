// Live Text in the editor. What can go wrong: words under a redaction become selectable, the
// overlay drifts off the image under zoom or crop, or a text drag takes a press that belonged to
// an annotation or a drawing tool.
import XCTest
import AppKit
@testable import KaptureEditor

final class LiveTextSourceTests: XCTestCase {
    func testWithNoRedactionsTheBaseIsAnalyzedAsIs() throws {
        let base = TestImages.blank(fill: .white)
        XCTAssertTrue(try XCTUnwrap(AnnotationRenderer.liveTextSource(base: base, covered: [])) === base)
    }

    /// Filled in image space (top-left origin). A rect filled bottom-up would leave the words it
    /// covers readable and black out text nobody redacted.
    func testARedactionIsFilledSolidWhereItIsAndNowhereElse() throws {
        let base = TestImages.blank(fill: .white)
        let rect = CGRect(x: 20, y: 20, width: 60, height: 60)
        let out = try XCTUnwrap(AnnotationRenderer.liveTextSource(base: base, covered: [rect]))

        XCTAssertEqual(out.width, base.width)
        XCTAssertEqual(out.height, base.height)
        let inside = TestImages.pixel(out, x: 50, y: 50)
        XCTAssertEqual(inside.r + inside.g + inside.b, 0, "the redacted region is still readable")
        let mirrored = TestImages.pixel(out, x: 50, y: 150)
        XCTAssertGreaterThan(mirrored.r, 250, "the fill landed upside down")
        let outside = TestImages.pixel(out, x: 150, y: 50)
        XCTAssertGreaterThan(outside.r, 250, "the fill leaked outside its rect")
    }

    /// A drag that starts inside an applied crop can extend past its edge, so the text the crop
    /// removed is filled solid and only the crop stays readable.
    func testEverythingOutsideAnAppliedCropIsFilled() throws {
        let base = TestImages.blank(fill: .white)
        let crop = CGRect(x: 0, y: 0, width: 100, height: 100)   // the top-left quarter
        let out = try XCTUnwrap(AnnotationRenderer.liveTextSource(base: base, covered: [], crop: crop))
        let inside = TestImages.pixel(out, x: 50, y: 50)
        XCTAssertGreaterThan(inside.r, 250, "the crop itself was filled")
        for (x, y) in [(150, 50), (50, 150), (150, 150)] {
            let p = TestImages.pixel(out, x: x, y: y)
            XCTAssertEqual(p.r + p.g + p.b, 0, "text removed by the crop is readable at \(x),\(y)")
        }
    }

    /// A solid box over an account number hides it as well as a blur does.
    func testFilledShapesHideTextAndOutlinesDoNot() {
        func layer(_ tool: Tool, filled: Bool? = nil) -> Annotation {
            var a = Annotation(tool: tool, points: [.zero, CGPoint(x: 10, y: 10)],
                               colorHex: "#000000", strokeWidth: 1)
            a.filled = filled
            return a
        }
        XCTAssertTrue(layer(.blur).hidesText)
        XCTAssertTrue(layer(.pixelate).hidesText)
        XCTAssertTrue(layer(.rect, filled: true).hidesText)
        XCTAssertTrue(layer(.ellipse, filled: true).hidesText)
        XCTAssertFalse(layer(.rect).hidesText)
        XCTAssertFalse(layer(.ellipse, filled: false).hidesText)
        XCTAssertFalse(layer(.highlight).hidesText)
        XCTAssertFalse(layer(.arrow).hidesText)
    }

    /// What a pin checks in the sidecar: any text-hiding layer turns its Live Text off.
    func testASavedLayerStackReportsWhetherItHidesText() {
        let blur = Annotation(tool: .blur, points: [.zero, CGPoint(x: 10, y: 10)],
                              colorHex: "#000000", strokeWidth: 1)
        let arrow = Annotation(tool: .arrow, points: [.zero, CGPoint(x: 10, y: 10)],
                               colorHex: "#000000", strokeWidth: 1)
        XCTAssertTrue(AnnotationCodec.hidesText(AnnotationCodec.encode([arrow, blur])))
        XCTAssertFalse(AnnotationCodec.hidesText(AnnotationCodec.encode([arrow])))
        XCTAssertFalse(AnnotationCodec.hidesText(nil))
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

    /// Selection works with the select tool only, so the editor analyzes nothing until it is
    /// chosen, and re-analyzes when a layer that hides text changes.
    func testAnalysisWaitsForTheSelectToolAndFollowsCoveredLayers() {
        var box = rect
        box.filled = true
        let canvas = TestCanvas.make(layers: [box], tool: .arrow)
        XCTAssertNil(canvas.liveTextCovered, "analyzed before the select tool was chosen")
        canvas.tool = .select
        XCTAssertEqual(canvas.liveTextCovered, [box.rect, .null])
        canvas.layers = []
        XCTAssertEqual(canvas.liveTextCovered, [.null])
    }

    func testZoomMagnifiesTheOverlayWithTheImage() {
        let canvas = TestCanvas.make(tool: .select)
        canvas.setZoom(2)
        canvas.viewWillDraw()
        XCTAssertEqual(canvas.liveTextClip.frame, CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(canvas.liveText.frame, CGRect(x: -200, y: -200, width: 800, height: 800))
    }
}
