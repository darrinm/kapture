import ScreenCaptureKit
import AppKit
import KaptureCore

public struct FrozenFrame {
    public let display: SCDisplay
    public let screen: NSScreen
    public let image: CGImage          // native-scale pixels
    public let scale: CGFloat          // pixels per point
}

public enum ScreenshotService {
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    public static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    static func screen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }
    }

    /// Freeze every display concurrently (spec §3.1). Returns one frame per display.
    public static func freezeAllDisplays() async throws -> [FrozenFrame] {
        guard let content = await ContentCache.shared.current() else { throw CaptureError.noContent }
        return try await withThrowingTaskGroup(of: FrozenFrame?.self) { group in
            for display in content.displays {
                group.addTask {
                    guard let screen = screen(for: display) else { return nil }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    let scale = screen.backingScaleFactor
                    config.width = Int(CGFloat(display.width) * scale)
                    config.height = Int(CGFloat(display.height) * scale)
                    config.captureResolution = .best
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return FrozenFrame(display: display, screen: screen, image: image, scale: scale)
                }
            }
            var frames: [FrozenFrame] = []
            for try await f in group { if let f { frames.append(f) } }
            return frames
        }
    }

    /// Crop a rect (in display points, origin top-left of that display) out of a frozen frame.
    public static func crop(_ frame: FrozenFrame, rectInPoints: CGRect) -> CGImage? {
        let px = CGRect(x: rectInPoints.origin.x * frame.scale,
                        y: rectInPoints.origin.y * frame.scale,
                        width: rectInPoints.width * frame.scale,
                        height: rectInPoints.height * frame.scale)
        return frame.image.cropping(to: px)
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }
}

public enum CaptureError: Error {
    case noContent, noPermission, cancelled
}
