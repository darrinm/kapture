// Blur and pixelate reproduce the pixels underneath, so the things that can go wrong are
// geometric: the patch lands in the wrong place, or upside down, or leaks outside its rect.
// Those are invisible in a build log and obvious in a pixel.
import XCTest
import AppKit
@testable import KaptureEditor

final class EffectsTests: XCTestCase {
    /// A 200x200 image: top half red, bottom half blue. Vertically asymmetric on purpose — a
    /// mirrored patch would put blue where red belongs.
    private func makeBase() -> CGImage {
        let size = 200
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext is bottom-left: draw blue low, red high, so the *image* is red on top
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fill(CGRect(x: 0, y: size / 2, width: size, height: size / 2))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * image.height)
        // drawing a CGImage into a bitmap context writes rows top-down, so memory row 0 is the
        // image's top row — the same top-left space the annotation geometry uses
        let p = y * ctx.bytesPerRow + x * 4
        return (Int(data[p]), Int(data[p + 1]), Int(data[p + 2]))
    }

    func testPixelateStaysInsideItsRectAndKeepsTheRegionsColour() throws {
        let base = makeBase()
        // a block in the red half only
        let layer = Annotation(tool: .pixelate, points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 80)],
                               colorHex: "#000000", strokeWidth: 1)
        let out = try XCTUnwrap(AnnotationRenderer.flatten(base: base, layers: [layer]))

        // inside: still red-dominant. If the patch were mirrored vertically it would be blue here.
        let inside = pixel(out, x: 50, y: 50)
        XCTAssertGreaterThan(inside.r, inside.b, "pixelated red region came back blue — patch is flipped")

        // outside the rect, nothing moved
        let untouchedRed = pixel(out, x: 150, y: 50)
        let originalRed = pixel(base, x: 150, y: 50)
        XCTAssertEqual(untouchedRed.r, originalRed.r, accuracy: 2)
        XCTAssertEqual(untouchedRed.b, originalRed.b, accuracy: 2)

        let untouchedBlue = pixel(out, x: 150, y: 150)
        XCTAssertGreaterThan(untouchedBlue.b, untouchedBlue.r, "the blue half must be untouched")
    }

    func testBlurLandsOnTheRegionItWasDrawnOver() throws {
        let base = makeBase()
        // straddle the colour boundary: a blur here must mix red and blue *at the boundary*,
        // which only happens if the patch is positioned correctly
        let layer = Annotation(tool: .blur, points: [CGPoint(x: 40, y: 60), CGPoint(x: 160, y: 140)],
                               colorHex: "#000000", strokeWidth: 1)
        let out = try XCTUnwrap(AnnotationRenderer.flatten(base: base, layers: [layer]))

        let atBoundary = pixel(out, x: 100, y: 100)
        XCTAssertGreaterThan(atBoundary.r, 10, "no red mixed in — the blur isn't over the boundary")
        XCTAssertGreaterThan(atBoundary.b, 10, "no blue mixed in — the blur isn't over the boundary")

        // well outside the rect the original edge is still crisp
        let aboveRect = pixel(out, x: 100, y: 10)
        XCTAssertGreaterThan(aboveRect.r, aboveRect.b)
    }

    func testAmountChangesTheResult() throws {
        let base = makeBase()
        func flatten(_ amount: CGFloat) throws -> (r: Int, g: Int, b: Int) {
            var layer = Annotation(tool: .blur, points: [CGPoint(x: 40, y: 60), CGPoint(x: 160, y: 140)],
                                   colorHex: "#000000", strokeWidth: 1)
            layer.intensity = amount
            let out = try XCTUnwrap(AnnotationRenderer.flatten(base: base, layers: [layer]))
            return pixel(out, x: 100, y: 70)
        }
        // near the top of the rect: a gentle blur is still mostly red, a heavy one pulls blue up
        let gentle = try flatten(4)
        let heavy = try flatten(80)
        XCTAssertGreaterThan(heavy.b, gentle.b, "a larger amount must blur further")
    }

    /// A redaction reproduces the base, so it must cover anything drawn under it rather than
    /// blending with it — otherwise "I blurred that out" would not be true.
    func testRedactionCoversAnnotationsUnderneath() throws {
        let base = makeBase()
        let arrow = Annotation(tool: .rect, points: [CGPoint(x: 30, y: 30), CGPoint(x: 70, y: 70)],
                               colorHex: "#00FF00", strokeWidth: 8)
        var filled = arrow
        filled.filled = true
        let redaction = Annotation(tool: .pixelate, points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 80)],
                                   colorHex: "#000000", strokeWidth: 1)
        let out = try XCTUnwrap(AnnotationRenderer.flatten(base: base, layers: [filled, redaction]))
        let covered = pixel(out, x: 50, y: 50)
        XCTAssertLessThan(covered.g, 200, "the green block is still showing through the redaction")
    }
}
