import Foundation
import GRDB

/// The index lives in Application Support, outside the watched library root (spec §2.1).
public final class Database: Sendable {
    public let queue: DatabaseQueue
    let operationLock = NSRecursiveLock()

    public init(directory: URL? = nil) throws {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kapture")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: dir.appendingPathComponent("library.sqlite").path)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "captures") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("status", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("trashedAt", .datetime)
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("bytes", .integer).notNull()
                t.column("relPath", .text).notNull().unique()
                t.column("sourceApp", .text)
                t.column("windowTitle", .text)
                t.column("screenID", .integer)
                t.column("fastID", .text).notNull()
                t.column("contentHash", .text)
                t.column("aiState", .text).notNull()
                t.column("summary", .text)
                t.column("shareURL", .text)
                t.column("shareStale", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "op_journal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("op", .text).notNull()          // write | discard | restore | sweep | rename
                t.column("captureId", .text).notNull()
                t.column("src", .text)
                t.column("dst", .text)
                t.column("startedAt", .datetime).notNull()
            }
            try db.create(table: "ingest_jobs") { t in
                t.column("captureId", .text).primaryKey()
                t.column("stage", .text).notNull()
                t.column("notBefore", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
            }
        }
        migrator.registerMigration("v2-recording-duration") { db in
            try db.alter(table: "captures") { t in
                t.add(column: "durationS", .double)
            }
        }
        // Search: external-content FTS5 over a plain source table. Contentless FTS5 can't be
        // UPDATEd (spec §2.2 F2), so fts_source holds the text and triggers keep the index in
        // step. OCR/AI columns fill in during M4's ingest work; name/app search works today.
        migrator.registerMigration("v3-search") { db in
            try db.create(table: "fts_source") { t in
                t.column("captureId", .text).primaryKey().references("captures", onDelete: .cascade)
                t.column("name", .text).notNull().defaults(to: "")
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("tags", .text).notNull().defaults(to: "")
                t.column("ocr", .text).notNull().defaults(to: "")
            }
            try db.create(virtualTable: "captures_fts", using: FTS5()) { t in
                t.synchronize(withTable: "fts_source")
                t.column("name")
                t.column("summary")
                t.column("tags")
                t.column("ocr")
                t.tokenizer = .unicode61()
            }
            // backfill existing rows from their filenames
            let rows = try Row.fetchAll(db, sql: "SELECT id, relPath FROM captures")
            for row in rows {
                let id: String = row["id"]
                let rel: String = row["relPath"]
                let name = (rel as NSString).lastPathComponent
                try db.execute(sql: "INSERT OR REPLACE INTO fts_source (captureId, name) VALUES (?, ?)",
                               arguments: [id, name])
            }
        }
        migrator.registerMigration("v4-revisions-and-recovery") { db in
            try db.alter(table: "captures") { $0.add(column: "contentRevision", .integer).notNull().defaults(to: 0) }
            try db.alter(table: "ingest_jobs") {
                $0.add(column: "revision", .integer).notNull().defaults(to: 0)
                $0.add(column: "generation", .text).notNull().defaults(to: "legacy")
            }
            try db.execute(sql: "UPDATE ingest_jobs SET generation = lower(hex(randomblob(16)))")
            try db.alter(table: "op_journal") { $0.add(column: "plan", .blob) }
        }
        migrator.registerMigration("v5-quarantined-recovery") { db in
            try db.alter(table: "op_journal") {
                $0.add(column: "recoveryError", .text)
            }
        }
        migrator.registerMigration("v6-recovery-backoff") { db in
            // recoveryError marks an entry a human has to look at; these track the ones that
            // are merely waiting for a permission, a disk, or a lock to come back.
            try db.alter(table: "op_journal") {
                $0.add(column: "attempts", .integer).notNull().defaults(to: 0)
                $0.add(column: "nextAttemptAt", .datetime)
                $0.add(column: "lastError", .text)
            }
            // The one definition of "this capture has an unfinished file operation". Every
            // query that must leave such a capture alone joins against it, so the rule cannot
            // drift between five pasted copies.
            try db.execute(sql: "CREATE VIEW blocked_captures AS SELECT DISTINCT captureId FROM op_journal")
        }
        try migrator.migrate(queue)
    }
}
