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

    public init(deviceID: String, cursor: Int64 = 0, keyID: String? = nil,
                capabilities: String = SyncStore.capabilityGeneration) {
        self.deviceID = deviceID; self.cursor = cursor
        self.keyID = keyID; self.capabilities = capabilities
    }
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

    public init(db: KaptureCore.Database, crypto: LibraryCrypto) {
        self.db = db
        self.crypto = crypto
    }

    /// What this build can apply: payload versions and op kinds together (F135).
    ///
    /// F104 replayed only when the payload version rose, which misses a release that adds a
    /// `kind` without bumping `v` — the skipped op then sits behind a cursor that has already
    /// passed it, forever. Keying replay on this string covers both.
    public static let capabilityGeneration = "v1;upsert,trash,restore,delete"
    public static let payloadVersion = 1

    // MARK: - Identity

    public func identity() throws -> SyncIdentity? {
        try db.queue.read { d in
            guard let row = try Row.fetchOne(d, sql: "SELECT * FROM sync_state WHERE id = 1")
            else { return nil }
            return SyncIdentity(deviceID: row["deviceID"], cursor: row["cursor"],
                                keyID: row["keyID"], capabilities: row["capabilities"])
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

    // MARK: - Rows

    /// A capture as the log carries it (F83, F84): no `relPath`, no `fastID`, no cache columns.
    public func row(for record: CaptureRecord, in d: GRDB.Database) throws -> SyncedRow {
        let extra = try Row.fetchOne(d, sql: """
            SELECT lamport, syncDeviceID, forkedFrom, parentHash FROM captures WHERE id = ?
            """, arguments: [record.id])
        let ocr = try String.fetchOne(d, sql: "SELECT ocr FROM fts_source WHERE captureId = ?",
                                      arguments: [record.id])
        // F23, F129: the row must be enough on its own to reach its own bytes, because a
        // snapshot carries the row and not the envelopes that once named them.
        var blobs: [BlobPurpose: BlobLocator] = [:]
        for entry in try Row.fetchAll(d, sql: """
            SELECT purpose, revision, writer, owningCapture FROM blob_cache WHERE captureId = ?
            """, arguments: [record.id]) {
            guard let purpose = BlobPurpose(rawValue: entry["purpose"]) else { continue }
            blobs[purpose] = BlobLocator(revision: entry["revision"], writer: entry["writer"],
                                         capture: entry["owningCapture"])
        }
        return SyncedRow(
            captureID: record.id,
            lamport: extra?["lamport"] ?? 0,
            deviceID: extra?["syncDeviceID"] ?? "",
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
            parentHash: extra?["parentHash"],
            aiState: record.aiState,
            summary: record.summary,
            ocr: ocr,
            shareURL: record.shareURL,
            durationS: record.durationS,
            blobs: blobs)
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

    public func localRows() throws -> [String: LocalRow] {
        try db.queue.read { d in
            var rows: [String: LocalRow] = [:]
            for record in try CaptureRecord.fetchAll(d) {
                let acknowledged = try Bool.fetchOne(
                    d, sql: "SELECT acknowledged FROM captures WHERE id = ?",
                    arguments: [record.id]) ?? false
                rows[record.id] = LocalRow(row: try row(for: record, in: d),
                                           acknowledged: acknowledged)
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
    public func enqueue(_ row: SyncedRow, kind: OpKind, requires: [BlobLocatorRef]? = nil,
                        observed: Int64, deviceID: String, in d: GRDB.Database) throws {
        let opID = ULID.generate()
        let payload = try crypto.seal(row, scope: .row(opID: opID), writer: deviceID)
        let encoded = try JSONEncoder().encode(requires ?? Self.requires(for: row))
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
                let refs = (try? JSONDecoder().decode([BlobLocatorRef].self,
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
        try db.queue.write { d in
            // A fork is minted here and has never been near the log. Marking it acknowledged
            // would make F130 read its absence from the next snapshot as a delete and remove
            // the edit this device just rescued.
            let forks = Set(result.forks)
            for row in result.upserts {
                try upsert(row, in: d, acknowledged: !forks.contains(row.captureID))
            }
            for captureID in result.deletions {
                try d.execute(sql: "DELETE FROM captures WHERE id = ?", arguments: [captureID])
                try d.execute(sql: "DELETE FROM fts_source WHERE captureId = ?",
                              arguments: [captureID])
            }
            for row in result.outbox {
                try upsert(row, in: d, acknowledged: false)
                try enqueue(row, kind: .upsert, observed: cursor ?? 0,
                            deviceID: deviceID, in: d)
            }
            if let cursor {
                try d.execute(sql: "UPDATE sync_state SET cursor = ? WHERE id = 1",
                              arguments: [cursor])
            }
        }
    }

    /// Write one synced row into `captures`, deriving the device-local fields rather than
    /// taking them from the log (F83): `relPath` is this Mac's, not the sender's.
    func upsert(_ row: SyncedRow, in d: GRDB.Database, acknowledged: Bool) throws {
        let existing = try Row.fetchOne(d, sql: "SELECT relPath, blobState FROM captures WHERE id = ?",
                                        arguments: [row.captureID])
        let relPath: String = existing?["relPath"] ?? Self.derivedRelPath(for: row)
        // A row this Mac already holds keeps the state it has: it made the capture, or it has
        // already fetched it, and the log has no opinion about where the bytes are on this
        // machine (F83, F84). Only a genuinely new row starts as `remote`, and only when the
        // log says bytes exist for it.
        let blobState: String = existing?["blobState"]
            ?? (row.blobs.isEmpty ? BlobState.local.rawValue : BlobState.remote.rawValue)

        try d.execute(sql: """
            INSERT INTO captures
              (id, kind, status, createdAt, trashedAt, width, height, bytes, relPath, sourceApp,
               windowTitle, screenID, fastID, contentHash, aiState, summary, shareURL, shareStale,
               durationS, contentRevision, lamport, syncDeviceID, forkedFrom, blobState,
               parentHash, acknowledged)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, '', ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              status = excluded.status, trashedAt = excluded.trashedAt, width = excluded.width,
              height = excluded.height, bytes = excluded.bytes, sourceApp = excluded.sourceApp,
              windowTitle = excluded.windowTitle, contentHash = excluded.contentHash,
              aiState = excluded.aiState, summary = excluded.summary,
              shareURL = excluded.shareURL, durationS = excluded.durationS,
              contentRevision = excluded.contentRevision, lamport = excluded.lamport,
              syncDeviceID = excluded.syncDeviceID, forkedFrom = excluded.forkedFrom,
              parentHash = excluded.parentHash, acknowledged = excluded.acknowledged
            """, arguments: [
                row.captureID, row.kind.rawValue, row.status.rawValue, row.createdAt,
                row.trashedAt, row.width, row.height, row.bytes, relPath, row.sourceApp,
                row.windowTitle, row.contentHash, row.aiState.rawValue, row.summary,
                row.shareURL, row.durationS, row.contentRevision, row.lamport, row.deviceID,
                row.forkedFrom, blobState, row.parentHash,
                acknowledged,
            ])

        try d.execute(sql: """
            INSERT INTO fts_source (captureId, name, summary, tags, ocr) VALUES (?, ?, ?, '', ?)
            ON CONFLICT(captureId) DO UPDATE SET
              name = excluded.name, summary = excluded.summary, ocr = excluded.ocr
            """, arguments: [row.captureID, row.name, row.summary ?? "", row.ocr ?? ""])
    }

    /// This Mac's path for a capture it has never held: the sharded directory its date implies,
    /// with the log's name. F83 keeps paths local, so nothing here consults the sender's.
    static func derivedRelPath(for row: SyncedRow) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM"
        // The name is sanitized to a single component: an op is attacker-controlled if a device
        // credential leaks (§13), and a name carrying a separator would escape the shard.
        let safe = row.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "..", with: "-")
        return "\(formatter.string(from: row.createdAt))/\(safe)"
    }
}

func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
