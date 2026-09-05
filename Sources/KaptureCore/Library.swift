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

/// Thrown by `Library(exclusive:)` when another process already holds the root.
public struct LibraryBusy: LocalizedError {
    public let root: URL
    public var errorDescription: String? {
        "The library at \(root.path) is open in another Kapture process"
    }
}

/// The library: visible files under the root (truth), DB index in App Support (derived).
/// @unchecked Sendable: all mutable state lives in the thread-safe DatabaseQueue; `db` and
/// `root` are immutable; file operations are serialized by `db.operationLock` through
/// `withOperation`, and made durable by the op journal.
public final class Library: @unchecked Sendable {
    public let db: Database
    public let root: URL
    /// Held for the life of the instance when opened `exclusive`; closing it releases the lock.
    private let exclusiveLock: FileHandle?
    /// Whether this process may assume it is the root's only writer. False for a test's second
    /// instance on a shared root, and for a volume whose `flock` cannot answer.
    var holdsRootLock: Bool { exclusiveLock != nil }

    /// `exclusive` makes this process the root's only writer: a `flock` on `<root>/.lock`,
    /// refused if another process holds it. The operation lock is per process and the startup
    /// sweep of `.pending` assumes nobody else is mid-upload, so the app and its command-line
    /// harnesses must never share a root at once. Tests open a second instance on a root
    /// while the first is alive, and leave it off.
    public init(db: Database, root: URL? = nil, exclusive: Bool = false) throws {
        self.db = db
        self.root = root ?? Settings.shared.libraryRoot
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        exclusiveLock = exclusive ? try Library.lock(self.root) : nil
        try recoverPendingOperations()
        cleanOrphanedStages()
    }

