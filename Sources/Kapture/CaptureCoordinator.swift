// Glue: hotkey/menu → selection chrome → capture → library store → overlay + clipboard.
import AppKit
import ScreenCaptureKit
import KaptureCore
import KaptureCapture

@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    var library: Library?

    func captureArea(startInWindowMode: Bool = false) {
        Task {
            guard ScreenshotService.hasPermission else { Onboarding.shared.show(); return }
            do {
                async let framesTask = ScreenshotService.freezeAllDisplays()
                let content = await ContentCache.shared.current()
                let frames = try await framesTask
                let result = await SelectionController.shared.select(
                    frames: frames, windows: content?.windows ?? [], startInWindowMode: startInWindowMode)
                switch result {
                case .area(let sel):
                    rememberArea(sel)
                    guard let cropped = ScreenshotService.crop(sel.frame, rectInPoints: sel.rectInPoints) else { return }
                    store(cropped, screenID: Int(sel.frame.display.displayID), windowTitle: nil,
                          sourceRect: ScreenshotService.nsRect(displayLocal: sel.rectInPoints, on: sel.frame.screen))
                case .window(let win):
                    let image = try await ScreenshotService.captureWindow(win)
                    store(image, screenID: nil, windowTitle: win.title,
                          sourceApp: win.owningApplication?.bundleIdentifier,
                          sourceRect: ScreenshotService.nsRect(cgGlobal: win.frame))
                case nil:
                    break
                }
            } catch { Log.capture.error("area capture failed: \(error)") }
        }
    }

    func captureWindow() { captureArea(startInWindowMode: true) }

    func captureFullscreen(allDisplays: Bool = false) {
        Task {
            guard ScreenshotService.hasPermission else { Onboarding.shared.show(); return }
            do {
                let frames = try await ScreenshotService.freezeAllDisplays()
                if allDisplays {
                    guard let image = ScreenshotService.compositeAllDisplays(frames) else { return }
                    store(image, screenID: nil, windowTitle: nil)
                } else {
                    let mouse = NSEvent.mouseLocation
                    let frame = frames.first { $0.screen.frame.contains(mouse) } ?? frames.first
                    guard let frame else { return }
                    store(frame.image, screenID: Int(frame.display.displayID), windowTitle: nil,
                          sourceRect: frame.screen.frame)
                }
            } catch { Log.capture.error("fullscreen capture failed: \(error)") }
        }
    }

    func capturePreviousArea() {
        Task {
            guard ScreenshotService.hasPermission else { Onboarding.shared.show(); return }
            guard let (displayID, rect) = recallArea() else { captureArea(); return }
            do {
                let frames = try await ScreenshotService.freezeAllDisplays()
                guard let frame = frames.first(where: { $0.display.displayID == displayID }) ?? frames.first,
                      let cropped = ScreenshotService.crop(frame, rectInPoints: rect) else { return }
                store(cropped, screenID: Int(frame.display.displayID), windowTitle: nil,
                      sourceRect: ScreenshotService.nsRect(displayLocal: rect, on: frame.screen))
            } catch { Log.capture.error("previous-area capture failed: \(error)") }
        }
    }

    func captureAreaAfter(seconds: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
            Sounds.play("Pop")
            self?.captureArea()
        }
    }

    // MARK: previous-area memory (persisted via the Settings facade)
    private func rememberArea(_ sel: AreaSelection) {
        let r = sel.rectInPoints
        Settings.shared.lastArea = "\(sel.frame.display.displayID):\(r.origin.x):\(r.origin.y):\(r.width):\(r.height)"
    }
    private func recallArea() -> (CGDirectDisplayID, CGRect)? {
        guard let s = Settings.shared.lastArea else { return nil }
        let p = s.split(separator: ":").compactMap { Double($0) }
        guard p.count == 5 else { return nil }
        return (CGDirectDisplayID(p[0]), CGRect(x: p[1], y: p[2], width: p[3], height: p[4]))
    }

    private func store(_ image: CGImage, screenID: Int?, windowTitle: String?, sourceApp: String? = nil,
                       sourceRect: NSRect? = nil) {
        guard let library else { return }
        let app = sourceApp ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let width = image.width, height = image.height
        // PNG encode + file/DB writes are hundreds of ms for a 5K frame — keep them off
        // the main actor; hop back for clipboard + overlay once the record exists.
        Task.detached(priority: .userInitiated) {
            guard let data = ScreenshotService.pngData(image) else { return }
            do {
                let (record, url) = try library.storePNG(
                    data, width: width, height: height,
                    sourceApp: app, windowTitle: windowTitle, screenID: screenID)
                await MainActor.run {
                    if Settings.shared.copyToClipboardAfterCapture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([url as NSURL, NSImage(cgImage: image, size: .zero)])
                    }
                    OverlayController.shared.show(record: record, fileURL: url, image: image, from: sourceRect)
                    Sounds.play("Tink")
                }
            } catch { Log.store.error("store failed: \(error)") }
        }
    }
}
