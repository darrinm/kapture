// Thumbnails for the shared library (docs/SHARED-LIBRARY.md §8.1, F47).
//
// Every Mac holds a thumbnail for every capture, so the grid is complete on a Mac that has
// fetched none of the full-size bytes. Long edge 512, JPEG at 0.7: about 60 KB each, so ten
// thousand captures is roughly 600 MB on every Mac.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import KaptureCore
import UniformTypeIdentifiers

public enum Thumbnailer {
    public static let maxEdge = 512
    public static let quality = 0.7

    /// A JPEG thumbnail for a capture's file, or nil when the file cannot be read as an image
    /// or a movie. Nil is not an error: a capture with no thumbnail syncs without one.
    public static func jpeg(for file: URL, kind: CaptureKind) async -> Data? {
        let image: CGImage?
        switch kind {
        case .recording: image = await posterFrame(file)
        case .screenshot, .gif, .text: image = still(file)
        }
        return image.flatMap(encode)
    }

    /// Decoded straight to the target size. `CGImageSourceCreateThumbnailAtIndex` scales during
    /// decode, so a 6K screenshot is never held at full resolution to make a 512-pixel image.
    /// For a GIF it is the first frame.
    static func still(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// One second in, or the first frame of anything shorter: the opening frame of a screen
    /// recording is often the moment before anything happened.
    static func posterFrame(_ file: URL) async -> CGImage? {
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let at = CMTime(seconds: duration >= 1 ? 1 : 0, preferredTimescale: 600)
        return try? await generator.image(at: at).image
    }

    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
