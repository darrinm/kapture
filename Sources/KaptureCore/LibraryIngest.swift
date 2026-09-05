import Foundation
import GRDB

/// A generation tells a cancel-and-re-enqueue from the job it replaced, and an edit — which
/// always re-enqueues under a fresh one — from the OCR that was in flight against the old
/// pixels. A result belongs to its generation; a job that has moved on ignores it.
public struct IngestJob: Sendable {
    public enum Stage: String, Sendable {
        case ocr, name
    }

    public let captureId: String
    public let generation: String
    public let stage: Stage
    public let attempts: Int
}

extension Library {
    static func enqueueIngest(_ d: GRDB.Database, record: CaptureRecord, notBefore: Date,
                              replacing: Bool = false) throws {
        // The pixels changed: whatever stage the old job reached, it was reading the old ones.
        // Start over under a generation the in-flight result cannot claim.
        if replacing { try cancelIngest(d, id: record.id) }
        try d.execute(sql: """
            INSERT INTO ingest_jobs (captureId, stage, notBefore, attempts, generation)
            VALUES (?, ?, ?, 0, ?)
            ON CONFLICT(captureId) DO UPDATE SET notBefore = MIN(notBefore, excluded.notBefore)
            """, arguments: [record.id, IngestJob.Stage.ocr.rawValue, notBefore, UUID().uuidString])
    }

    static func cancelIngest(_ d: GRDB.Database, id: String) throws {
        try d.execute(sql: "DELETE FROM ingest_jobs WHERE captureId = ?", arguments: [id])
    }

    public func enqueueIngest(_ id: String, notBefore: Date) throws {
        try withOperation(for: id) {
            try db.queue.write { d in
                guard let record = try CaptureRecord.fetchOne(d, key: id), record.isLive else { return }
                try Library.enqueueIngest(d, record: record, notBefore: notBefore)
            }
        }
    }

    public func cancelIngest(_ id: String) throws {
        try db.queue.write { try Library.cancelIngest($0, id: id) }
    }

    public func nextIngestJob() throws -> IngestJob? {
        try db.queue.read { d in
            guard let row = try Row.fetchOne(d, sql: """
                SELECT * FROM ingest_jobs WHERE notBefore <= ?
                    AND captureId NOT IN (SELECT captureId FROM blocked_captures)
                ORDER BY notBefore LIMIT 1
                """, arguments: [Date()]) else { return nil }
            return IngestJob(captureId: row["captureId"], generation: row["generation"],
                             stage: IngestJob.Stage(rawValue: row["stage"]) ?? .ocr, attempts: row["attempts"])
        }
    }

    static func currentIngestRecord(_ d: GRDB.Database, job: IngestJob) throws -> CaptureRecord? {
        guard let record = try CaptureRecord.fetchOne(d, key: job.captureId), record.isLive,
              try String.fetchOne(d, sql: "SELECT generation FROM ingest_jobs WHERE captureId = ?",
                                  arguments: [job.captureId]) == job.generation else { return nil }
        return record
    }

    public func ingestRecord(_ job: IngestJob) throws -> CaptureRecord? {
        try withOperation(for: job.captureId) {
            try db.queue.read { try Library.currentIngestRecord($0, job: job) }
        }
    }

    /// The generation check, index write, and job transition must share one transaction. An
    /// edit also takes the operation lock, so pixels cannot change between that check and the
    /// write.
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
                    try d.execute(sql: "UPDATE ingest_jobs SET stage = ?, attempts = 0, lastError = NULL WHERE captureId = ?",
                                  arguments: [IngestJob.Stage.name.rawValue, job.captureId])
                } else {
                    try Library.cancelIngest(d, id: job.captureId)
                }
                return true
            }
        }
    }

    public func clearIngestJob(_ job: IngestJob) throws {
        try db.queue.write { d in
            try d.execute(sql: """
                DELETE FROM ingest_jobs WHERE captureId = ? AND generation = ?
                    AND captureId NOT IN (SELECT captureId FROM blocked_captures)
                """, arguments: [job.captureId, job.generation])
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
