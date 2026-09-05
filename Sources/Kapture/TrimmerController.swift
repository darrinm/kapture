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
    /// Window and its close observer travel together — two parallel dictionaries could drift
    /// and leave an observer registered for a window that is already gone.
    private struct Open {
        let window: NSWindow
        let closeObserver: NSObjectProtocol
    }
    private var open: [String: Open] = [:]

    func open(recordID: String) {
        guard let library,
              let record = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: recordID) }),
              record.canTrim else { return }
        if let existing = open[recordID] { existing.window.makeKeyAndOrderFront(nil); return }
        let url = library.url(for: record)

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
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let entry = self.open.removeValue(forKey: recordID) {
                    NotificationCenter.default.removeObserver(entry.closeObserver)
                }
                ActivationPolicy.release()
            }
        }
        open[recordID] = Open(window: window, closeObserver: observer)
        ActivationPolicy.acquire()
        window.makeKeyAndOrderFront(nil)

        // start the native trim UI once the item is ready
        Task {
            // `for _ in 0..<40 where !canBeginTrimming` filters iterations rather than stopping,
            // so it slept the full 4s even once the item was ready
            var tries = 0
            while !playerView.canBeginTrimming && tries < 40 {
                try? await Task.sleep(for: .milliseconds(100))
                tries += 1
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
        let out = Library.tempURL(prefix: "kapture-trim", ext: "mp4")
        do {
            export.timeRange = range
            if #available(macOS 15, *) {
                try await export.export(to: out, as: .mp4)
            } else {
                try await legacyExport(export, to: out)
            }
            try library.applyTrim(recordID, trimmedURL: out, duration: range.duration.seconds)
            Sounds.play("Glass")
            window.close()
            OverlayController.shared.showCard(recordID: recordID)
        } catch {
            // The window stays open with the range intact; the user just needs to know why.
            Log.capture.error("trimmer: export failed: \(error)")
            Toast.show(error, while: "Trim")
        }
    }

    /// The macOS 14 export path. `export(to:as:)` is macOS 15 only, and Kapture ships back to 14.
    ///
    /// Deliberately marked deprecated: a deprecated declaration is allowed to call other
    /// declarations deprecated at the same version, which is what keeps the pre-15 calls inside
    /// it from failing a `-warnings-as-errors` build against a 15+ SDK.
    @available(macOS, deprecated: 15.0, message: "AVAssetExportSession.export(to:as:) covers 15+")
    private func legacyExport(_ export: AVAssetExportSession, to out: URL) async throws {
        export.outputURL = out
        export.outputFileType = .mp4
        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw export.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}
