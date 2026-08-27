// One place that builds the fixtures the editor tests need. Five files had grown their own
// private copy of the same CGContext boilerplate, and two of those had a second copy inline.
import AppKit
import XCTest
@testable import KaptureEditor

enum TestImages {
    /// A blank image of the given size, filled so sampled pixels are deterministic.
    static func blank(_ width: Int = 200, _ height: Int = 200, fill: NSColor = .gray) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Top half red, bottom half blue. Vertically asymmetric on purpose: a patch drawn mirrored
    /// puts blue where red belongs, which is otherwise invisible in a passing test.
    static func splitRedOverBlue(_ size: Int = 200) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext is bottom-left: blue low, red high, so the *image* is red on top
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fill(CGRect(x: 0, y: size / 2, width: size, height: size / 2))
        return ctx.makeImage()!
    }

    /// One pixel in image space (top-left origin), as the annotation geometry uses.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let ctx = CGContext(data: nil, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * image.height)
        // drawing a CGImage into a bitmap context writes rows top-down, so memory row 0 is the
        // image's top row
        let p = y * ctx.bytesPerRow + x * 4
        return (Int(data[p]), Int(data[p + 1]), Int(data[p + 2]))
    }

    static func centre(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        pixel(image, x: image.width / 2, y: image.height / 2)
    }
}

@MainActor
enum TestCanvas {
    /// A canvas in a frame of the given size. The frame matters: the zoom tests read fitted
    /// geometry straight out of it.
    static func make(image: CGImage = TestImages.blank(200, 200),
                     layers: [Annotation] = [],
                     tool: Tool = .arrow,
                     frame: NSSize = NSSize(width: 400, height: 400),
                     selectingMostRecent: Bool = false) -> CanvasView {
        let canvas = CanvasView(image: image, layers: layers)
        canvas.frame = NSRect(origin: .zero, size: frame)
        canvas.tool = tool
        if selectingMostRecent { canvas.selectMostRecent() }
        return canvas
    }
}
