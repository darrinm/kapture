import Foundation
import GRDB

/// A generation distinguishes cancel/re-enqueue at the same pixel revision as well as edits.
public struct IngestJob: Sendable {
    public let captureId: String
    public let revision: Int64
    public let generation: String
    public let stage: String
    public let attempts: Int
}

extension Library {
    static func enqueueIngest(_ d: GRDB.Database, record: CaptureRecord, notBefore: Date,
                              replacing: Bool = false) throws {
        let generation = UUID().uuidString
        try d.execute(sql: """
            INSERT INTO ingest_jobs (captureId, stage, notBefore, attempts, revision, generation)
            VALUES (?, 'ocr', ?, 0, ?, ?)
            ON CONFLICT(captureId) DO UPDATE SET
                notBefore = MIN(notBefore, excluded.notBefore),
                stage = CASE WHEN revision != excluded.revision OR ? THEN 'ocr' ELSE stage END,
                attempts = CASE WHEN revision != excluded.revision OR ? THEN 0 ELSE attempts END,
                generation = CASE WHEN revision != excluded.revision OR ? THEN excluded.generation ELSE generation END,
                revision = excluded.revision
            """, arguments: [record.id, notBefore, record.contentRevision, generation, replacing, replacing, replacing])
    }

    public func enqueueIngest(_ id: String, notBefore: Date) throws {
        try withOperation(for: id) {
            try db.queue.write { d in
                guard let record = try CaptureRecord.fetchOne(d, key: id),
                      record.status != .trashed, record.status != .sweeping else { return }
                try Library.enqueueIngest(d, record: record, notBefore: notBefore)
            }
        }
    }

    public func nextIngestJob() throws -> IngestJob? {
        try db.queue.read { d in
            guard let row = try Row.fetchOne(d, sql: "SELECT * FROM ingest_jobs WHERE notBefore <= ? AND NOT EXISTS (SELECT 1 FROM op_journal WHERE captureId = ingest_jobs.captureId AND recoveryError IS NOT NULL) ORDER BY notBefore LIMIT 1",
                                             arguments: [Date()]) else { return nil }
            return IngestJob(captureId: row["captureId"], revision: row["revision"], generation: row["generation"],
                             stage: row["stage"], attempts: row["attempts"])
        }
    }

    static func currentIngestRecord(_ d: GRDB.Database, job: IngestJob) throws -> CaptureRecord? {
        guard let record = try CaptureRecord.fetchOne(d, key: job.captureId),
              record.contentRevision == job.revision, record.status != .trashed, record.status != .sweeping,
              try String.fetchOne(d, sql: "SELECT generation FROM ingest_jobs WHERE captureId = ?",
                                  arguments: [job.captureId]) == job.generation else { return nil }
        return record
    }

    public func ingestRecord(_ job: IngestJob) throws -> CaptureRecord? {
        try withOperation(for: job.captureId) {
            try db.queue.read { try Library.currentIngestRecord($0, job: job) }
        }
    }

    /// The revision check, index write, and job transition must share one transaction. An edit
    /// also takes the operation lock, so pixels cannot change between that check and the write.
    @discardableResult
    public func finishOCR(_ job: IngestJob, text: String, naming: Bool) throws -> Bool {
        try withOperation(for: job.captureId) {
            try db.queue.write { d in
                guard let record = try Library.currentIngestRecord(d, job: job) else { return false }
                try Library.indexText(d, id: job.captureId, ocr: String(text.prefix(20_000)))
                // Also notify capture observers when re-indexing an already named capture.
                let state: CaptureRecord.AIState = record.aiState.acceptsName ? .ocr : record.aiState
                try d.execute(sql: "UPDATE captures SET aiState = ? WHERE id = ?",
                              arguments: [state.rawValue, job.captureId])
                if naming && record.aiState.acceptsName {
                    try d.execute(sql: "UPDATE ingest_jobs SET stage = 'name', attempts = 0, lastError = NULL WHERE captureId = ?",
                                  arguments: [job.captureId])
                } else {
                    try d.execute(sql: "DELETE FROM ingest_jobs WHERE captureId = ?", arguments: [job.captureId])
                }
                return true
            }
        }
    }

    public func clearIngestJob(_ job: IngestJob) throws {
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM ingest_jobs WHERE captureId = ? AND generation = ? AND NOT EXISTS (SELECT 1 FROM op_journal WHERE captureId = ingest_jobs.captureId AND recoveryError IS NOT NULL)",
                          arguments: [job.captureId, job.generation])
        }
    }

    public func retryIngestJob(_ job: IngestJob, after delay: TimeInterval, error: String) throws {
        try db.queue.write { d in
            try d.execute(sql: """
                UPDATE ingest_jobs SET attempts = attempts + 1, notBefore = ?, lastError = ?
                WHERE captureId = ? AND generation = ?
                """, arguments: [Date().addingTimeInterval(delay), error, job.captureId, job.generation])
        }
    }
}
