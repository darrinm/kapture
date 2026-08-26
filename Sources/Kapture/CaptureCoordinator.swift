// Glue: hotkey/menu → selection chrome → capture → library store → overlay + clipboard.
import AppKit
import KaptureCore
import KaptureCapture

@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    var library: Library?

    func captureArea() {
        Task {
            guard ScreenshotService.hasPermission else { Onboarding.shared.show(); return }
            do {
                let frames = try await ScreenshotService.freezeAllDisplays()
                guard let selection = await SelectionController.shared.selectArea(frames: frames),
                      let cropped = ScreenshotService.crop(selection.frame, rectInPoints: selection.rectInPoints)
                else { return }
                store(cropped, screenID: Int(selection.frame.display.displayID))
            } catch { Log.capture.error("area capture failed: \(error)") }
        }
    }

    func captureFullscreen() {
        Task {
            guard ScreenshotService.hasPermission else { Onboarding.shared.show(); return }
            do {
                let frames = try await ScreenshotService.freezeAllDisplays()
                // display under the cursor, else main
                let mouse = NSEvent.mouseLocation
                let frame = frames.first { $0.screen.frame.contains(mouse) } ?? frames.first
                guard let frame else { return }
                store(frame.image, screenID: Int(frame.display.displayID))
            } catch { Log.capture.error("fullscreen capture failed: \(error)") }
        }
    }

    private func store(_ image: CGImage, screenID: Int?) {
        guard let library, let data = ScreenshotService.pngData(image) else { return }
        let frontApp = NSWorkspace.shared.frontmostApplication
        do {
            let (record, url) = try library.storePNG(
                data, width: image.width, height: image.height,
                sourceApp: frontApp?.bundleIdentifier, windowTitle: nil, screenID: screenID)
            if Settings.shared.copyToClipboardAfterCapture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL, NSImage(cgImage: image, size: .zero)])
            }
            OverlayController.shared.show(record: record, fileURL: url, image: image)
            NSSound(named: "Tink")?.play()
        } catch { Log.store.error("store failed: \(error)") }
    }
}
