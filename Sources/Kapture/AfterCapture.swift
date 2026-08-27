// Runs the After Capture list. One place decides what happens to a fresh capture, so the
// corner card, the editor and the uploader can't each grow their own version of "and then…".
import AppKit
import KaptureCore
import KaptureEditor
import KaptureIntelligence

@MainActor
enum AfterCapture {
    /// Returns true if the corner card should still be shown. Opening the editor replaces the
    /// card rather than stacking a window on top of it.
    @discardableResult
    static func run(record: CaptureRecord, url: URL, image: CGImage?) -> Bool {
        let actions = Settings.shared.afterCaptureActions

        if actions.contains(.copy) {
            Clipboard.write(url: url, image: image.map { NSImage(cgImage: $0, size: .zero) })
        }
        if actions.contains(.save) { save(url) }

        // anything that opens a window or leaves the Mac counts as acting on the capture, so it
        // stops being a staged card and gets indexed now
        if actions.contains(where: \.marksKept) {
            Task { await IngestQueue.shared.expedite(record.id) }
            try? OverlayController.shared.library?.setStatus(record.id, .kept)
        }
        if actions.contains(.pin) { PinController.shared.pin(fileURL: url) }
        if actions.contains(.share) { ShareCoordinator.shared.share(record) }
        if actions.contains(.editor), record.canAnnotate {
            EditorController.shared.open(recordID: record.id)
            return false      // the editor replaces the card rather than stacking on it
        }
        return true
    }

    /// Off the main actor: this runs inside the capture's MainActor hop, and a stop-recording
    /// takes the same path — copying a large movie there would stall the UI for its duration.
    private static func save(_ url: URL) {
        Task.detached(priority: .utility) {
            do { try Library.copyToExportLocation(url) }
            catch { Log.store.error("after-capture save failed: \(error)") }
        }
    }
}
