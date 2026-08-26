import Foundation
import GRDB

/// The index lives in Application Support, outside the watched library root (spec §2.1).
public final class Database: Sendable {
    public let queue: DatabaseQueue

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
        try migrator.migrate(queue)
    }
}

/// Intent journal (spec §2.2 F1): journal before the file op, clear with the state update.
public struct OpJournal {
    public static func run<T>(_ db: Database, op: String, captureId: String,
                              src: String?, dst: String?,
                              fileOp: () throws -> T,
                              stateUpdate: @escaping (GRDB.Database, T) throws -> Void) throws -> T {
        let journalId: Int64 = try db.queue.write { d in
            try d.execute(sql: "INSERT INTO op_journal (op, captureId, src, dst, startedAt) VALUES (?,?,?,?,?)",
                          arguments: [op, captureId, src, dst, Date()])
            return d.lastInsertedRowID
        }
        let result = try fileOp()
        try db.queue.write { d in
            try stateUpdate(d, result)
            try d.execute(sql: "DELETE FROM op_journal WHERE id = ?", arguments: [journalId])
        }
        return result
    }
}
