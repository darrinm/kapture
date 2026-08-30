// Glue: hotkey/menu → selection chrome → capture → library store → overlay + clipboard.
import AppKit
import ScreenCaptureKit
import KaptureCore
import KaptureCapture
import KaptureIntelligence

@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    var library: Library?

    func captureArea(startInWindowMode: Bool = false) {
        // Before anything of ours is on screen. The selection overlay is a key window, so by the
        // time the capture is stored *we* are the frontmost application — every area capture was
        // being filed under Kapture itself, which is why the library's app filter offered one
        // entry. `RecordingCoordinator` takes the same reading for the same reason.
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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
                          sourceApp: frontApp,
                          sourceRect: ScreenshotService.nsRect(displayLocal: sel.rectInPoints, on: sel.frame.screen))
                case .window(let win):
                    let image = try await ScreenshotService.captureWindow(win)
                    // the window's own owner where ScreenCaptureKit knows it, and the reading
                    // taken before our overlay went up where it doesn't — never "whoever is in
                    // front now", which on this path is always us
                    store(image, screenID: nil, windowTitle: win.title,
                          sourceApp: win.owningApplication?.bundleIdentifier ?? frontApp,
                          sourceRect: ScreenshotService.nsRect(cgGlobal: win.frame))
                case nil:
                    break
                }
            } catch { Log.capture.error("area capture failed: \(error)") }
        }
    }

    func captureWindow() { captureArea(startInWindowMode: true) }

    /// Capture Text (⌘⇧2): select a region, recognize its text on-device, put it on the
    /// clipboard. Nothing is stored — this is a clipboard action, not a capture.
    func captureText() {
        Task {
            guard ScreenshotService.hasPermission else { Onboarding.shared.show(); return }
            do {
                let frames = try await ScreenshotService.freezeAllDisplays()
                guard case .area(let sel)? = await SelectionController.shared.select(frames: frames, windows: []),
                      let cropped = ScreenshotService.crop(sel.frame, rectInPoints: sel.rectInPoints)
                else { return }
                let text = await Task.detached(priority: .userInitiated) {
                    OCRService.clipboardText(for: cropped)
                }.value
                guard !text.isEmpty else {
                    Toast.show("No text found")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                Sounds.play("Tink")
                Toast.show(text.count > 60 ? String(text.prefix(60)) + "…" : text)
            } catch { Log.capture.error("capture text failed: \(error)") }
        }
    }

    func captureFullscreen(allDisplays: Bool = false) {
        // read now rather than after the freeze: nothing of ours takes focus on this path, but
        // "who was in front when the shutter was pressed" is the question, not "who is in front
        // by the time the file is written"
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Task {
            guard ScreenshotService.hasPermission else { Onboarding.shared.show(); return }
            do {
                let frames = try await ScreenshotService.freezeAllDisplays()
                if allDisplays {
                    guard let image = ScreenshotService.compositeAllDisplays(frames) else { return }
                    store(image, screenID: nil, windowTitle: nil, sourceApp: frontApp)
                } else {
                    let mouse = NSEvent.mouseLocation
                    let frame = frames.first { $0.screen.frame.contains(mouse) } ?? frames.first
                    guard let frame else { return }
                    store(frame.image, screenID: Int(frame.display.displayID), windowTitle: nil,
                          sourceApp: frontApp, sourceRect: frame.screen.frame)
                }
            } catch { Log.capture.error("fullscreen capture failed: \(error)") }
        }
    }

    func capturePreviousArea() {
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Task {
            guard ScreenshotService.hasPermission else { Onboarding.shared.show(); return }
            guard let (displayID, rect) = recallArea() else { captureArea(); return }
            do {
                let frames = try await ScreenshotService.freezeAllDisplays()
                guard let frame = frames.first(where: { $0.display.displayID == displayID }) ?? frames.first,
                      let cropped = ScreenshotService.crop(frame, rectInPoints: rect) else { return }
                store(cropped, screenID: Int(frame.display.displayID), windowTitle: nil,
                      sourceApp: frontApp,
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

    /// `sourceApp` has no default and no fallback on purpose: by the time this runs the capture
    /// is over, and reading the frontmost application here is what filed every area capture under
    /// Kapture. Callers take that reading before anything of ours is on screen.
    private func store(_ image: CGImage, screenID: Int?, windowTitle: String?, sourceApp: String?,
                       sourceRect: NSRect? = nil) {
        guard let library else { return }
        let width = image.width, height = image.height
        // PNG encode + file/DB writes are hundreds of ms for a 5K frame — keep them off
        // the main actor; hop back for clipboard + overlay once the record exists.
        Task.detached(priority: .userInitiated) {
            guard let data = ScreenshotService.pngData(image) else { return }
            do {
                let (record, url) = try library.storePNG(
                    data, width: width, height: height,
                    sourceApp: sourceApp, windowTitle: windowTitle, screenID: screenID)
                await MainActor.run {
                    let showCard = AfterCapture.run(record: record, url: url, image: image)
                    if showCard {
                        OverlayController.shared.show(record: record, fileURL: url, image: image,
                                                      from: sourceRect)
                    }
                    Sounds.play("Tink")
                    // OCR after the debounce — a burst-triage discard costs no work
                    Task { await IngestQueue.shared.enqueue(record.id) }
                }
            } catch { Log.store.error("store failed: \(error)") }
        }
    }
}
