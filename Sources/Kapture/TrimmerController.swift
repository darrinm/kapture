// Recording trimmer: AVPlayerView's native QuickTime-style trim UI over the library file.
// Trim exports passthrough (no re-encode — the recorder's 1.5s max keyframe interval bounds
// the snap error) and lands via Library.applyTrim: original preserved in .originals/, the
// trimmed movie replaces the file, and the capture returns as an overlay card.
import AppKit
import AVKit
import KaptureCore
import KaptureDesign

@MainActor
final class TrimmerController {
    static let shared = TrimmerController()
    var library: Library?
    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]

    func open(recordID: String) {
        guard let library,
              let record = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: recordID) }),
              record.kind == .recording else { return }
        if let existing = windows[recordID] { existing.makeKeyAndOrderFront(nil); return }
        let url = library.root.appendingPathComponent(record.relPath)

        let playerView = AVPlayerView()
        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .floating

        let aspect = record.height > 0 ? CGFloat(record.width) / CGFloat(record.height) : 16.0 / 9
        let maxSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let w = min(CGFloat(record.width) / 2, maxSize.width * 0.7)
        let h = w / aspect

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(560, w), height: max(320, h)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = (record.relPath as NSString).lastPathComponent
        window.contentView = playerView
        window.center()
        window.isReleasedWhenClosed = false
        windows[recordID] = window
        closeObservers[recordID] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.windows[recordID] = nil
                if let token = self.closeObservers.removeValue(forKey: recordID) {
                    NotificationCenter.default.removeObserver(token)
                }
                ActivationPolicy.release()
            }
        }
        ActivationPolicy.acquire()
        window.makeKeyAndOrderFront(nil)

        // start the native trim UI once the item is ready
        Task {
            for _ in 0..<40 where !playerView.canBeginTrimming {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard playerView.canBeginTrimming else {
                Log.capture.error("trimmer: item never became trimmable")
                return
            }
            // Cancel must not export: AVKit's restoration of the playback end times is not
            // contractual, so a discarded result can commit a trim the user rejected.
            guard await playerView.beginTrimming() == .okButton else { window.close(); return }
            guard let item = playerView.player?.currentItem else { return }
            let start = item.reversePlaybackEndTime.isValid && item.reversePlaybackEndTime.seconds > 0
                ? item.reversePlaybackEndTime : .zero
            let duration = (try? await item.asset.load(.duration)) ?? .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : duration
            let range = CMTimeRange(start: start, end: end)
            // full-range "trim" = nothing to do
            if start == .zero, end == duration { window.close(); return }
            await self.export(recordID: recordID, sourceURL: url, range: range, window: window)
        }
    }

    private func export(recordID: String, sourceURL: URL, range: CMTimeRange, window: NSWindow) async {
        guard let library else { return }
        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            Log.capture.error("trimmer: export session creation failed")
            return
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("kapture-trim-\(ULID.generate()).mp4")
        do {
            export.timeRange = range
            try await export.export(to: out, as: .mp4)
            try library.applyTrim(recordID, trimmedURL: out, duration: range.duration.seconds)
            Sounds.play("Glass")
            window.close()
            OverlayController.shared.showCard(recordID: recordID)
        } catch {
            Log.capture.error("trimmer: export failed: \(error)")
        }
    }
}
