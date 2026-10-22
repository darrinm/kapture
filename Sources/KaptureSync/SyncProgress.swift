// What the shared library is doing and how far it has to go, for Settings › Shared Library.
//
// Stage 5 of the rollout found the pane silent: a seed of 9 GB, a Mac waiting for approval and a
// thumbnail backfill all looked the same as nothing happening, and the only way to tell them
// apart was a script reading the index.
import Foundation
import GRDB
import KaptureCore

/// The step a sync pass is on. Only one pass and one upload drain run at a time, so there is at
/// most one of each.
public enum SyncActivity: Equatable, Sendable {
    case idle
    case exchanging                 // pushing this Mac's changes and pulling the others'
    case uploading(String)          // the file name of the capture being uploaded
    case downloadingThumbnails
}

public struct SyncProgress: Equatable, Sendable {
    public var activity: SyncActivity = .idle
    /// The last exchange with the server that succeeded.
    public var lastSync: Date?
    /// The last time this Mac asked, successful or not.
    public var lastAttempt: Date?
    public var lastError: String?
    /// Captures in the index, and how many of them the shared log has acknowledged.
    public var captures = 0
    public var inLog = 0
    /// Changes queued for the log.
    public var outbox = 0
    /// Captures whose bytes are queued for upload, and how many bytes that is.
    public var uploadsWaiting = 0
    public var uploadBytesWaiting: Int64 = 0
    /// Captures whose full file is not on this Mac (opened on demand).
    public var notOnThisMac = 0
    /// Thumbnails the log names that this Mac has not downloaded yet.
    public var thumbnailsMissing = 0

    public init() {}
}

extension SyncStore {
    /// The counts behind `SyncProgress`, in one read.
    func progressCounts(into progress: inout SyncProgress) throws {
        let row = try db.queue.read { d in
            try Row.fetchOne(d, sql: """
                SELECT
                  (SELECT count(*) FROM captures WHERE status != 'sweeping') AS captures,
                  (SELECT count(*) FROM captures WHERE acknowledged = 1) AS inLog,
                  (SELECT count(*) FROM sync_outbox) AS outbox,
                  (SELECT count(*) FROM upload_queue) AS uploads,
                  (SELECT coalesce(sum(c.bytes), 0) FROM upload_queue u
                     JOIN captures c ON c.id = u.captureId) AS uploadBytes,
                  (SELECT count(*) FROM captures
                     WHERE blobState != 'local' AND status != 'sweeping') AS remote,
                  (SELECT count(*) FROM blob_cache WHERE purpose = 'thumb') AS thumbs
                """)
        }
        guard let row else { return }
        progress.captures = row["captures"]
        progress.inLog = row["inLog"]
        progress.outbox = row["outbox"]
        progress.uploadsWaiting = row["uploads"]
        progress.uploadBytesWaiting = row["uploadBytes"]
        progress.notOnThisMac = row["remote"]
        progress.thumbnailsMissing = row["thumbs"]   // less what is on disk; see below
    }
}
