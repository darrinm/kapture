// Recording state machine: ⌘⇧5 (or the menu) starts a recording via the selection chrome
// (area drag, space for window, esc cancels); the same hotkey stops it. While recording the
// menu-bar item shows a timer, a red border marks the recorded region, and the stop lands the
// movie in the library with an overlay card (poster frame + duration).
import AppKit
import AVFoundation
import ScreenCaptureKit
import KaptureCore
import KaptureCapture
import KaptureRecording

@MainActor
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()
    var library: Library?
    var onStateChanged: ((_ recording: Bool) -> Void)?

    private var session: RecordingSession?
    private var border: BorderWindow?
    private var timer: Timer?
    private var frontApp: String?

    var isRecording: Bool { session != nil }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        Task {
            guard ScreenshotService.hasPermission else { Onboarding.shared.show(); return }
            do {
                async let framesTask = ScreenshotService.freezeAllDisplays()
                let content = await ContentCache.shared.current()
                let frames = try await framesTask
                guard let result = await SelectionController.shared.select(
                    frames: frames, windows: content?.windows ?? []) else { return }

                frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let pid = ProcessInfo.processInfo.processIdentifier
                let excluded = (content?.windows ?? []).filter { $0.owningApplication?.processID == pid }
                let scope: RecordingScope
                var borderRect: NSRect?
                switch result {
                case .area(let sel):
                    scope = .area(sel.frame.display, rectInPoints: sel.rectInPoints, scale: sel.frame.scale)
                    borderRect = nsRect(displayLocal: sel.rectInPoints, on: sel.frame.screen)
                case .window(let win):
                    let scale = ScreenshotService.displayScale(forCGGlobal: win.frame)
                    scope = .window(win, scale: scale)
                }
                let session = try RecordingSession(
                    scope: scope, excludingWindows: excluded,
                    captureMic: Settings.shared.recordMicrophone,
                    captureSystemAudio: Settings.shared.recordSystemAudio)
                try await session.start()
                self.session = session
                if let rect = borderRect { showBorder(around: rect) }
                startTimer()
                Sounds.play("Morse")
                onStateChanged?(true)
            } catch {
                Log.capture.error("recording start failed: \(error)")
                self.session = nil
            }
        }
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        timer?.invalidate(); timer = nil
        border?.orderOut(nil); border = nil
        onStateChanged?(false)
        let app = frontApp
        Task {
            do {
                let result = try await session.stop()
                guard let library else { return }
                let (record, url) = try library.storeMovie(
                    from: result.url, width: result.width, height: result.height,
                    duration: result.duration, sourceApp: app)
                Sounds.play("Glass")
                await self.showRecordingCard(record: record, url: url)
            } catch { Log.capture.error("recording stop failed: \(error)") }
        }
    }

    private func showRecordingCard(record: CaptureRecord, url: URL) async {
        // poster = first frame
        let poster: CGImage? = await Task.detached(priority: .userInitiated) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            return try? generator.copyCGImage(at: .zero, actualTime: nil)
        }.value
        guard let poster else { return }
        OverlayController.shared.show(record: record, fileURL: url, image: poster)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard let started = RecordingCoordinator.shared.session?.startedAt else { return }
                let s = Int(Date().timeIntervalSince(started))
                RecordingCoordinator.shared.onTick?(String(format: "%d:%02d", s / 60, s % 60))
            }
        }
    }
    var onTick: ((String) -> Void)?

    private func nsRect(displayLocal r: CGRect, on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.minX + r.origin.x, y: screen.frame.maxY - r.maxY,
               width: r.width, height: r.height)
    }

    private func showBorder(around rect: NSRect) {
        let b = BorderWindow(around: rect)
        b.orderFrontRegardless()
        border = b
    }
}

/// Click-through accent border marking the recorded region (excluded from capture by pid filter).
final class BorderWindow: NSWindow {
    init(around rect: NSRect) {
        super.init(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor(srgbRed: 0.78, green: 0.26, blue: 0.23, alpha: 0.9).cgColor
        view.layer?.cornerRadius = 4
        contentView = view
    }
}
