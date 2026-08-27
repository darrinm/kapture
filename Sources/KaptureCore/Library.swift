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
        while FileManager.default.fileExists(atPath: url.path) {
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
        let now = Date()
        let dir = try shardDir(for: now)
        let url = Library.uniqueURL(in: dir, base: Library.templatedName(kind: "recording", at: now),
                                    ext: ext)
        let id = ULID.generate(now: now)
        let relPath = rel(url)
        let bytes = Library.byteSize(of: tempURL)

        let record: CaptureRecord = try OpJournal.run(
            db, op: "write", captureId: id, src: nil, dst: relPath,
            fileOp: {
                try FileManager.default.moveItem(at: tempURL, to: url)
                try Sidecar(id: id, created: now, app: sourceApp, window: nil).write(next: url)
                var r = CaptureRecord(id: id, kind: kind, createdAt: now,
                                      width: width, height: height, bytes: bytes, relPath: relPath,
                                      sourceApp: sourceApp, windowTitle: nil, screenID: nil,
                                      fastID: Library.fastID(of: url))
                r.durationS = duration
                return r
            },
            stateUpdate: { d, record in
                try record.insert(d)
                try Library.indexText(d, id: record.id, name: (record.relPath as NSString).lastPathComponent)
            })
        Log.store.info("stored \(relPath, privacy: .public) (\(Int(duration))s recording)")
        return (record, url)
    }

    /// Store PNG data: journal → write file + sidecar → DB insert (staged). Returns the record + URL.
    public func storePNG(_ data: Data, width: Int, height: Int,
                         sourceApp: String?, windowTitle: String?, screenID: Int?) throws -> (CaptureRecord, URL) {
        let now = Date()
        let dir = try shardDir(for: now)
        let url = Library.uniqueURL(in: dir, base: Library.templatedName(kind: "capture", at: now),
                                    ext: "png")
        let id = ULID.generate(now: now)
        let relPath = rel(url)

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
            stateUpdate: { d, record in
                try record.insert(d)
                try Library.indexText(d, id: record.id, name: (record.relPath as NSString).lastPathComponent)
            })
        Log.store.info("stored \(relPath, privacy: .public) (\(data.count) bytes)")
        return (record, url)
    }

    public func setStatus(_ id: String, _ status: CaptureStatus) throws {
        try db.queue.write { d in
            try d.execute(sql: "UPDATE captures SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
    }

    /// Record (or clear) the kapture.sh link for a capture. Setting a link also clears the stale
    /// flag: a fresh upload is by definition the current pixels, whatever edits preceded it.
    public func setShareLink(_ id: String, url: String?) throws {
        try db.queue.write { d in
            try d.execute(sql: "UPDATE captures SET shareURL = ?, shareStale = 0 WHERE id = ?",
                          arguments: [url, id])
        }
        Log.store.info("share link \(url == nil ? "cleared" : "set", privacy: .public) for \(id, privacy: .public)")
    }

    /// Copy the pristine pixels aside into .originals/ if that hasn't happened yet, and return
    /// the copy's library-relative path. Idempotent: only the first destructive edit copies,
    /// every later one finds the original already there and leaves it untouched.
    private func preserveOriginal(_ relPath: String) throws -> String {
        let fm = FileManager.default
        let originalRel = ".originals/" + relPath
        let originalURL = root.appendingPathComponent(originalRel)
        if !fm.fileExists(atPath: originalURL.path) {
            try fm.createDirectory(at: originalURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.copyItem(at: root.appendingPathComponent(relPath), to: originalURL)
        }
        return originalRel
    }

    /// Apply a trim to a recording: first trim preserves the pristine movie in .originals/,
    /// the trimmed file replaces rel_path, identity/duration refresh, shares go stale.
    public func applyTrim(_ id: String, trimmedURL: URL, duration: Double) throws {
        guard let record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }) else { return }
        let fm = FileManager.default
        let fileURL = url(for: record)
        let trimmedBytes = Library.byteSize(of: trimmedURL)
        let bytes = trimmedBytes > 0 ? trimmedBytes : record.bytes

        _ = try OpJournal.run(db, op: "trim", captureId: id, src: record.relPath, dst: record.relPath,
            fileOp: {
                let originalRel = try self.preserveOriginal(record.relPath)
                _ = try fm.replaceItemAt(fileURL, withItemAt: trimmedURL)
                // the sidecar points at the pristine movie the same way an edited image's does,
                // so editBase() can reach a trimmed recording's original too
                var sidecar = Sidecar.read(for: fileURL)
                    ?? Sidecar(id: id, created: record.createdAt, app: record.sourceApp, window: record.windowTitle)
                sidecar.annotations = .init(original: originalRel, layersJSON: "[]")
                try sidecar.write(next: fileURL)
            },
            stateUpdate: { d, _ in
                try d.execute(sql: """
                    UPDATE captures SET bytes = ?, durationS = ?, fastID = ?, contentHash = NULL,
                        shareStale = (shareURL IS NOT NULL) WHERE id = ?
                    """, arguments: [bytes, duration, Library.fastID(of: fileURL), id])
            })
        Log.store.info("trimmed \(record.relPath, privacy: .public) to \(Int(duration))s")
    }

    // MARK: - Edits (spec §2.3: originals + flatten)

    /// First edit moves the pristine pixels to .originals/; every flatten rewrites rel_path,
    /// updates identity, marks any share stale, and records the layer stack in the sidecar.
    public func applyEdit(_ id: String, flattenedPNG: Data, layersJSON: String,
                          width: Int, height: Int) throws {
        guard let record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }) else { return }
        let fileURL = url(for: record)

        _ = try OpJournal.run(db, op: "flatten", captureId: id, src: record.relPath, dst: record.relPath,
            fileOp: {
                let originalRel = try self.preserveOriginal(record.relPath)
                try flattenedPNG.write(to: fileURL, options: .atomic)
                var sidecar = Sidecar.read(for: fileURL)
                    ?? Sidecar(id: id, created: record.createdAt, app: record.sourceApp, window: record.windowTitle)
                sidecar.annotations = .init(original: originalRel, layersJSON: layersJSON)
                try sidecar.write(next: fileURL)
            },
            stateUpdate: { d, _ in
                try d.execute(sql: """
                    UPDATE captures SET bytes = ?, width = ?, height = ?, fastID = ?, contentHash = NULL,
                        shareStale = (shareURL IS NOT NULL) WHERE id = ?
                    """, arguments: [flattenedPNG.count, width, height,
                                     Library.fastID(of: fileURL), id])
            })
        Log.store.info("flattened edit onto \(record.relPath, privacy: .public)")
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

    private func tombstoneURL(_ id: String) -> URL {
        trashDir.appendingPathComponent("\(id).tombstone.json")
    }

    /// Move a capture file together with its sidecar (when one exists).
    func moveWithSidecar(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.moveItem(at: src, to: dst)
        let sidecar = Sidecar.url(for: src)
        if fm.fileExists(atPath: sidecar.path) {
            try? fm.moveItem(at: sidecar, to: Sidecar.url(for: dst))
        }
    }

    /// Discard: journal → move file (+sidecar) into .trash/ + write tombstone → status=trashed.
    public func discard(_ record: CaptureRecord) throws {
        let fm = FileManager.default
        let src = url(for: record)
        let trashShard = trashDir.appendingPathComponent((record.relPath as NSString).deletingLastPathComponent,
                                                         isDirectory: true)
        try fm.createDirectory(at: trashShard, withIntermediateDirectories: true)
        var dst = trashShard.appendingPathComponent(src.lastPathComponent)
        if fm.fileExists(atPath: dst.path) {
            dst = trashShard.appendingPathComponent("\(record.id)-\(src.lastPathComponent)")
        }
        let trashRel = rel(dst)

        _ = try OpJournal.run(db, op: "discard", captureId: record.id, src: record.relPath, dst: trashRel,
            fileOp: {
                try self.moveWithSidecar(from: src, to: dst)
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

    /// Restore one specific trashed capture. Status flips first (a sweeping row refuses), then
    /// the file moves back under the journal; returns the restored record, or nil when the id
    /// isn't a trashed capture any more.
    @discardableResult
    public func restore(id: String) throws -> CaptureRecord? {
        guard let record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }),
              record.status == .trashed else { return nil }

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
        let src = url(for: record)
        let dstRel = rel(dst)
        do {
            _ = try OpJournal.run(db, op: "restore", captureId: record.id, src: record.relPath, dst: dstRel,
                fileOp: {
                    try self.moveWithSidecar(from: src, to: dst)
                    try? fm.removeItem(at: tombURL)
                },
                stateUpdate: { d, _ in
                    try d.execute(sql: "UPDATE captures SET relPath = ? WHERE id = ?",
                                  arguments: [dstRel, record.id])
                })
        } catch {
            // the file never moved — revert the optimistic status flip so the capture stays
            // trashed (restorable and sweepable) instead of 'kept' with a .trash/ relPath
            try? db.queue.write { d in
                try d.execute(sql: "UPDATE captures SET status = 'trashed', trashedAt = ? WHERE id = ?",
                              arguments: [record.trashedAt ?? Date(), record.id])
            }
            throw error
        }
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
            let file = url(for: record)
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
