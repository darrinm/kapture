// What opening a capture means, for the corner card and the library alike: a recording opens
// the recording window, a screenshot opens the annotation editor, and anything else (a GIF,
// which is neither trimmable nor PNG-editable) has no window of Kapture's. The still editor's
// save writes PNG bytes, so a GIF must never land there.
import KaptureCore
import KaptureEditor

@MainActor
enum CaptureOpener {
    /// The context-menu title for opening `record`, or nil when Kapture has no window for it.
    static func menuTitle(for record: CaptureRecord) -> String? {
        if record.opensRecordingWindow { return "Trim or Grab Frames…" }
        if record.canAnnotate { return "Edit…" }
        return nil
    }

    /// Opens `record` in its window. Returns false, and opens nothing, when it has none.
    @discardableResult
    static func open(_ record: CaptureRecord) -> Bool {
        if record.opensRecordingWindow {
            RecordingWindowController.shared.open(recordID: record.id)
        } else if record.canAnnotate {
            EditorController.shared.open(recordID: record.id)
        } else {
            return false
        }
        return true
    }
}
