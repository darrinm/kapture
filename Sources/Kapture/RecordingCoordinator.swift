// Recording state machine: ⌘⇧5 (or the menu) starts a recording via the selection chrome
// (area drag, space for window, esc cancels); the same hotkey stops it. While recording the
// menu-bar item shows a timer, a red border marks the recorded region, and the stop lands the
// movie in the library with an overlay card (poster frame + duration).
import AppKit
import AVFoundation
import ScreenCaptureKit
import KaptureCore
import KaptureCapture
import KaptureDesign
import KaptureRecording

/// Everything the menu-bar item needs to draw itself, in one signal.
enum RecordingStatus {
    case idle
    case active(elapsed: String, paused: Bool)
}

@MainActor
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()
    var library: Library?
    var onStatusChanged: ((RecordingStatus) -> Void)?

    private var session: RecordingSession?
    private var border: BorderWindow?
    private var timer: Timer?
    private var frontApp: String?
    // Two clocks, deliberately: the movie's length comes from the session (frames appended),
    // while the menu-bar timer runs on wall time minus pause spans. SCK only delivers frames
    // when the screen CHANGES, so a session-derived timer would sit frozen on a still screen
    // even though the recording is very much running.
    private var pauseStart: Date?
    private var pausedTotal: TimeInterval = 0
    /// true between "selection made" and "session assigned" — a second ⌘⇧5 in that window
    /// would otherwise start a second stream and orphan the first one, still capturing.
    private var starting = false

    var isRecording: Bool { session != nil }
    var isPaused: Bool { session?.isPaused ?? false }

    /// Wall-clock recorded time, pause spans removed.
    private var elapsedText: String {
        guard let started = session?.startedAt else { return Tokens.duration(0) }
        let now = Date()
        var elapsed = now.timeIntervalSince(started) - pausedTotal
        if let began = pauseStart { elapsed -= now.timeIntervalSince(began) }
        return Tokens.duration(elapsed)
    }

    private func publishStatus() {
        guard let session else { onStatusChanged?(.idle); return }
        onStatusChanged?(.active(elapsed: elapsedText, paused: session.isPaused))
    }

    func togglePause() {
        guard let session else { return }
        let next = !session.isPaused
        session.setPaused(next)
        // the timer shows RECORDED time, so paused spans are subtracted
        if next {
            pauseStart = Date()
        } else if let began = pauseStart {
            pausedTotal += Date().timeIntervalSince(began)
            pauseStart = nil
        }
        RecordingHUD.shared.setSuspended(next)
        publishStatus()
        Sounds.play(next ? "Tink" : "Morse")
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording, !starting else { return }
        Log.capture.info("record: begin")
        Task {
            guard ScreenshotService.hasPermission else { Onboarding.shared.show(); return }
            do {
                async let framesTask = ScreenshotService.freezeAllDisplays()
                let content = await ContentCache.shared.current()
                let frames = try await framesTask
                let selection = await SelectionController.shared.select(
                    frames: frames, windows: content?.windows ?? [])
                guard let result = selection else { Log.capture.info("record: selection cancelled"); return }
                Log.capture.info("record: selection made")
                starting = true
                defer { starting = false }

                frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let pid = ProcessInfo.processInfo.processIdentifier
                let excluded = (content?.windows ?? []).filter { $0.owningApplication?.processID == pid }
                let scope: RecordingScope
                var borderRect: NSRect?
                switch result {
                case .area(let sel):
                    scope = .area(sel.frame.display, rectInPoints: sel.rectInPoints, scale: sel.frame.scale)
                    borderRect = ScreenshotService.nsRect(displayLocal: sel.rectInPoints, on: sel.frame.screen)
                case .window(let win):
                    let scale = ScreenshotService.displayScale(forCGGlobal: win.frame)
                    scope = .window(win, scale: scale)
                }
                let session = try RecordingSession(
                    scope: scope, excludingWindows: excluded,
                    captureMic: Settings.shared.recordMicrophone,
                    captureSystemAudio: Settings.shared.recordSystemAudio)
                try await session.start()
                Log.capture.info("record: capturing \(session.pixelWidth)x\(session.pixelHeight)")
                self.session = session
                pauseStart = nil
                pausedTotal = 0
                if let rect = borderRect { showBorder(around: rect) }
                RecordingHUD.shared.start(showClicks: Settings.shared.showClicksWhileRecording,
                                          showKeys: Settings.shared.showKeysWhileRecording)
                startTimer()
                Sounds.play("Morse")
                publishStatus()
            } catch {
                Log.capture.error("recording start failed: \(error)")
                self.session = nil
            }
        }
    }

    func stop() {
        Log.capture.info("record: stop requested (active: \(self.session != nil))")
        guard let session else { return }
        self.session = nil
        timer?.invalidate(); timer = nil
        border?.orderOut(nil); border = nil
        RecordingHUD.shared.stop()
        publishStatus()
        let app = frontApp
        Task {
            do {
                let result = try await session.stop()
                guard let library else { return }
                let (record, _) = try library.storeMovie(result, sourceApp: app)
                Sounds.play("Glass")
                OverlayController.shared.showCard(recordID: record.id)
            } catch { Log.capture.error("recording stop failed: \(error)") }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {   // scheduled on the main run loop
                RecordingCoordinator.shared.publishStatus()
            }
        }
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
        view.layer?.borderColor = Tokens.accent.withAlphaComponent(0.9).cgColor
        view.layer?.cornerRadius = 4
        contentView = view
    }
}
