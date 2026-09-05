import Foundation
import GRDB

/// A finished piece of timed media sitting in a temp file, ready to be stored: what the
/// recorder hands back from `stop()` and what the GIF exporter hands back from `export()`.
public struct MediaResult: Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let duration: Double

    public init(url: URL, width: Int, height: Int, duration: Double) {
        self.url = url; self.width = width; self.height = height; self.duration = duration
    }
}

/// The library: visible files under the root (truth), DB index in App Support (derived).
/// @unchecked Sendable: all mutable state lives in the thread-safe DatabaseQueue; `db` and
/// `root` are immutable, and file operations are serialized through the op journal.
public final class Library: @unchecked Sendable {
    public let db: Database
    public let root: URL

    public init(db: Database, root: URL? = nil) throws {
        self.db = db
        self.root = root ?? Settings.shared.libraryRoot
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try recoverPendingOperations()
        cleanOrphanedStages()
    }

    // DateFormatter creation is expensive; formatting through a shared instance is thread-safe.
    private static let shardFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM"
        return f
    }()
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// YYYY/MM shard directory for a date, created on demand.
    public func shardDir(for date: Date = Date()) throws -> URL {
        let dir = root.appendingPathComponent(Library.shardFormatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Date parts a filename template can name; anything else after `%` stays literal.
    private static let templateTokens: [Character: String] = [
        "Y": "yyyy", "m": "MM", "d": "dd", "H": "HH", "M": "mm", "S": "ss",
    ]

    /// Expand `Settings.filenameTemplate` for one capture: `%Y %m %d %H %M %S` are the capture's
    /// date parts, `%n` is the kind word ("capture"/"recording"), `%%` is a literal percent. The
    /// result is the base name only — `uniqueURL` still de-duplicates and adds the extension.
    public static func templatedName(kind: String, at date: Date = Date(),
                                     template: String? = nil) -> String {
        let chars = Array(template ?? Settings.shared.filenameTemplate)
        // a local formatter: this runs on the capture's background task, and DateFormatter's
        // dateFormat can't be swapped on a shared instance from more than one thread
        let f = DateFormatter()
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 1 < chars.count {
                let token = chars[i + 1]
                if token == "n" { out += kind; i += 2; continue }
                if token == "%" { out += "%"; i += 2; continue }
                if let format = templateTokens[token] {
                    f.dateFormat = format
                    out += f.string(from: date)
                    i += 2
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        // the template is free-form user text: a "/" would fork a directory and ":" reads as a
        // path separator in Finder, so neither can reach a file name
        out = out.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return "\(kind) \(timestampFormatter.string(from: date))" }
        return out
    }

    /// First non-colliding "base.ext" in `dir`, then "base-2.ext", "base-3.ext", …
    public static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: Sidecar.url(for: url).path) {
            url = dir.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    /// Path of `url` relative to the library root — the one place that owns this string surgery.
    func rel(_ url: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    /// Absolute URL for a capture's file — `rel(_:)` run backwards.
    public func url(for record: CaptureRecord) -> URL {
        root.appendingPathComponent(record.relPath)
    }

    public static func fastID(of url: URL) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs[.systemFileNumber] as? Int) ?? 0
        return "\(size):\(Int(mtime * 1000)):\(inode)"
    }

    /// On-disk size in bytes; 0 when the file is unreachable.
    public static func byteSize(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    }

    /// Scratch URL for work-in-progress media: `<tmp>/prefix-<ULID>.ext`. Every producer of a
    /// temp artifact (recorder, GIF exporter, trimmer, clipboard pin) names files the same way,
    /// so a stray temp file is always traceable back to the stage that wrote it.
    public static func tempURL(prefix: String, ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(ULID.generate())")
            .appendingPathExtension(ext)
    }

    /// Store a finished movie/GIF described by a `MediaResult`.
    public func storeMovie(_ result: MediaResult, sourceApp: String?, ext: String = "mp4",
                           kind: CaptureKind = .recording) throws -> (CaptureRecord, URL) {
        try storeMovie(from: result.url, width: result.width, height: result.height,
                       duration: result.duration, sourceApp: sourceApp, ext: ext, kind: kind)
    }

    /// Store a finished recording: journaled move from its temp location into the shard,
    /// minimal sidecar, DB row (staged). Same durability contract as storePNG.
    public func storeMovie(from tempURL: URL, width: Int, height: Int, duration: Double,
                           sourceApp: String?, ext: String = "mp4",
                           kind: CaptureKind = .recording) throws -> (CaptureRecord, URL) {
        try withOperation {
            let now = Date()
            let target = Library.uniqueURL(in: try shardDir(for: now),
                base: Library.templatedName(kind: "recording", at: now), ext: ext)
            var record = CaptureRecord(kind: kind, createdAt: now, width: width, height: height,
                bytes: Library.byteSize(of: tempURL), relPath: rel(target), sourceApp: sourceApp, fastID: "")
            record.durationS = duration
            let staged = try stageFile(tempURL)
            defer { removeUnjournaledStage(staged) }
            let plan = FileOperation(op: "write", source: rel(staged), record: record,
                sidecar: Sidecar(id: record.id, created: now, app: sourceApp, window: nil))
            try commit(plan)
            try? removeIfPresent(tempURL)
            record.fastID = Library.fastID(of: target)
            return (record, target)
        }
    }

    public func storePNG(_ data: Data, width: Int, height: Int,
                         sourceApp: String?, windowTitle: String?, screenID: Int?) throws -> (CaptureRecord, URL) {
        try withOperation {
            let now = Date()
            let target = Library.uniqueURL(in: try shardDir(for: now),
                base: Library.templatedName(kind: "capture", at: now), ext: "png")
            var record = CaptureRecord(kind: .screenshot, createdAt: now, width: width, height: height,
                bytes: data.count, relPath: rel(target), sourceApp: sourceApp, windowTitle: windowTitle,
                screenID: screenID, fastID: "")
            let staged = try stageData(data)
            defer { removeUnjournaledStage(staged) }
            try commit(FileOperation(op: "write", source: rel(staged), record: record,
                sidecar: Sidecar(id: record.id, created: now, app: sourceApp, window: windowTitle)))
            record.fastID = Library.fastID(of: target)
            return (record, target)
        }
    }

    public func setStatus(_ id: String, _ status: CaptureStatus) throws {
        try withOperation(for: id) {
            try db.queue.write { d in
                try d.execute(sql: "UPDATE captures SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
            }
        }
    }

    /// Copy a capture into the export folder under a non-colliding name. Both the overlay's
    /// Save and the After Capture list want exactly this; they had a copy each.
    @discardableResult
    public static func copyToExportLocation(_ url: URL) throws -> URL {
        let destination = uniqueURL(in: Settings.shared.exportLocation,
                                    base: url.deletingPathExtension().lastPathComponent,
                                    ext: url.pathExtension)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Upload completion must name the revision represented by the uploaded snapshot.
    /// A stale link is retained for revocation, but must never be reused as the current share.
    @discardableResult
    public func setShareLink(_ id: String, url: String?, revision: Int64? = nil) throws -> Bool {
        try withOperation(for: id) {
            try db.queue.write { d in
                guard let record = try CaptureRecord.fetchOne(d, key: id) else { return false }
                let current = url == nil || record.contentRevision == revision
                try d.execute(sql: "UPDATE captures SET shareURL = ?, shareStale = ? WHERE id = ?",
                              arguments: [url, !current, id])
                return current
            }
        }
    }

    /// Hard-link on the library filesystem while locked: an atomic replacement keeps the old
    /// inode alive without copying a movie from an external disk while blocking capture actions.
    public func shareSnapshot(_ id: String) throws -> (record: CaptureRecord, file: URL) {
        try shareSnapshot(id, linking: FileManager.default.linkItem)
    }

    func shareSnapshot(_ id: String, linking: (URL, URL) throws -> Void) throws -> (record: CaptureRecord, file: URL) {
        let snapshot = try withOperation(for: id) { () -> (CaptureRecord, URL, FileHandle?) in
            guard let record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }),
                  record.status != .trashed, record.status != .sweeping else { throw CocoaError(.fileNoSuchFile) }
            let source = url(for: record)
            let file = try stagingURL(ext: source.pathExtension)
            do {
                try linking(source, file)
                return (record, file, nil)
            } catch {
                try? removeIfPresent(file)
                // Some removable filesystems do not support hard links. Pin the open file
                // descriptor under the lock, then stream its bytes after releasing the lock.
                let handle = try FileHandle(forReadingFrom: source)
                return (record, Library.tempURL(prefix: "kapture-share", ext: source.pathExtension), handle)
            }
        }
        let (record, file, input) = snapshot
        if let input {
            defer { try? input.close() }
            do {
                guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: file)
                defer { try? output.close() }
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { try output.write(contentsOf: data) }
            } catch { try? removeIfPresent(file); throw error }
        }
        return (record, file)
    }

    /// Reuse the sidecar's original across renames. Never infer absence from a read failure.
    func originalPath(for record: CaptureRecord) throws -> String {
        try Sidecar.readIfPresent(for: url(for: record))?.annotations?.original
            ?? ".originals/\(record.id).\(url(for: record).pathExtension)"
    }

    public func applyTrim(_ id: String, trimmedURL: URL, duration: Double) throws {
        try withOperation(for: id) {
            guard var record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }),
                  record.status != .sweeping else { return }
            let staged = try stageFile(trimmedURL)
            defer { removeUnjournaledStage(staged) }
            record.bytes = Library.byteSize(of: staged)
            record.durationS = duration
            try replaceContent(record, staged: staged, layersJSON: "[]", op: "trim")
            try? removeIfPresent(trimmedURL)
        }
    }

    public func applyEdit(_ id: String, flattenedPNG: Data, layersJSON: String,
                          width: Int, height: Int) throws {
        try withOperation(for: id) {
            guard var record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }),
                  record.status != .sweeping else { return }
            let staged = try stageData(flattenedPNG)
            defer { removeUnjournaledStage(staged) }
            record.bytes = flattenedPNG.count
            record.width = width; record.height = height
            try replaceContent(record, staged: staged, layersJSON: layersJSON, op: "flatten")
        }
    }

    private func replaceContent(_ current: CaptureRecord, staged: URL, layersJSON: String, op: String) throws {
        var record = current
        var sidecar = try Sidecar.readIfPresent(for: url(for: record))
            ?? Sidecar(id: record.id, created: record.createdAt, app: record.sourceApp, window: record.windowTitle)
        sidecar.annotations = .init(original: try originalPath(for: record), layersJSON: layersJSON)
        record.contentRevision += 1
        record.contentHash = nil
        record.shareStale = record.shareURL != nil
        record.summary = nil
        record.aiState = .none
        try commit(FileOperation(op: op, source: rel(staged), record: record, sidecar: sidecar))
    }

    /// The image the editor should open: pristine original if one exists, else the file itself.
    public func editBase(for record: CaptureRecord) -> (image: URL, layersJSON: String?) {
        let fileURL = url(for: record)
        guard let ann = Sidecar.read(for: fileURL)?.annotations else { return (fileURL, nil) }
        let orig = root.appendingPathComponent(ann.original)
        return (FileManager.default.fileExists(atPath: orig.path) ? orig : fileURL, ann.layersJSON)
    }

    // MARK: - Trash (spec §2.2 F7)

    struct Tombstone: Codable {
        var id: String
        var originalRelPath: String
        var trashedAt: Date
    }

    public var trashDir: URL { root.appendingPathComponent(".trash", isDirectory: true) }

    func tombstoneURL(_ id: String) -> URL {
        trashDir.appendingPathComponent("\(id).tombstone.json")
    }

    public func discard(_ requested: CaptureRecord) throws {
        try withOperation(for: requested.id) {
            guard var record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: requested.id) }),
                  record.status != .trashed, record.status != .sweeping else { return }
            let source = record.relPath
            let file = url(for: record)
            let shard = trashDir.appendingPathComponent((source as NSString).deletingLastPathComponent)
            try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
            let target = Library.uniqueURL(in: shard, base: file.deletingPathExtension().lastPathComponent,
                                          ext: file.pathExtension)
            record.status = .trashed; record.trashedAt = Date(); record.relPath = rel(target)
            try commit(FileOperation(op: "discard", source: source, record: record,
                sidecar: nil, originalRelPath: source))
        }
    }

    /// Restore the most recently discarded capture — the menu bar's "Restore Last Discarded".
    @discardableResult
    public func restoreLastDiscarded() throws -> CaptureRecord? {
        guard let id = try db.queue.read({ d in
            try String.fetchOne(d, sql: """
                SELECT id FROM captures WHERE status = 'trashed' ORDER BY trashedAt DESC LIMIT 1
                """)
        }) else { return nil }
        return try restore(id: id)
    }

    /// Restore and sweeping use the same operation lock, so no optimistic status flip is needed.
    @discardableResult
    public func restore(id: String) throws -> CaptureRecord? {
        try withOperation(for: id) {
            guard var record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }),
                  record.status == .trashed else { return nil }
            let source = record.relPath
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let original = (try? dec.decode(Tombstone.self, from: Data(contentsOf: tombstoneURL(id))))?
                .originalRelPath ?? String(source.dropFirst(".trash/".count))
            let desired = root.appendingPathComponent(original)
            try FileManager.default.createDirectory(at: desired.deletingLastPathComponent(), withIntermediateDirectories: true)
            let target = Library.uniqueURL(in: desired.deletingLastPathComponent(),
                base: desired.deletingPathExtension().lastPathComponent, ext: desired.pathExtension)
            record.status = .kept; record.trashedAt = nil; record.relPath = rel(target)
            try commit(FileOperation(op: "restore", source: source, record: record, sidecar: nil))
            return try db.queue.read { try CaptureRecord.fetchOne($0, key: id) }
        }
    }

    /// Retry interrupted sweeps and retain the row/sidecar until every referenced file is gone.
    public func sweepTrash(olderThanDays days: Int = 7) {
        sweepTrash(olderThanDays: days, removing: removeIfPresent)
    }

    func sweepTrash(olderThanDays days: Int, removing remove: (URL) throws -> Void) {
        db.operationLock.lock(); defer { db.operationLock.unlock() }
        do {
            try recoverPendingOperations()
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            let expired = try db.queue.read { d in
                try CaptureRecord.fetchAll(d, sql: """
                    SELECT * FROM captures WHERE (status = 'sweeping'
                        OR (status = 'trashed' AND trashedAt < ?))
                        AND NOT EXISTS (SELECT 1 FROM op_journal WHERE captureId = captures.id AND recoveryError IS NOT NULL)
                    """, arguments: [cutoff])
            }
            for record in expired {
                do {
                    try db.queue.write { d in
                        try d.execute(sql: "UPDATE captures SET status = 'sweeping' WHERE id = ?", arguments: [record.id])
                    }
                    let file = url(for: record)
                    if let original = try Sidecar.readIfPresent(for: file)?.annotations?.original,
                       try canDeleteOriginal(original, ownedBy: record.id) {
                        try remove(try checkedOriginalURL(original))
                    }
                    try remove(file)
                    try remove(Sidecar.url(for: file))
                    try remove(tombstoneURL(record.id))
                    try db.queue.write { d in
                        try d.execute(sql: "DELETE FROM ingest_jobs WHERE captureId = ?", arguments: [record.id])
                        try d.execute(sql: "DELETE FROM captures WHERE id = ?", arguments: [record.id])
                    }
                } catch { Log.store.error("trash cleanup will retry \(record.id): \(error)") }
            }
        } catch { Log.store.error("trash cleanup deferred: \(error)") }
    }
    /// Legacy originals are named by a reusable visible path, not capture identity. Preserve
    /// the file while another capture or unfinished plan references it. Unknown metadata also
    /// keeps it: losing a little disk space is preferable to deleting someone else's original.
    private func canDeleteOriginal(_ original: String, ownedBy id: String) throws -> Bool {
        let target = try checkedOriginalURL(original)
        let others = try db.queue.read { try CaptureRecord.fetchAll($0, sql: "SELECT * FROM captures WHERE id != ?", arguments: [id]) }
        for other in others {
            do {
                if let path = try Sidecar.readIfPresent(for: url(for: other))?.annotations?.original,
                   try checkedOriginalURL(path) == target { return false }
            } catch { return false }
        }
        let plans = try db.queue.read { try Row.fetchAll($0, sql: "SELECT plan FROM op_journal WHERE captureId != ?", arguments: [id]) }
        for row in plans {
            guard let data: Data = row["plan"], let plan = try? JSONDecoder().decode(FileOperation.self, from: data) else { return false }
            if let path = plan.sidecar?.annotations?.original, try checkedOriginalURL(path) == target { return false }
            // A failed move may have put the sidecar at its destination before the DB row
            // changed. New move plans preserve raw bytes instead of embedding decoded metadata.
            for path in Set([plan.source, plan.record.relPath]) {
                do {
                    if let reference = try Sidecar.readIfPresent(for: root.appendingPathComponent(path))?.annotations?.original,
                       try checkedOriginalURL(reference) == target { return false }
                } catch { return false }
            }
        }
        return true
    }

}
