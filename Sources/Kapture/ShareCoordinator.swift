// One place that turns "share this" into a link on the clipboard, wherever the gesture came
// from — the overlay card, the library grid, or the menu bar. Uploading is the only way a
// capture's pixels leave this Mac by user action, so it is always explicit and never automatic.
import AppKit
import KaptureCore

@MainActor
final class ShareCoordinator {
    static let shared = ShareCoordinator()
    var library: Library?

    /// ids with an upload in flight, so a double-press can't upload the same capture twice
    private var inFlight: Set<String> = []

    /// Shares a capture and puts the link on the clipboard. A capture that already has a link
    /// and hasn't been edited since is not re-uploaded — the existing link is simply copied,
    /// which is what pressing share a second time almost always means.
    func share(_ record: CaptureRecord, then onFinish: ((URL?) -> Void)? = nil) {
        guard let library,
              let record = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: record.id) }) else { return }
        guard ShareService.isConfigured else {
            Toast.show("Add a share token in Settings › Sharing")
            SettingsWindowController.shared.show(tab: .sharing)
            onFinish?(nil)
            return
        }
        if let existing = record.shareURL, !record.shareStale, let url = URL(string: existing) {
            copy(url)
            onFinish?(url)
            return
        }
        guard !inFlight.contains(record.id) else { return }
        inFlight.insert(record.id)

        let id = record.id
        // Keep the visible name stable until the snapshot upload completes.
        Library.markInUse(id)
        Toast.show("Sharing…")

        Task { [weak self] in
            defer {
                Library.clearInUse(id)
                self?.inFlight.remove(id)
            }
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try library.shareSnapshot(id)
                }.value
                defer { try? FileManager.default.removeItem(at: snapshot.file) }
                let link = try await ShareService.upload(fileURL: snapshot.file,
                    filename: (snapshot.record.relPath as NSString).lastPathComponent)
                // an open library picks the new link up from the write itself — see
                // `Library.observeCaptures`; it used to have to be told from here
                let current: Bool
                do {
                    current = try library.setShareLink(id, url: link.url.absoluteString,
                                                       revision: snapshot.record.contentRevision)
                } catch {
                    // The row refused the link (its file operation is still settling), so
                    // nothing local remembers it and nothing could revoke it later. Take it
                    // back down now rather than leave it charged against the quota, unlisted.
                    try? await ShareService.delete(id: link.url.lastPathComponent)
                    throw error
                }
                guard current else {
                    Toast.show("Capture changed while uploading — share again to upload the latest version")
                    onFinish?(nil)
                    return
                }
                self?.copy(link.url)
                onFinish?(link.url)
            } catch let failure as ShareFailure {
                Toast.show(failure.description)
                if failure.isAuthFailure { SettingsWindowController.shared.show(tab: .sharing) }
                Log.shell.error("share failed: \(failure.description, privacy: .public)")
                onFinish?(nil)
            } catch {
                Toast.show(error, while: "Share")
                onFinish?(nil)
            }
        }
    }

    /// Revokes the link and forgets it locally. The capture itself is untouched.
    func unshare(_ record: CaptureRecord) {
        guard let library, let existing = record.shareURL,
              let shareID = URL(string: existing)?.lastPathComponent, !shareID.isEmpty
        else { return }
        let id = record.id
        Task {
            // Forget it locally first. A capture whose file operation is still settling refuses
            // the write, and that has to stop us *before* the server forgets a link this row
            // would otherwise go on offering as current — a 404 on the clipboard.
            do { _ = try library.setShareLink(id, url: nil) }
            catch { Toast.show(error, while: "Delete link"); return }
            do {
                try await ShareService.delete(id: shareID)
                Toast.show("Link deleted")
            } catch {
                // Still live on the server, so the row has to keep knowing about it.
                _ = try? library.setShareLink(id, url: existing, revision: record.contentRevision)
                Toast.show((error as? ShareFailure)?.description ?? "Could not delete the link")
            }
        }
    }

    private func copy(_ url: URL) {
        if Settings.shared.copyShareLinkAutomatically {
            Clipboard.write(string: url.absoluteString)
            Toast.show("Link copied — \(url.absoluteString)")
        } else {
            Toast.show(url.absoluteString)
        }
        Sounds.play("Glass")
    }
}
