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
}
