// Shared image encoding. One authoritative CGImage → PNG path for every writer
// (capture store, editor flatten, clipboard pins), and one downscaled-JPEG path for every
// reader that ships pixels somewhere small (naming over the API).
import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncoding {
    /// Encode a CGImage as PNG. rep.size is pinned to the pixel dimensions so the PNG
    /// reports 72 DPI and points == pixels downstream.
    public static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    /// Encode a CGImage as JPEG, downscaled so its longest edge is at most `maxEdge`. The
    /// defaults are the naming tier's: layout survives, pixel detail doesn't need to, and a
    /// full-screen capture lands around 100 KB instead of tens of megabytes.
    public static func jpegData(_ image: CGImage, maxEdge: CGFloat = 1024,
                                quality: CGFloat = 0.7) -> Data? {
        let scale = min(1, maxEdge / CGFloat(max(image.width, image.height)))
        let w = max(Int(CGFloat(image.width) * scale), 1)
        let h = max(Int(CGFloat(image.height) * scale), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, scaled,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
