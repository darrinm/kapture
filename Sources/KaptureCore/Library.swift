import Foundation
import GRDB

/// The library: visible files under the root (truth), DB index in App Support (derived).
public final class Library {
    public let db: Database
    public let root: URL

    public init(db: Database, root: URL? = nil) throws {
        self.db = db
        self.root = root ?? Settings.shared.libraryRoot
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    /// YYYY/MM shard directory for a date, created on demand.
    public func shardDir(for date: Date = Date()) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM"
        let dir = root.appendingPathComponent(f.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func timestampName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "capture \(f.string(from: date))"
    }

    public static func fastID(of url: URL) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs[.systemFileNumber] as? Int) ?? 0
        return "\(size):\(Int(mtime * 1000)):\(inode)"
    }

    /// Store PNG data: journal → write file + sidecar → DB insert (staged). Returns the record + URL.
    public func storePNG(_ data: Data, width: Int, height: Int,
                         sourceApp: String?, windowTitle: String?, screenID: Int?) throws -> (CaptureRecord, URL) {
        let now = Date()
        let dir = try shardDir(for: now)
        var url = dir.appendingPathComponent(Library.timestampName(now)).appendingPathExtension("png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(Library.timestampName(now) + "-\(n)").appendingPathExtension("png")
            n += 1
        }
        let id = ULID.generate(now: now)
        let relPath = url.path.replacingOccurrences(of: root.path + "/", with: "")

        let record: CaptureRecord = try OpJournal.run(
            db, op: "write", captureId: id, src: nil, dst: relPath,
            fileOp: {
                try data.write(to: url, options: .atomic)
                try Sidecar(id: id, created: now, app: sourceApp, window: windowTitle).write(next: url)
                return CaptureRecord(id: id, kind: .screenshot, createdAt: now,
                                     width: width, height: height, bytes: data.count, relPath: relPath,
                                     sourceApp: sourceApp, windowTitle: windowTitle, screenID: screenID,
                                     fastID: Library.fastID(of: url))
            },
            stateUpdate: { d, record in try record.insert(d) })
        Log.store.info("stored \(relPath, privacy: .public) (\(data.count) bytes)")
        return (record, url)
    }

    public func setStatus(_ id: String, _ status: CaptureStatus) throws {
        try db.queue.write { d in
            try d.execute(sql: "UPDATE captures SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
    }

    // MARK: - Trash (spec §2.2 F7)

    struct Tombstone: Codable {
        var id: String
        var originalRelPath: String
        var trashedAt: Date
    }

    public var trashDir: URL { root.appendingPathComponent(".trash", isDirectory: true) }

    private func tombstoneURL(_ id: String) -> URL {
        trashDir.appendingPathComponent("\(id).tombstone.json")
    }

    /// Discard: journal → move file (+sidecar) into .trash/ + write tombstone → status=trashed.
    public func discard(_ record: CaptureRecord) throws {
        let fm = FileManager.default
        let src = root.appendingPathComponent(record.relPath)
        let trashShard = trashDir.appendingPathComponent((record.relPath as NSString).deletingLastPathComponent,
                                                         isDirectory: true)
        try fm.createDirectory(at: trashShard, withIntermediateDirectories: true)
        var dst = trashShard.appendingPathComponent(src.lastPathComponent)
        if fm.fileExists(atPath: dst.path) {
            dst = trashShard.appendingPathComponent("\(record.id)-\(src.lastPathComponent)")
        }
        let trashRel = dst.path.replacingOccurrences(of: root.path + "/", with: "")

        _ = try OpJournal.run(db, op: "discard", captureId: record.id, src: record.relPath, dst: trashRel,
            fileOp: {
                try fm.moveItem(at: src, to: dst)
                let sidecar = Sidecar.url(for: src)
                if fm.fileExists(atPath: sidecar.path) {
                    try? fm.moveItem(at: sidecar, to: Sidecar.url(for: dst))
                }
                let tomb = Tombstone(id: record.id, originalRelPath: record.relPath, trashedAt: Date())
                let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
                try enc.encode(tomb).write(to: self.tombstoneURL(record.id), options: .atomic)
            },
            stateUpdate: { d, _ in
                try d.execute(sql: "UPDATE captures SET status = 'trashed', trashedAt = ?, relPath = ? WHERE id = ?",
                              arguments: [Date(), trashRel, record.id])
            })
        Log.store.info("discarded \(record.relPath, privacy: .public)")
    }

    /// Restore the most recently discarded capture. Status flips first (fails if sweeping),
    /// then the file moves back; returns the restored record.
    @discardableResult
    public func restoreLastDiscarded() throws -> CaptureRecord? {
        guard let record = try db.queue.read({ d in
            try CaptureRecord.fetchOne(d, sql: "SELECT * FROM captures WHERE status = 'trashed' ORDER BY trashedAt DESC LIMIT 1")
        }) else { return nil }

        let fm = FileManager.default
        let tombURL = tombstoneURL(record.id)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let originalRel = (try? dec.decode(Tombstone.self, from: Data(contentsOf: tombURL)))?.originalRelPath
            ?? record.relPath.replacingOccurrences(of: ".trash/", with: "")

        // flip status first inside the queue — a sweeping row refuses restore
        let flipped = try db.queue.write { d -> Bool in
            let status = try String.fetchOne(d, sql: "SELECT status FROM captures WHERE id = ?", arguments: [record.id])
            guard status == "trashed" else { return false }
            try d.execute(sql: "UPDATE captures SET status = 'kept', trashedAt = NULL WHERE id = ?", arguments: [record.id])
            return true
        }
        guard flipped else { return nil }

        var dst = root.appendingPathComponent(originalRel)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) {
            let base = dst.deletingPathExtension().lastPathComponent
            dst = dst.deletingLastPathComponent().appendingPathComponent("\(base)-restored.png")
        }
        let src = root.appendingPathComponent(record.relPath)
        _ = try OpJournal.run(db, op: "restore", captureId: record.id, src: record.relPath,
                              dst: dst.path.replacingOccurrences(of: root.path + "/", with: ""),
            fileOp: {
                try fm.moveItem(at: src, to: dst)
                let sidecar = Sidecar.url(for: src)
                if fm.fileExists(atPath: sidecar.path) { try? fm.moveItem(at: sidecar, to: Sidecar.url(for: dst)) }
                try? fm.removeItem(at: tombURL)
            },
            stateUpdate: { d, _ in
                try d.execute(sql: "UPDATE captures SET relPath = ? WHERE id = ?",
                              arguments: [dst.path.replacingOccurrences(of: self.root.path + "/", with: ""), record.id])
            })
        Log.store.info("restored \(originalRel, privacy: .public)")
        return try db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) }
    }

    /// Hard-delete trashed captures older than `days`. Per item: mark sweeping (aborts unless
    /// still trashed and expired) → unlink → delete row. Never touches share links.
    public func sweepTrash(olderThanDays days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let fm = FileManager.default
        let expired = (try? db.queue.read { d in
            try CaptureRecord.fetchAll(d, sql: "SELECT * FROM captures WHERE status = 'trashed' AND trashedAt < ?",
                                       arguments: [cutoff])
        }) ?? []
        for record in expired {
            let marked = (try? db.queue.write { d -> Bool in
                let status = try String.fetchOne(d, sql: "SELECT status FROM captures WHERE id = ?", arguments: [record.id])
                guard status == "trashed" else { return false }
                try d.execute(sql: "UPDATE captures SET status = 'sweeping' WHERE id = ?", arguments: [record.id])
                return true
            }) ?? false
            guard marked else { continue }
            let file = root.appendingPathComponent(record.relPath)
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: Sidecar.url(for: file))
            try? fm.removeItem(at: tombstoneURL(record.id))
            try? db.queue.write { d in
                try d.execute(sql: "DELETE FROM captures WHERE id = ?", arguments: [record.id])
            }
        }
        if !expired.isEmpty { Log.store.info("swept \(expired.count) trashed captures") }
    }
}
