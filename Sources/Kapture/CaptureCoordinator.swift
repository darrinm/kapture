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
                    store(cropped, screenID: Int(sel.frame.display.displayID), windowTitle: nil)
                case .window(let win):
                    let image = try await ScreenshotService.captureWindow(win)
                    store(image, screenID: nil, windowTitle: win.title,
                          sourceApp: win.owningApplication?.bundleIdentifier)
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
                    store(frame.image, screenID: Int(frame.display.displayID), windowTitle: nil)
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
                store(cropped, screenID: Int(frame.display.displayID), windowTitle: nil)
            } catch { Log.capture.error("previous-area capture failed: \(error)") }
        }
    }

    func captureAreaAfter(seconds: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
            NSSound(named: "Pop")?.play()
            self?.captureArea()
        }
    }

    // MARK: previous-area memory
    private func rememberArea(_ sel: AreaSelection) {
        let r = sel.rectInPoints
        UserDefaults.standard.set("\(sel.frame.display.displayID):\(r.origin.x):\(r.origin.y):\(r.width):\(r.height)",
                                  forKey: "lastArea")
    }
    private func recallArea() -> (CGDirectDisplayID, CGRect)? {
        guard let s = UserDefaults.standard.string(forKey: "lastArea") else { return nil }
        let p = s.split(separator: ":").compactMap { Double($0) }
        guard p.count == 5 else { return nil }
        return (CGDirectDisplayID(p[0]), CGRect(x: p[1], y: p[2], width: p[3], height: p[4]))
    }

    private func store(_ image: CGImage, screenID: Int?, windowTitle: String?, sourceApp: String? = nil) {
        guard let library, let data = ScreenshotService.pngData(image) else { return }
        let app = sourceApp ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do {
            let (record, url) = try library.storePNG(
                data, width: image.width, height: image.height,
                sourceApp: app, windowTitle: windowTitle, screenID: screenID)
            if Settings.shared.copyToClipboardAfterCapture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL, NSImage(cgImage: image, size: .zero)])
            }
            OverlayController.shared.show(record: record, fileURL: url, image: image)
            NSSound(named: "Tink")?.play()
        } catch { Log.store.error("store failed: \(error)") }
    }
}
