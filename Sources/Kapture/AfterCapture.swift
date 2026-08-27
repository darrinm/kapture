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
        guard !actions.isEmpty else { return true }

        for action in actions {
            switch action {
            case .copy:
                Clipboard.write(url: url, image: image.map { NSImage(cgImage: $0, size: .zero) })
            case .save:
                save(url)
            case .editor, .pin, .share:
                break   // handled below, after the capture is marked kept
            }
        }

        // anything that opens a window or leaves the Mac counts as acting on the capture, so it
        // stops being a staged card and gets indexed now
        let opensSomething = actions.contains(where: { $0 == .editor || $0 == .pin || $0 == .share })
        if opensSomething {
            Task { await IngestQueue.shared.expedite(record.id) }
            try? OverlayController.shared.library?.setStatus(record.id, .kept)
        }
        if actions.contains(.pin) { PinController.shared.pin(fileURL: url) }
        if actions.contains(.share) { ShareCoordinator.shared.share(record) }
        if actions.contains(.editor), record.canAnnotate {
            EditorController.shared.open(recordID: record.id)
            return false
        }
        return true
    }

    private static func save(_ url: URL) {
        let destination = Library.uniqueURL(in: Settings.shared.exportLocation,
                                            base: url.deletingPathExtension().lastPathComponent,
                                            ext: url.pathExtension)
        do { try FileManager.default.copyItem(at: url, to: destination) }
        catch { Log.store.error("after-capture save failed: \(error)") }
    }
}
