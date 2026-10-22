// Persistence for the shared library: the outbox, the cursor, and turning captures into rows.
//
// F90 keeps the merge pure, so this is where the database lives instead. The rule it enforces is
// F29: an op reaches `sync_outbox` in the same transaction as the row it describes, which is
// what makes a push durable across a quit and idempotent across a retry.

import Foundation
import GRDB
import KaptureCore

public struct SyncIdentity: Sendable, Equatable {
    public var deviceID: String
    public var cursor: Int64
    public var keyID: String?
    public var capabilities: String
    /// Where this device last wrote a snapshot (F33).
    public var lastSnapshotSeq: Int64

    public init(deviceID: String, cursor: Int64 = 0, keyID: String? = nil,
                capabilities: String = SyncStore.capabilityGeneration,
                lastSnapshotSeq: Int64 = 0) {
        self.deviceID = deviceID; self.cursor = cursor
        self.keyID = keyID; self.capabilities = capabilities
        self.lastSnapshotSeq = lastSnapshotSeq
    }

    /// How many ops have landed since the last snapshot — the quantity F33 actually gates on.
    ///
    /// The cursor is a log position, not a count, so passing it here made every sweep past
    /// seq 10,000 try to snapshot again.
    public var opsSinceSnapshot: Int64 { max(0, cursor - lastSnapshotSeq) }
}

public struct OutboxEntry: Sendable, Equatable {
    public var opID: String
    public var captureID: String
    public var kind: OpKind
    public var payload: Data
    public var requires: [BlobLocatorRef]
    public var observed: Int64
    public var v: Int
}

/// A `requires` entry as the envelope carries it (F98).
public struct BlobLocatorRef: Codable, Sendable, Equatable {
    public var purpose: BlobPurpose
    public var revision: Int64
    public var writer: String
    public var capture: String

    public init(purpose: BlobPurpose, revision: Int64, writer: String, capture: String) {
        self.purpose = purpose; self.revision = revision
        self.writer = writer; self.capture = capture
    }
}

public struct SyncStore: Sendable {
    public let db: KaptureCore.Database
    public let crypto: LibraryCrypto
    /// The library folder. With it, a deletion pulled from the log removes the file it names as
    /// well as the row (F7). Without it — the tests that only exercise rows — the file is left.
    public let root: URL?
    /// Where synced thumbnails are kept (`BlobStore.thumbnailDirectory`). With it, applying a
    /// merge removes a thumbnail whose locator changed or whose capture was deleted, so the next
    /// `fetchThumbnails` downloads the current one. Without it, thumbnail files are left alone.
    public let thumbnailDirectory: URL?

    public init(db: KaptureCore.Database, crypto: LibraryCrypto, root: URL? = nil,
                thumbnailDirectory: URL? = nil) {
        self.db = db
        self.crypto = crypto
        self.root = root
        self.thumbnailDirectory = thumbnailDirectory
    }

    /// What this build can apply: payload versions and op kinds together (F135).
    ///
    /// F104 replayed only when the payload version rose, which misses a release that adds a
    /// `kind` without bumping `v` — the skipped op then sits behind a cursor that has already
    /// passed it, forever. Keying replay on this string covers both.
    public static let capabilityGeneration = "v1;upsert,trash,restore,delete"
    public static let payloadVersion = 1