    /// nil when the filesystem cannot lock at all. The lock is a safety net for a root two
    /// processes might share, not a reason a root that works for everything else should fail.
    private static func lock(_ root: URL) throws -> FileHandle? {
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            Log.store.error("library lock unavailable (open failed, errno \(errno)); running without it")
            return nil
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let reason = errno
            close(fd)
            // Only "someone else holds it" is a refusal. ENOTSUP and its relatives mean the
            // volume cannot answer the question, which is not the same as answering "busy".
            guard reason == EWOULDBLOCK else {
                Log.store.error("library lock unavailable (flock failed, errno \(reason)); running without it")
                return nil
            }
            throw LibraryBusy(root: root)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
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
    /// result is the base name only — `availableURL` still de-duplicates and adds the extension.
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

    /// First non-colliding "base.ext" in `dir`, then "base-2.ext", "base-3.ext", … — as far
    /// as the filesystem knows, which is all an export location has. The library's own names
    /// go through `availableURL`.
    public static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        uniqueURL(in: dir, base: base, ext: ext) { url in
            FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: Sidecar.url(for: url).path)
        }
    }

    /// The one naming loop: the first candidate `taken` does not refuse.
    static func uniqueURL(in dir: URL, base: String, ext: String,
                          taken: (URL) throws -> Bool) rethrows -> URL {
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while try taken(url) {
            url = dir.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    /// `uniqueURL` for the library's own files. A name is also taken when a row still holds it
    /// — a file deleted in Finder leaves its row behind — or when a journaled plan is on its
    /// way there; either would trip the UNIQUE relPath or a moveItem collision at commit, after
    /// the file had already moved. Presence is asked with `itemExists`, so a file we may not
    /// read counts as there.
    func availableURL(in dir: URL, base: String, ext: String) throws -> URL {
        try Library.uniqueURL(in: dir, base: base, ext: ext) { url in
            try itemExists(url) || itemExists(Sidecar.url(for: url)) || db.queue.read { d in
                try Bool.fetchOne(d, sql: """
                    SELECT EXISTS(SELECT 1 FROM captures WHERE relPath = ?)
                        OR EXISTS(SELECT 1 FROM op_journal WHERE dst = ?)
                    """, arguments: [rel(url), rel(url)]) ?? false
            }
        }
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
        // Staging is the slow part — a movie coming off an external volume — and needs no
        // lock: only startup sweeps .pending, and only while holding the root.
        let staged = try stageFile(tempURL)
        defer { removeUnjournaledStage(staged) }
        return try withOperation {
            let now = Date()
            let target = try availableURL(in: try shardDir(for: now),
                base: Library.templatedName(kind: "recording", at: now), ext: ext)
            var record = CaptureRecord(kind: kind, createdAt: now, width: width, height: height,
                bytes: Library.byteSize(of: tempURL), relPath: rel(target), sourceApp: sourceApp, fastID: "")
            record.durationS = duration
            try commit(FileOperation(op: .write, source: rel(staged), record: record, sidecar: Sidecar(for: record)))
            try? removeIfPresent(tempURL)
            record.fastID = Library.fastID(of: target)
            return (record, target)
        }
    }

    public func storePNG(_ data: Data, width: Int, height: Int,
                         sourceApp: String?, windowTitle: String?, screenID: Int?) throws -> (CaptureRecord, URL) {
        let staged = try stageData(data)   // off the lock, as in storeMovie
        defer { removeUnjournaledStage(staged) }
        return try withOperation {
            let now = Date()
            let target = try availableURL(in: try shardDir(for: now),
                base: Library.templatedName(kind: "capture", at: now), ext: "png")
            var record = CaptureRecord(kind: .screenshot, createdAt: now, width: width, height: height,
                bytes: data.count, relPath: rel(target), sourceApp: sourceApp, windowTitle: windowTitle,
                screenID: screenID, fastID: "")
            try commit(FileOperation(op: .write, source: rel(staged), record: record, sidecar: Sidecar(for: record)))
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
                  record.isLive else { throw CocoaError(.fileNoSuchFile) }
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

    /// Where this build keeps a capture's pristine pixels: keyed by its id, so the file can be
    /// nobody else's — unlike a legacy original, keyed by a visible path two captures could
    /// have shared.
    static func ownOriginalPath(id: String, ext: String) -> String {
        ".originals/\(id).\(ext)"
    }

    /// Reuse the sidecar's original across renames. Never infer absence from a read failure.
    func originalPath(for record: CaptureRecord) throws -> String {
        try Sidecar.readIfPresent(for: url(for: record))?.annotations?.original
            ?? Library.ownOriginalPath(id: record.id, ext: url(for: record).pathExtension)
    }

    public func applyTrim(_ id: String, trimmedURL: URL, duration: Double) throws {
        let staged = try stageFile(trimmedURL)   // off the lock, as in storeMovie
        defer { removeUnjournaledStage(staged) }
        try withOperation(for: id) {
            guard var record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }),
                  record.status != .sweeping else { return }
            record.bytes = Library.byteSize(of: staged)
            record.durationS = duration
            try replaceContent(record, staged: staged, layersJSON: "[]", op: .trim)
            try? removeIfPresent(trimmedURL)
        }
    }

    public func applyEdit(_ id: String, flattenedPNG: Data, layersJSON: String,
                          width: Int, height: Int) throws {
        let staged = try stageData(flattenedPNG)   // off the lock, as in storeMovie
        defer { removeUnjournaledStage(staged) }
        try withOperation(for: id) {
            guard var record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }),
                  record.status != .sweeping else { return }
            record.bytes = flattenedPNG.count
            record.width = width; record.height = height
            try replaceContent(record, staged: staged, layersJSON: layersJSON, op: .flatten)
        }
    }

    private func replaceContent(_ current: CaptureRecord, staged: URL, layersJSON: String,
                                op: FileOperation.Op) throws {
        var record = current
        var sidecar = try Sidecar.readIfPresent(for: url(for: record)) ?? Sidecar(for: record)
        sidecar.annotations = .init(original: try originalPath(for: record), layersJSON: layersJSON)
        record.markContentReplaced()
        try commit(FileOperation(op: op, source: rel(staged), record: record, sidecar: sidecar))
    }

    /// The image the editor should open: pristine original if one exists, else the file itself.
    public func editBase(for record: CaptureRecord) -> (image: URL, layersJSON: String?) {
        let fileURL = url(for: record)
        guard let ann = Sidecar.read(for: fileURL)?.annotations else { return (fileURL, nil) }
        // The containment check the sweep and the replayer already enforce: a sidecar pointing
        // outside .originals/ does not get to choose what the editor opens.
        if let orig = try? checkedOriginalURL(ann.original), FileManager.default.fileExists(atPath: orig.path) {
            return (orig, ann.layersJSON)
        }
        return (fileURL, ann.layersJSON)
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
                  record.isLive else { return }
            let source = record.relPath
            let file = url(for: record)
            let shard = trashDir.appendingPathComponent((source as NSString).deletingLastPathComponent)
            try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
            let target = try availableURL(in: shard, base: file.deletingPathExtension().lastPathComponent,
                                          ext: file.pathExtension)
            record.status = .trashed; record.trashedAt = Date(); record.relPath = rel(target)
            try commit(FileOperation(op: .discard, source: source, record: record,
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
            let target = try availableURL(in: desired.deletingLastPathComponent(),
                base: desired.deletingPathExtension().lastPathComponent, ext: desired.pathExtension)
            record.status = .kept; record.trashedAt = nil; record.relPath = rel(target)
            try commit(FileOperation(op: .restore, source: source, record: record, sidecar: nil))
            return try db.queue.read { try CaptureRecord.fetchOne($0, key: id) }
        }
    }

    /// Retry interrupted sweeps and retain the row/sidecar until every referenced file is gone.
    public func sweepTrash(olderThanDays days: Int = 7) {
        sweepTrash(olderThanDays: days, removing: removeIfPresent)
    }

    func sweepTrash(olderThanDays days: Int, removing remove: (URL) throws -> Void) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let expired: [CaptureRecord]
        do {
            expired = try withOperation {
                try db.queue.read { d in
                    try CaptureRecord.fetchAll(d, sql: """
                        SELECT * FROM captures WHERE (status = 'sweeping'
                            OR (status = 'trashed' AND trashedAt < ?))
                            AND id NOT IN (SELECT captureId FROM blocked_captures)
                        """, arguments: [cutoff])
                }
            }
        } catch { Log.store.error("trash cleanup deferred: \(error)"); return }

        var referents: OriginalReferents?
        var undecided: [String] = []
        for record in expired {
            // Decided before the lock: reading a sidecar — and, for a legacy original, every
            // sidecar in the library — is the slow part, and none of it should hold up a Keep
            // press. A restore that lands in between is caught by the checks under the lock,
            // and the scan cannot go stale in a way that deletes anything: legacy references
            // are only ever carried across moves, never created, so a stale map can at most
            // keep a file it might have deleted.
            let disposition = originalDisposition(for: record, referents: &referents)
            if case .undecidable = disposition {
                // Keep the row as well: its sidecar is what still names the original, and the
                // next pass can decide once the sidecar it could not read is fixed.
                undecided.append(record.id)
                continue
            }
            do {
                // One capture per hold of the lock: a Keep press on the main thread waits out
                // one capture's deletes, not the whole pass.
                try withOperation(for: record.id) {
                    guard let current = try db.queue.read({ try CaptureRecord.fetchOne($0, key: record.id) }),
                          !current.isLive, current.relPath == record.relPath else { return }   // restored meanwhile
                    // Everything that can refuse was decided before the row is marked, so
                    // 'sweeping' always means deletion has begun — which is why restore
                    // refuses it. A row that could be marked and then fail to decide would
                    // be neither restorable nor sweepable.
                    try db.queue.write { d in
                        try d.execute(sql: "UPDATE captures SET status = 'sweeping' WHERE id = ?", arguments: [current.id])
                    }
                    if case .delete(let original) = disposition { try remove(original) }
                    let file = url(for: current)
                    try remove(file)
                    try remove(Sidecar.url(for: file))
                    try remove(tombstoneURL(current.id))
                    try db.queue.write { d in
                        try Library.cancelIngest(d, id: current.id)
                        try d.execute(sql: "DELETE FROM captures WHERE id = ?", arguments: [current.id])
                    }
                }
            } catch { Log.store.error("trash cleanup will retry \(record.id): \(error)") }
        }
        if !undecided.isEmpty {
            let unresolved = (referents?.unresolved ?? []).joined(separator: ", ")
            Log.store.error("trash cleanup kept \(undecided.count) capture(s) whose legacy originals could not be vouched for; sidecars or plans unreadable for: \(unresolved, privacy: .public)")
        }
    }

    enum OriginalDisposition {
        case keep, delete(URL), undecidable
    }

    /// What to do about a swept capture's pristine original. Anything unknowable keeps the
    /// file — a little disk is cheaper than someone else's pixels — and `.undecidable` keeps
    /// the row too, so the original stays named by a sidecar the next pass can read again.
    private func originalDisposition(for record: CaptureRecord,
                                     referents: inout OriginalReferents?) -> OriginalDisposition {
        let file = url(for: record)
        guard let original = Sidecar.read(for: file)?.annotations?.original else { return .keep }
        guard let target = try? checkedOriginalURL(original) else {
            Log.store.error("sweep keeps an original outside .originals/ for \(record.id): \(original, privacy: .public)")
            return .keep
        }
        if original == Library.ownOriginalPath(id: record.id, ext: file.pathExtension) { return .delete(target) }
        // Already gone — an earlier sweep of a sibling took it — so nobody needs asking.
        guard (try? itemExists(target)) == true else { return .keep }
        // Legacy originals are keyed by the visible path, which two captures can have shared.
        let scan = referents ?? scanOriginalReferents()
        referents = scan
        switch scan.referenced(target, byAnyoneBut: record.id) {
        case .some(true): return .keep
        case .some(false): return .delete(target)
        case .none: return .undecidable
        }
    }

    /// Which `.originals/` files the rest of the library still points at, built once per sweep
    /// and only if a legacy original comes up. Any sidecar or plan that cannot be read makes
    /// the answer unknowable for the pass — it could have named any of them.
    struct OriginalReferents {
        let refs: [URL: Set<String>]
        /// Capture ids whose sidecar or plan could not be read or did not point inside
        /// `.originals/`. Non-empty means no legacy original can be vouched for this pass.
        let unresolved: [String]

        /// nil when unknowable.
        func referenced(_ target: URL, byAnyoneBut id: String) -> Bool? {
            guard unresolved.isEmpty else { return nil }
            return !refs[target, default: []].subtracting([id]).isEmpty
        }
    }

    private func scanOriginalReferents() -> OriginalReferents {
        var refs: [URL: Set<String>] = [:]
        var unresolved: [String] = []
        func note(_ path: String?, from id: String) {
            guard let path else { return }
            guard let url = try? checkedOriginalURL(path) else { unresolved.append(id); return }
            refs[url, default: []].insert(id)
        }
        func note(sidecarAt rel: String, from id: String) {
            do { note(try Sidecar.readIfPresent(for: root.appendingPathComponent(rel))?.annotations?.original, from: id) }
            catch { unresolved.append(id) }
        }
        do {
            for row in try db.queue.read({ try Row.fetchAll($0, sql: "SELECT id, relPath FROM captures") }) {
                note(sidecarAt: row["relPath"], from: row["id"])
            }
            // A failed move may have put the sidecar at its destination before the row changed.
            // Plan-less legacy rows carry no sidecar, and their capture is already in the scan.
            for row in try db.queue.read({ try Row.fetchAll($0, sql: "SELECT captureId, plan FROM op_journal") }) {
                guard let data: Data = row["plan"] else { continue }
                let id: String = row["captureId"]
                guard let plan = try? JSONDecoder().decode(FileOperation.self, from: data) else { unresolved.append(id); continue }
                note(plan.sidecar?.annotations?.original, from: id)
                for rel in Set([plan.source, plan.record.relPath]) { note(sidecarAt: rel, from: id) }
            }
        } catch { unresolved.append("(database: \(error))") }
        return OriginalReferents(refs: refs, unresolved: unresolved)
    }
}
