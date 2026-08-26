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
    /// Kapture's own windows (overlays, onboarding) are excluded so they never appear in captures.
    public static func freezeAllDisplays() async throws -> [FrozenFrame] {
        guard let content = await ContentCache.shared.refresh() else { throw CaptureError.noContent }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        return try await withThrowingTaskGroup(of: FrozenFrame?.self) { group in
            for display in content.displays {
                group.addTask {
                    guard let screen = screen(for: display) else { return nil }
                    let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
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

    /// CG-global rect (top-left origin) → NS-global rect (bottom-left origin).
    public static func nsRect(cgGlobal r: CGRect) -> NSRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: r.origin.x, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    /// Scale of the display the CG-global (top-left origin) rect mostly sits on —
    /// mixed-DPI correctness for window captures, where NSScreen.main may be a different display.
    public static func displayScale(forCGGlobal r: CGRect) -> CGFloat {
        let ns = nsRect(cgGlobal: r)
        let best = NSScreen.screens.max { a, b in
            overlapArea(a.frame, ns) < overlapArea(b.frame, ns)
        }
        return best?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// Live single-window capture (transparent background, includes rounded corners).
    public static func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = displayScale(forCGGlobal: window.frame)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.captureResolution = .best
        config.showsCursor = false
        config.backgroundColor = .clear
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Composite every display's frozen frame edge-to-edge into one image (all-displays fullscreen).
    public static func compositeAllDisplays(_ frames: [FrozenFrame]) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        if frames.count == 1 { return frames[0].image }
        // CG global coords (top-left origin), points
        let union = frames.map { $0.display.frame }.reduce(frames[0].display.frame) { $0.union($1) }
        let scale = frames.map(\.scale).max() ?? 2
        let w = Int(union.width * scale), h = Int(union.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for f in frames {
            let d = f.display.frame
            // context is bottom-left origin; display frames are top-left global
            let rect = CGRect(x: (d.origin.x - union.origin.x) * scale,
                              y: (union.maxY - d.maxY) * scale,
                              width: d.width * scale, height: d.height * scale)
            ctx.draw(f.image, in: rect)
        }
        return ctx.makeImage()
    }

    public static func pngData(_ image: CGImage) -> Data? {
        ImageEncoding.pngData(image)
    }
}

public enum CaptureError: Error {
    case noContent
}