    /// Built once: constructing a coder costs far more than using one, and `enqueue` runs in a
    /// loop over a merge result.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// `Library` carries the same note on its own shard formatter: creation is expensive,
    /// formatting through a shared instance is thread-safe. `derivedRelPath` runs per row on a
    /// bootstrap, so a per-call formatter is a second of pure allocation over 10k rows.
    private static let shardFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM"
        return f
    }()

    // MARK: - Identity

    public func identity() throws -> SyncIdentity? {
        try db.queue.read { d in
            guard let row = try Row.fetchOne(d, sql: "SELECT * FROM sync_state WHERE id = 1")
            else { return nil }
            return SyncIdentity(deviceID: row["deviceID"], cursor: row["cursor"],
                                keyID: row["keyID"], capabilities: row["capabilities"],
                                lastSnapshotSeq: row["lastSnapshotSeq"] ?? 0)
        }
    }

    public func enable(deviceID: String) throws -> SyncIdentity {
        let identity = SyncIdentity(deviceID: deviceID, keyID: crypto.keyID)
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT OR REPLACE INTO sync_state (id, deviceID, cursor, keyID, enabledAt, capabilities)
                VALUES (1, ?, 0, ?, ?, ?)
                """, arguments: [deviceID, crypto.keyID, Date(), Self.capabilityGeneration])
        }
        return identity
    }

    public func advanceCursor(to seq: Int64) throws {
        try db.queue.write { d in
            try d.execute(sql: "UPDATE sync_state SET cursor = ? WHERE id = 1", arguments: [seq])
        }
    }

    public func recordSnapshot(at seq: Int64) throws {
        try db.queue.write { d in
            try d.execute(sql: "UPDATE sync_state SET lastSnapshotSeq = ? WHERE id = 1",
                          arguments: [seq])
        }
    }

    // MARK: - Rows

    /// A capture as the log carries it (F83, F84): no `relPath`, no `fastID`, no cache columns.
    public func row(for record: CaptureRecord, in d: GRDB.Database) throws -> SyncedRow {
        let ocr = try String.fetchOne(d, sql: "SELECT ocr FROM fts_source WHERE captureId = ?",
                                      arguments: [record.id])
        return row(for: record, ocr: ocr, blobs: try blobLocators(for: record.id, in: d))
    }

    /// F23, F129: the row must be enough on its own to reach its own bytes, because a snapshot
    /// carries the row and not the envelopes that once named them.
    func blobLocators(for captureID: String, in d: GRDB.Database) throws
        -> [BlobPurpose: BlobLocator] {
        var blobs: [BlobPurpose: BlobLocator] = [:]
        for entry in try Row.fetchAll(d, sql: """
            SELECT purpose, revision, writer, owningCapture FROM blob_cache WHERE captureId = ?
            """, arguments: [captureID]) {
            guard let purpose = BlobPurpose(rawValue: entry["purpose"]) else { continue }
            blobs[purpose] = BlobLocator(revision: entry["revision"], writer: entry["writer"],
                                         capture: entry["owningCapture"])
        }
        return blobs
    }

    func row(for record: CaptureRecord, ocr: String?,
             blobs: [BlobPurpose: BlobLocator]) -> SyncedRow {
        SyncedRow(
            captureID: record.id,
            lamport: record.lamport,
            deviceID: record.syncDeviceID ?? "",
            kind: record.kind,
            status: record.status,
            createdAt: record.createdAt,
            trashedAt: record.trashedAt,
            width: record.width,
            height: record.height,
            bytes: record.bytes,
            name: (record.relPath as NSString).lastPathComponent,
            sourceApp: record.sourceApp,
            windowTitle: record.windowTitle,
            contentRevision: record.contentRevision,
            contentHash: record.contentHash,
            parentHash: record.parentHash,
            aiState: record.aiState,
            summary: record.summary,
            ocr: ocr,
            shareURL: record.shareURL,
            durationS: record.durationS,
            blobs: blobs,
            // Carried, or every re-push of a fork tells the other Macs it is not one and the
            // F36 badge disappears.
            forkedFrom: record.forkedFrom)
    }

    /// The `requires` an op must carry for a row (F32, F98). Derived from the row rather than
    /// passed in, so a caller cannot forget it and leave the server's dependency check with
    /// nothing to check.
    public static func requires(for row: SyncedRow) -> [BlobLocatorRef] {
        row.blobs.map { purpose, locator in
            BlobLocatorRef(purpose: purpose, revision: locator.revision,
                           writer: locator.writer, capture: locator.capture)
        }
    }

    /// Every local row, as three table scans rather than four queries per capture.
    ///
    /// `pull` calls this once per page, so the per-row form was ~40,000 statements per call on a
    /// ten-thousand capture library and twenty times that during a bootstrap.
    public func localRows() throws -> [String: LocalRow] {
        try db.queue.read { d in
            var ocr: [String: String] = [:]
            for entry in try Row.fetchAll(d, sql: "SELECT captureId, ocr FROM fts_source") {
                ocr[entry["captureId"]] = entry["ocr"]
            }
            var blobs: [String: [BlobPurpose: BlobLocator]] = [:]
            for entry in try Row.fetchAll(d, sql: """
                SELECT captureId, purpose, revision, writer, owningCapture FROM blob_cache
                """) {
                guard let purpose = BlobPurpose(rawValue: entry["purpose"]) else { continue }
                let captureID: String = entry["captureId"]
                blobs[captureID, default: [:]][purpose] = BlobLocator(
                    revision: entry["revision"], writer: entry["writer"],
                    capture: entry["owningCapture"])
            }
            var rows: [String: LocalRow] = [:]
            for record in try CaptureRecord.fetchAll(d) {
                rows[record.id] = LocalRow(
                    row: row(for: record, ocr: ocr[record.id], blobs: blobs[record.id] ?? [:]),
                    acknowledged: record.acknowledged)
            }
            return rows
        }
    }

    /// The next `lamport` this device should stamp: `max(seen) + 1` (§7).
    public func nextLamport(in d: GRDB.Database) throws -> Int64 {
        (try Int64.fetchOne(d, sql: "SELECT MAX(lamport) FROM captures") ?? 0) + 1
    }

    // MARK: - The outbox (F29)

    /// Queue a row for push, in the caller's transaction.
    ///
    /// The payload is sealed here rather than at send time so the outbox holds ciphertext at
    /// rest: a queued op is no more readable on disk than it is on the server.
    public func enqueue(_ row: SyncedRow, kind: OpKind,
                        observed: Int64, deviceID: String, in d: GRDB.Database) throws {
        let opID = ULID.generate()
        let payload = try crypto.seal(row, scope: .row(opID: opID), writer: deviceID)
        let encoded = try Self.encoder.encode(Self.requires(for: row))
        try d.execute(sql: """
            INSERT INTO sync_outbox (opID, captureId, kind, payload, requires, observed, v, queuedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [opID, row.captureID, kind.rawValue, payload,
                             String(data: encoded, encoding: .utf8) ?? "[]",
                             observed, Self.payloadVersion, Date()])
    }

    /// Read a capture's current row and queue it, stamping the next `lamport` (§7).
    ///
    /// One transaction, because F29 requires the op and the row it describes to be written
    /// together — a queued op that does not match the row it claims to carry is worse than no op.
    public func enqueueCurrentRow(_ captureID: String, kind: OpKind, observed: Int64,
                                  deviceID: String) throws {
        try db.queue.write { d in
            guard let record = try CaptureRecord.fetchOne(d, key: captureID) else { return }
            var row = try self.row(for: record, in: d)
            row.lamport = try self.nextLamport(in: d)
            row.deviceID = deviceID
            try d.execute(sql: "UPDATE captures SET lamport = ?, syncDeviceID = ? WHERE id = ?",
                          arguments: [row.lamport, deviceID, captureID])
            try self.enqueue(row, kind: kind, observed: observed, deviceID: deviceID, in: d)
        }
    }

    public func pending(limit: Int = 100) throws -> [OutboxEntry] {
        try db.queue.read { d in
            let now = Date()
            let rows = try Row.fetchAll(d, sql: """
                SELECT * FROM sync_outbox
                WHERE nextAttemptAt IS NULL OR nextAttemptAt <= ?
                ORDER BY queuedAt LIMIT ?
                """, arguments: [now, limit])
            return rows.map { row in
                let raw: String = row["requires"]
                    let refs = (try? Self.decoder.decode([BlobLocatorRef].self,
                                                    from: Data(raw.utf8))) ?? []
                return OutboxEntry(
                    opID: row["opID"], captureID: row["captureId"],
                    kind: OpKind(rawValue: row["kind"]) ?? .upsert,
                    payload: row["payload"], requires: refs,
                    observed: row["observed"], v: row["v"])
            }
        }
    }

    /// Whether anything at all is queued, including entries backing off after a rejection.
    /// `pending()` hides those, and F111's "nothing queued" has to mean all of them.
    public func hasPending() throws -> Bool {
        try db.queue.read { d in
            try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM sync_outbox)") ?? false
        }
    }

    /// F30: an op leaves the outbox only once the server has acknowledged it, and F130 records
    /// that the log now knows this row.
    public func acknowledge(_ opIDs: [String]) throws {
        guard !opIDs.isEmpty else { return }
        try db.queue.write { d in
            let placeholders = databaseQuestionMarks(count: opIDs.count)
            let captureIDs = try String.fetchAll(
                d, sql: "SELECT captureId FROM sync_outbox WHERE opID IN (\(placeholders))",
                arguments: StatementArguments(opIDs))
            try d.execute(sql: "DELETE FROM sync_outbox WHERE opID IN (\(placeholders))",
                          arguments: StatementArguments(opIDs))
            if !captureIDs.isEmpty {
                let marks = databaseQuestionMarks(count: captureIDs.count)
                try d.execute(sql: "UPDATE captures SET acknowledged = 1 WHERE id IN (\(marks))",
                              arguments: StatementArguments(captureIDs))
            }
        }
    }

    /// A rejected op backs off rather than spinning, reusing the schedule `op_journal` uses.
    public func deferEntry(_ opID: String, error: String, after delay: TimeInterval) throws {
        try db.queue.write { d in
            try d.execute(sql: """
                UPDATE sync_outbox
                SET attempts = attempts + 1, nextAttemptAt = ?, lastError = ?
                WHERE opID = ?
                """, arguments: [Date().addingTimeInterval(delay), error, opID])
        }
    }

    public func drop(_ opID: String) throws {
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM sync_outbox WHERE opID = ?", arguments: [opID])
        }
    }

    // MARK: - The upload queue (F10)

    /// Queue a capture's bytes for upload. Keyed by capture, so a second edit before the first
    /// upload drains replaces the entry rather than queuing a stale revision behind it.
    public func queueUpload(_ captureID: String) throws {
        try db.queue.write { d in try queueUpload(captureID, in: d) }
    }

    func queueUpload(_ captureID: String, in d: GRDB.Database) throws {
        try d.execute(sql: """
            INSERT INTO upload_queue (captureId, queuedAt, attempts, nextAttemptAt, lastError, priority)
            VALUES (?, ?, 0, NULL, NULL, 0)
            ON CONFLICT(captureId) DO UPDATE SET
              queuedAt = excluded.queuedAt, attempts = 0, nextAttemptAt = NULL, lastError = NULL,
              priority = 0
            """, arguments: [captureID, Date()])
    }

    /// Live changes before seeded ones, and within each the newest capture first (F65): the
    /// captures someone wants on a second Mac are the recent ones, and a new screenshot must
    /// not wait behind a seed of ten thousand old ones.
    public func dueUploads() throws -> [String] {
        try db.queue.read { d in
            try String.fetchAll(d, sql: """
                SELECT u.captureId FROM upload_queue u
                LEFT JOIN captures c ON c.id = u.captureId
                WHERE u.nextAttemptAt IS NULL OR u.nextAttemptAt <= ?
                ORDER BY u.priority ASC, c.createdAt DESC
                """, arguments: [Date()])
        }
    }

    public func queuedUploads() throws -> [String] {
        try db.queue.read { d in try String.fetchAll(d, sql: "SELECT captureId FROM upload_queue") }
    }

    /// The file and revision to upload *now*: an edit since the capture was queued replaces
    /// both, and uploading the queued ones would push a row naming bytes that no longer match.
    public func currentContent(of captureID: String) throws
        -> (relPath: String, revision: Int64, kind: CaptureKind)? {
        try db.queue.read { d in
            guard let record = try CaptureRecord.fetchOne(d, key: captureID) else { return nil }
            return (record.relPath, record.contentRevision, record.kind)
        }
    }

    /// Leave the queue and enter the outbox in one transaction (F29). Two transactions would let
    /// a crash between them remove the upload and never queue the row that names it.
    ///
    /// `revision` is the revision whose bytes were uploaded. An edit committed during the upload
    /// re-queues the capture under the same `upload_queue` entry. In that case the entry stays
    /// for the next drain and no row is queued, because the row would carry the new revision
    /// with the uploaded revision's locator.
    public func completeUpload(_ captureID: String, revision: Int64, observed: Int64,
                               deviceID: String) throws {
        try db.queue.write { d in
            guard let record = try CaptureRecord.fetchOne(d, key: captureID) else {
                try d.execute(sql: "DELETE FROM upload_queue WHERE captureId = ?",
                              arguments: [captureID])
                return
            }
            guard record.contentRevision == revision else { return }
            try d.execute(sql: "DELETE FROM upload_queue WHERE captureId = ?", arguments: [captureID])
            var row = try self.row(for: record, in: d)
            row.lamport = try self.nextLamport(in: d)
            row.deviceID = deviceID
            try d.execute(sql: "UPDATE captures SET lamport = ?, syncDeviceID = ? WHERE id = ?",
                          arguments: [row.lamport, deviceID, captureID])
            try self.enqueue(row, kind: .upsert, observed: observed, deviceID: deviceID, in: d)
        }
    }

    /// Back off a failed upload: a minute, doubling, capped at an hour.
    public func deferUpload(_ captureID: String, error: String) throws {
        try db.queue.write { d in
            let attempts = try Int.fetchOne(
                d, sql: "SELECT attempts FROM upload_queue WHERE captureId = ?",
                arguments: [captureID]) ?? 0
            let delay = min(60 * pow(2, Double(attempts)), 3600)
            try d.execute(sql: """
                UPDATE upload_queue
                SET attempts = attempts + 1, nextAttemptAt = ?, lastError = ?
                WHERE captureId = ?
                """, arguments: [Date().addingTimeInterval(delay), error, captureID])
        }
    }

    public func dropUpload(_ captureID: String) throws {
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM upload_queue WHERE captureId = ?", arguments: [captureID])
        }
    }

    // MARK: - Seeding (§11.1, F62-F66, F70, F72)

    /// Captures this Mac holds that the log has never seen: not acknowledged, not already
    /// queued either way, and not mid-sweep (F40 keeps `sweeping` local).
    private static let seedCandidatesSQL = """
        SELECT id FROM captures
        WHERE acknowledged = 0 AND status != 'sweeping'
          AND id NOT IN (SELECT captureId FROM sync_outbox)
          AND id NOT IN (SELECT captureId FROM upload_queue)
        """

    public func isSeeded() throws -> Bool {
        try db.queue.read { d in
            try Row.fetchOne(d, sql: "SELECT seededAt FROM sync_state WHERE id = 1")?["seededAt"]
                as Date? != nil
        }
    }

    /// How many local captures seeding would add — what F72's confirmation states.
    public func seedCandidateCount() throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM (\(Self.seedCandidatesSQL))") ?? 0
        }
    }

    /// Hand this Mac's existing library to the log, in one transaction (F62).
    ///
    /// Rows first and bytes after (F65): every candidate's row is queued now, carrying its status —
    /// a trashed capture as a trash op, so the sweep sees it (F64) — and its bytes are queued at
    /// seed priority for the upload drain, which re-pushes each row with its locators once the
    /// bytes land (F68). One transaction makes it all-or-nothing, so an interrupted seed simply
    /// runs again on the next launch (F63). Returns how many captures were seeded.
    @discardableResult
    public func seed(deviceID: String, observed: Int64) throws -> Int {
        try db.queue.write { d in
            let ids = try String.fetchAll(d, sql: Self.seedCandidatesSQL)
            for id in ids {
                guard let record = try CaptureRecord.fetchOne(d, key: id) else { continue }
                var row = try self.row(for: record, in: d)
                row.lamport = try self.nextLamport(in: d)
                row.deviceID = deviceID
                try d.execute(sql: "UPDATE captures SET lamport = ?, syncDeviceID = ? WHERE id = ?",
                              arguments: [row.lamport, deviceID, id])
                try self.enqueue(row, kind: record.status == .trashed ? .trash : .upsert,
                                 observed: observed, deviceID: deviceID, in: d)
                try d.execute(sql: """
                    INSERT OR IGNORE INTO upload_queue (captureId, queuedAt, attempts, priority)
                    VALUES (?, ?, 0, 1)
                    """, arguments: [id, Date()])
            }
            try d.execute(sql: "UPDATE sync_state SET seededAt = ? WHERE id = 1", arguments: [Date()])
            return ids.count
        }
    }

    /// Record that there was nothing to seed, so the check is not repeated (F73).
    public func markSeeded() throws {
        try db.queue.write { d in
            try d.execute(sql: "UPDATE sync_state SET seededAt = ? WHERE id = 1", arguments: [Date()])
        }
    }

    // MARK: - Skipped ops (F78, F104, F135)

    public func noteSkipped(seq: Int64, v: Int, kind: String) throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT OR REPLACE INTO skipped_ops (seq, v, kind, noticedAt) VALUES (?, ?, ?, ?)
                """, arguments: [seq, v, kind, Date()])
        }
    }

    public func skippedSeqs() throws -> [Int64] {
        try db.queue.read { d in
            try Int64.fetchAll(d, sql: "SELECT seq FROM skipped_ops ORDER BY seq")
        }
    }

    /// Whether this build's capabilities have widened since the skipped ops were recorded
    /// (F135). Replay is keyed on the whole capability string, not the payload version alone: a
    /// release that adds a `kind` without bumping `v` would otherwise never go back for them.
    /// Rewind past what this build skipped, forget it, and record the new generation — in one
    /// transaction (F135).
    ///
    /// Spelled out inline in the lifecycle method, this was four separate `try?` calls: a crash
    /// between the rewind and the clear left a rewound cursor with the skipped rows still in
    /// place, and each `try?` threw away the error that would have said so.
    @discardableResult
    public func replaySkippedIfCapabilitiesWidened() throws -> Bool {
        try db.queue.write { d in
            let current = try String.fetchOne(
                d, sql: "SELECT capabilities FROM sync_state WHERE id = 1")
            guard let current, current != Self.capabilityGeneration else { return false }
            if let oldest = try Int64.fetchOne(d, sql: "SELECT MIN(seq) FROM skipped_ops") {
                try d.execute(sql: "UPDATE sync_state SET cursor = ? WHERE id = 1",
                              arguments: [max(0, oldest - 1)])
            }
            try d.execute(sql: "DELETE FROM skipped_ops")
            try d.execute(sql: "UPDATE sync_state SET capabilities = ? WHERE id = 1",
                          arguments: [Self.capabilityGeneration])
            return true
        }
    }

    public func capabilitiesWidened() throws -> Bool {
        guard let identity = try identity() else { return false }
        return identity.capabilities != Self.capabilityGeneration
    }

    public func recordCapabilities() throws {
        try db.queue.write { d in
            try d.execute(sql: "UPDATE sync_state SET capabilities = ? WHERE id = 1",
                          arguments: [Self.capabilityGeneration])
        }
    }

    public func clearSkipped() throws {
        try db.queue.write { d in try d.execute(sql: "DELETE FROM skipped_ops") }
    }

    // MARK: - Applying a merge

    /// Write a merge result. One transaction, so a crash mid-apply leaves the cursor behind and
    /// the page is simply replayed (F26).
    public func apply(_ result: MergeResult, cursor: Int64?, deviceID: String) throws {
        // Files are removed after the transaction commits: the filesystem is not
        // transactional, and removing a file whose row then failed to delete would leave a
        // row pointing at nothing.
        let (removed, staleThumbnails, moves) = try db.queue.write {
            d -> ([String], [String], [(from: String, to: String)]) in
            var removedPaths: [String] = []
            // `missingThumbnails` checks only whether `<id>.jpg` exists. A thumbnail fetched for
            // an older revision would stay in the grid after another Mac's edit, and a deleted
            // capture's thumbnail would stay on disk, unless the file is removed here.
            var staleThumbnails: [String] = []
            // A fork is minted here and has never been near the log. Marking it acknowledged
            // would make F130 read its absence from the next snapshot as a delete and remove
            // the edit this device just rescued.
            let forks = Set(result.forks)

            // A fork of this Mac's edit whose bytes have not uploaded yet. The fork inherits the
            // local row's locators, which still name the bytes from before the edit, and the
            // edited file is still at the original's path, where the queued upload would send
            // it as the original's new revision over the other Mac's edit. The edit is the
            // fork's: its file moves to the fork, which uploads under its own key, and the
            // original is fetched again from the server.
            var unuploaded: [(fork: String, original: String, relPath: String)] = []
            for row in result.upserts where forks.contains(row.captureID) {
                guard let original = row.forkedFrom,
                      let local = try CaptureRecord.fetchOne(d, key: original),
                      local.contentHash != nil, local.contentHash == row.contentHash,
                      try Int.fetchOne(d, sql: "SELECT count(*) FROM upload_queue WHERE captureId = ?",
                                       arguments: [original]) ?? 0 > 0 else { continue }
                unuploaded.append((row.captureID, original, local.relPath))
            }

            for row in result.upserts {
                if thumbnailDirectory != nil, let incoming = row.blobs[.thumb],
                   let held = try blobLocators(for: row.captureID, in: d)[.thumb],
                   incoming != held {
                    staleThumbnails.append(row.captureID)
                }
                try upsert(row, in: d, acknowledged: !forks.contains(row.captureID))
            }
            for captureID in result.deletions {
                staleThumbnails.append(captureID)
                if let relPath = try String.fetchOne(
                    d, sql: "SELECT relPath FROM captures WHERE id = ?", arguments: [captureID]) {
                    removedPaths.append(relPath)
                }
                try d.execute(sql: "DELETE FROM captures WHERE id = ?", arguments: [captureID])
                try d.execute(sql: "DELETE FROM fts_source WHERE captureId = ?",
                              arguments: [captureID])
                try d.execute(sql: "DELETE FROM blob_cache WHERE captureId = ?",
                              arguments: [captureID])
            }
            for row in result.outbox {
                try upsert(row, in: d, acknowledged: false)
                try enqueue(row, kind: .upsert, observed: cursor ?? 0,
                            deviceID: deviceID, in: d)
            }
            var moves: [(from: String, to: String)] = []
            for edit in unuploaded {
                guard let forkPath = try String.fetchOne(
                    d, sql: "SELECT relPath FROM captures WHERE id = ?", arguments: [edit.fork])
                else { continue }
                try d.execute(sql: "DELETE FROM blob_cache WHERE captureId = ?",
                              arguments: [edit.fork])
                try d.execute(sql: "DELETE FROM sync_outbox WHERE captureId = ?",
                              arguments: [edit.fork])
                try d.execute(sql: "UPDATE captures SET blobState = 'local' WHERE id = ?",
                              arguments: [edit.fork])
                try d.execute(sql: "UPDATE captures SET blobState = 'remote' WHERE id = ?",
                              arguments: [edit.original])
                try d.execute(sql: "DELETE FROM upload_queue WHERE captureId = ?",
                              arguments: [edit.original])
                try queueUpload(edit.fork, in: d)
                moves.append((edit.relPath, forkPath))
            }
            if let cursor {
                try d.execute(sql: "UPDATE sync_state SET cursor = ? WHERE id = 1",
                              arguments: [cursor])
            }
            return (removedPaths, staleThumbnails, moves)
        }
        removeFiles(atRelPaths: removed)
        moveFiles(moves)
        if let thumbnailDirectory {
            for captureID in staleThumbnails {
                try? FileManager.default.removeItem(
                    at: thumbnailDirectory.appendingPathComponent("\(captureID).jpg"))
            }
        }
    }

    /// An unuploaded edit's file and sidecar, from the original's path to its fork's.
    func moveFiles(_ moves: [(from: String, to: String)]) {
        guard let root else { return }
        let files = FileManager.default
        for move in moves {
            let source = root.appendingPathComponent(move.from)
            let target = root.appendingPathComponent(move.to)
            try? files.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
            try? files.moveItem(at: Sidecar.url(for: source), to: Sidecar.url(for: target))
            try? files.moveItem(at: source, to: target)
        }
    }

    /// A deleted capture's file, its sidecar, and the pre-edit original the sidecar names.
    ///
    /// `MergeResult.deletions` promises "their bytes go too". Dropping only the rows left every
    /// Mac holding a file with nothing pointing at it, so disk use never fell after a sweep.
    func removeFiles(atRelPaths relPaths: [String]) {
        guard let root else { return }
        let files = FileManager.default
        for relPath in relPaths {
            let file = root.appendingPathComponent(relPath)
            if let original = Sidecar.read(for: file)?.annotations?.original {
                try? files.removeItem(at: root.appendingPathComponent(original))
            }
            try? files.removeItem(at: Sidecar.url(for: file))
            try? files.removeItem(at: file)
        }
    }

    /// Write one synced row into `captures`, deriving the device-local fields rather than
    /// taking them from the log (F83): `relPath` is this Mac's, not the sender's.
    func upsert(_ row: SyncedRow, in d: GRDB.Database, acknowledged: Bool) throws {
        // Fetch the whole record and write the whole record. The hand-written INSERT this
        // replaces named 26 columns in three lists that had to stay aligned by eye, and it
        // duplicated a schema `CaptureRecord` already describes.
        let existing = try CaptureRecord.fetchOne(d, key: row.captureID)
        let heldBlob = try blobLocators(for: row.captureID, in: d)[.blob]
        var record = try existing
            ?? CaptureRecord(id: row.captureID, kind: row.kind, status: row.status,
                             createdAt: row.createdAt, width: row.width, height: row.height,
                             bytes: row.bytes, relPath: availableRelPath(for: row, in: d),
                             sourceApp: row.sourceApp, windowTitle: row.windowTitle,
                             fastID: "")

        // The log's fields. `relPath` and `fastID` are deliberately absent: they are
        // device-local (F83, F84), so a row that already exists keeps this Mac's.
        record.kind = row.kind
        record.status = row.status
        record.createdAt = row.createdAt
        record.trashedAt = row.trashedAt
        record.width = row.width
        record.height = row.height
        record.bytes = row.bytes
        record.sourceApp = row.sourceApp
        record.windowTitle = row.windowTitle
        record.contentRevision = row.contentRevision
        record.contentHash = row.contentHash
        record.aiState = row.aiState
        record.summary = row.summary
        record.shareURL = row.shareURL
        record.durationS = row.durationS
        record.lamport = row.lamport
        record.syncDeviceID = row.deviceID
        record.forkedFrom = row.forkedFrom
        record.parentHash = row.parentHash
        record.acknowledged = acknowledged

        // Where this Mac's bytes stand. A new row is `remote` when the log names bytes for it. A
        // row already held keeps its state — it made the capture, or fetched it — unless the log
        // now names a different revision or writer than the one on disk, in which case the file
        // here is the old content and opening it must fetch the new one.
        if existing == nil {
            record.blobState = row.blobs.isEmpty ? BlobState.local.rawValue
                                                 : BlobState.remote.rawValue
        } else if let incoming = row.blobs[.blob], incoming != heldBlob {
            record.blobState = BlobState.remote.rawValue
        }
        try record.save(d)

        // The locators themselves (F23, F129). Without them a capture pulled from another Mac
        // has no way to reach its bytes here: `BlobStore.fetch` finds no locator, marks it
        // missing, and every later push or snapshot from this Mac drops the locators too. Only
        // the address columns are written; `bytes` and `lastOpenedAt` are this Mac's own.
        for (purpose, locator) in row.blobs {
            try d.execute(sql: """
                INSERT INTO blob_cache (captureId, purpose, revision, writer, owningCapture, bytes)
                VALUES (?, ?, ?, ?, ?, 0)
                ON CONFLICT(captureId, purpose) DO UPDATE SET
                  revision = excluded.revision, writer = excluded.writer,
                  owningCapture = excluded.owningCapture
                """, arguments: [row.captureID, purpose.rawValue, locator.revision,
                                 locator.writer, locator.capture])
        }

        try d.execute(sql: """
            INSERT INTO fts_source (captureId, name, summary, tags, ocr) VALUES (?, ?, ?, '', ?)
            ON CONFLICT(captureId) DO UPDATE SET
              name = excluded.name, summary = excluded.summary, ocr = excluded.ocr
            """, arguments: [row.captureID, row.name, row.summary ?? "", row.ocr ?? ""])
    }

    /// A path for a capture this Mac has never held, free both in the index and on disk.
    ///
    /// Names are second-resolution timestamps, so two Macs capturing in the same second produce
    /// the same one, and `captures.relPath` is UNIQUE. Without this the pulled row fails the
    /// constraint, the page's transaction rolls back, the cursor never moves, and every later
    /// pull fails on the same page. The suffix follows `Library.uniqueURL`'s " 2", " 3" form.
    func availableRelPath(for row: SyncedRow, in d: GRDB.Database) throws -> String {
        let base = Self.derivedRelPath(for: row)
        func taken(_ candidate: String) throws -> Bool {
            if try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM captures WHERE relPath = ?)",
                                 arguments: [candidate]) == true { return true }
            if let root, FileManager.default.fileExists(
                atPath: root.appendingPathComponent(candidate).path) { return true }
            return false
        }
        guard try taken(base) else { return base }
        let ns = base as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? base : ns.deletingPathExtension
        for n in 2...10_000 {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if try !taken(candidate) { return candidate }
        }
        // Ten thousand collisions on one name is not a real library; the id cannot collide.
        return ext.isEmpty ? "\(stem) \(row.captureID)" : "\(stem) \(row.captureID).\(ext)"
    }

    /// This Mac's path for a capture it has never held: the sharded directory its date implies,
    /// with the log's name. F83 keeps paths local, so nothing here consults the sender's.
    static func derivedRelPath(for row: SyncedRow) -> String {
        // The name is sanitized to a single component: an op is attacker-controlled if a device
        // credential leaks (§13), and a name carrying a separator would escape the shard.
        var safe = row.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "..", with: "-")
        // An empty name or "." makes the path the shard directory itself. A later delete or
        // eviction of that capture then removes the directory and every capture in it.
        if safe.isEmpty || safe == "." { safe = row.captureID }
        return "\(shardFormatter.string(from: row.createdAt))/\(safe)"
    }
}
