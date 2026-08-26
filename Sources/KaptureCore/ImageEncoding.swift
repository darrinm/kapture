// Shared image encoding. One authoritative CGImage → PNG path for every writer
// (capture store, editor flatten, clipboard pins).
import AppKit

public enum ImageEncoding {
    /// Encode a CGImage as PNG. rep.size is pinned to the pixel dimensions so the PNG
    /// reports 72 DPI and points == pixels downstream.
    public static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }
}
