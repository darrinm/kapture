// Blur and pixelate reproduce the pixels underneath, so the things that can go wrong are
// geometric: the patch lands in the wrong place, or upside down, or leaks outside its rect.
// Those are invisible in a build log and obvious in a pixel.
import XCTest
import AppKit
@testable import KaptureEditor

final class EffectsTests: XCTestCase {
    /// Two captures of the same display are the same size. A cache keyed only by dimensions
    /// served the first capture's patch inside the second capture's redaction — the one place a
    /// stale cache leaks image content, and precisely what redaction exists to prevent.
    func testAPatchIsNeverReusedAcrossCaptures() throws {
        let rect = CGRect(x: 20, y: 20, width: 60, height: 60)
        let fromRed = try XCTUnwrap(AnnotationEffects.render(tool: .pixelate, rect: rect,
                                                             intensity: 16, base: TestImages.blank(fill: .systemRed)))
        let fromBlue = try XCTUnwrap(AnnotationEffects.render(tool: .pixelate, rect: rect,
                                                              intensity: 16, base: TestImages.blank(fill: .systemBlue)))
        let red = TestImages.centre(fromRed), blue = TestImages.centre(fromBlue)
        XCTAssertGreaterThan(red.r, red.b, "the red capture's patch is not red")
        XCTAssertGreaterThan(blue.b, blue.r, "the second capture got the first capture's pixels")
    }

    func testPixelateStaysInsideItsRectAndKeepsTheRegionsColour() throws {
        let base = TestImages.splitRedOverBlue()
        // a block in the red half only
        let layer = Annotation(tool: .pixelate, points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 80)],
                               colorHex: "#000000", strokeWidth: 1)
        let out = try XCTUnwrap(AnnotationRenderer.flatten(base: base, layers: [layer]))

        // inside: still red-dominant. If the patch were mirrored vertically it would be blue here.
        let inside = TestImages.pixel(out, x: 50, y: 50)
        XCTAssertGreaterThan(inside.r, inside.b, "pixelated red region came back blue — patch is flipped")

        // outside the rect, nothing moved
        let untouchedRed = TestImages.pixel(out, x: 150, y: 50)
        let originalRed = TestImages.pixel(base, x: 150, y: 50)
        XCTAssertEqual(untouchedRed.r, originalRed.r, accuracy: 2)
        XCTAssertEqual(untouchedRed.b, originalRed.b, accuracy: 2)

        let untouchedBlue = TestImages.pixel(out, x: 150, y: 150)
        XCTAssertGreaterThan(untouchedBlue.b, untouchedBlue.r, "the blue half must be untouched")
    }

    func testBlurLandsOnTheRegionItWasDrawnOver() throws {
        let base = TestImages.splitRedOverBlue()
        // straddle the colour boundary: a blur here must mix red and blue *at the boundary*,
        // which only happens if the patch is positioned correctly
        let layer = Annotation(tool: .blur, points: [CGPoint(x: 40, y: 60), CGPoint(x: 160, y: 140)],
                               colorHex: "#000000", strokeWidth: 1)
        let out = try XCTUnwrap(AnnotationRenderer.flatten(base: base, layers: [layer]))

        let atBoundary = TestImages.pixel(out, x: 100, y: 100)
        XCTAssertGreaterThan(atBoundary.r, 10, "no red mixed in — the blur isn't over the boundary")
        XCTAssertGreaterThan(atBoundary.b, 10, "no blue mixed in — the blur isn't over the boundary")

        // well outside the rect the original edge is still crisp
        let aboveRect = TestImages.pixel(out, x: 100, y: 10)
        XCTAssertGreaterThan(aboveRect.r, aboveRect.b)
    }

    func testAmountChangesTheResult() throws {
        let base = TestImages.splitRedOverBlue()
        func flatten(_ amount: CGFloat) throws -> (r: Int, g: Int, b: Int) {
            var layer = Annotation(tool: .blur, points: [CGPoint(x: 40, y: 60), CGPoint(x: 160, y: 140)],
                                   colorHex: "#000000", strokeWidth: 1)
            layer.intensity = amount
            let out = try XCTUnwrap(AnnotationRenderer.flatten(base: base, layers: [layer]))
            return TestImages.pixel(out, x: 100, y: 70)
        }
        // near the top of the rect: a gentle blur is still mostly red, a heavy one pulls blue up
        let gentle = try flatten(4)
        let heavy = try flatten(80)
        XCTAssertGreaterThan(heavy.b, gentle.b, "a larger amount must blur further")
    }

    /// A redaction reproduces the base, so it must cover anything drawn under it rather than
    /// blending with it — otherwise "I blurred that out" would not be true.
    func testRedactionCoversAnnotationsUnderneath() throws {
        let base = TestImages.splitRedOverBlue()
        let arrow = Annotation(tool: .rect, points: [CGPoint(x: 30, y: 30), CGPoint(x: 70, y: 70)],
                               colorHex: "#00FF00", strokeWidth: 8)
        var filled = arrow
        filled.filled = true
        let redaction = Annotation(tool: .pixelate, points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 80)],
                                   colorHex: "#000000", strokeWidth: 1)
        let out = try XCTUnwrap(AnnotationRenderer.flatten(base: base, layers: [filled, redaction]))
        let covered = TestImages.pixel(out, x: 50, y: 50)
        XCTAssertLessThan(covered.g, 200, "the green block is still showing through the redaction")
    }
}
