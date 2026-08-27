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

    func isSharing(_ id: String) -> Bool { inFlight.contains(id) }

    /// Shares a capture and puts the link on the clipboard. A capture that already has a link
    /// and hasn't been edited since is not re-uploaded — the existing link is simply copied,
    /// which is what pressing share a second time almost always means.
    func share(_ record: CaptureRecord, then onFinish: ((URL?) -> Void)? = nil) {
        guard let library else { return }
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

        let fileURL = library.url(for: record)
        let id = record.id
        // the rename registry treats an upload as a reason to leave the file alone: a rename
        // mid-upload would move the bytes out from under URLSession
        Library.markInUse(id)
        Toast.show("Sharing…")

        Task { [weak self] in
            defer {
                Library.clearInUse(id)
                self?.inFlight.remove(id)
            }
            do {
                let link = try await ShareService.upload(fileURL: fileURL)
                try? library.setShareLink(id, url: link.url.absoluteString)
                self?.copy(link.url)
                LibraryWindowController.shared.reload()
                onFinish?(link.url)
            } catch let failure as ShareFailure {
                Toast.show(failure.description)
                if failure.isAuthFailure { SettingsWindowController.shared.show(tab: .sharing) }
                Log.shell.error("share failed: \(failure.description, privacy: .public)")
                onFinish?(nil)
            } catch {
                Toast.show("Share failed — \(error.localizedDescription)")
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
            do {
                try await ShareService.delete(id: shareID)
                try? library.setShareLink(id, url: nil)
                LibraryWindowController.shared.reload()
                Toast.show("Link deleted")
            } catch let failure as ShareFailure {
                Toast.show(failure.description)
            } catch {
                Toast.show("Could not delete the link")
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
