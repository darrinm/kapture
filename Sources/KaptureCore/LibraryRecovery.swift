import Foundation
import GRDB
import ImageIO
import AVFoundation

/// The complete intended state is durable before any visible file moves. Replaying the same
/// plan is safe whether the crash happened before the move, during metadata writes, or before
/// the SQLite commit. Incoming bytes are staged on the library's own filesystem.
struct FileOperation: Codable {
    var op: String
    var source: String
    var record: CaptureRecord
    var sidecar: Sidecar?
    var originalRelPath: String? = nil
    var tags: String? = nil
    var probeMovieMetadata: Bool? = nil
}

/// The file an operation needed is at neither end of its move. No retry will make it appear
/// and the row is as consistent as it can be, so the entry is abandoned rather than parked:
/// the caller hears once, and the capture is not blocked afterwards.
public struct FileVanished: LocalizedError {
    public let path: String
    public var errorDescription: String? { "The file for this capture is missing: \(path)" }
}

/// Thrown for any operation on a capture whose journal entry has not finished replaying.
public struct RecoveryBlocked: LocalizedError {
    public let captureID: String
    /// True when no retry can fix it and something on disk or in the journal needs a human;
    /// false while recovery is only backing off between attempts.
    public let quarantined: Bool
    public let reason: String

    public var errorDescription: String? {
        (quarantined ? "This capture needs attention before it can change: "
                     : "This capture has an unfinished file operation, retrying: ") + reason
    }
}

extension Library {
    func withOperation<T>(for captureID: String? = nil, _ body: () throws -> T) throws -> T {
        db.operationLock.lock(); defer { db.operationLock.unlock() }
        try recoverPendingOperations()
        if let captureID { try requireRecovered(captureID) }
        return try body()
    }

    func stagingURL(ext: String) throws -> URL {
        let dir = root.appendingPathComponent(".pending", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    func stageData(_ data: Data) throws -> URL {
        let url = try stagingURL(ext: "png")
        do { try data.write(to: url, options: .atomic) }
        catch { try? removeIfPresent(url); throw error }
        return url
    }

    func stageFile(_ file: URL) throws -> URL {
        let url = try stagingURL(ext: file.pathExtension)
        // Keep the caller's temp file until the operation commits, including journal failures.
        do { try FileManager.default.copyItem(at: file, to: url) }
        catch { try? removeIfPresent(url); throw error }
        return url
    }

    /// Journal the plan, then carry it out. Every caller that staged bytes owns their cleanup
    /// (a `defer` around the stage), so nothing is repeated here. A failure after the journal
    /// row exists is recorded on it the same way a failed replay would be, so the entry backs
    /// off or is quarantined exactly as if the crash had come a moment later.
    func commit(_ plan: FileOperation) throws {
        let data = try JSONEncoder().encode(plan)
        let journalID = try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO op_journal (op, captureId, src, dst, startedAt, plan) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [plan.op, plan.record.id, plan.source, plan.record.relPath, Date(), data])
            return d.lastInsertedRowID
        }
        do { try finish(plan, journalID: journalID, replay: false) }
        catch {
            try? recordReplayFailure(error, journalID: journalID, attempts: 0)
            throw error
        }
    }

    // MARK: - Replay

    /// A replay failure that no retry can fix: something on disk or in the journal has to be
    /// put right by hand first. A plan that will not decode, a name already taken — on disk or
    /// by a row — a path outside the library. Everything else — a permission not yet granted,
    /// a full or busy disk, a locked database — is assumed to clear on its own and is retried
    /// with backoff rather than parked. (A file missing at both ends is neither: see
    /// `FileVanished`.)
    static func isPermanentRecoveryFailure(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        if let database = error as? DatabaseError {
            // Only the "taken" constraints. A trigger's RAISE, a CHECK, a NOT NULL all report
            // SQLITE_CONSTRAINT too, and none of them is a name collision.
            return [.SQLITE_CONSTRAINT_UNIQUE, .SQLITE_CONSTRAINT_PRIMARYKEY].contains(database.extendedResultCode)
        }
        guard let cocoa = error as? CocoaError else { return false }
        switch cocoa.code {
        case .fileReadCorruptFile, .fileReadInvalidFileName, .fileNoSuchFile, .fileReadNoSuchFile,
             .fileWriteFileExists:
            return true
        default:
            return false
        }
    }

    /// How long a transient failure waits before the next try. The first failure waits for
    /// nothing — the caller has its error, and the next operation or relaunch simply tries
    /// again — then doubling from two seconds, capped at an hour. It never gives up, transient
    /// meaning it will resolve, and while it waits the capture stays blocked so nothing
    /// overtakes the half-finished operation.
    static func recoveryBackoff(attempts: Int) -> TimeInterval {
        attempts == 0 ? 0 : min(3600, pow(2, Double(min(attempts, 12))))
    }

    /// Testable separately from launch; the operation lock also prevents a later edit/rename
    /// from overtaking an operation whose filesystem half succeeded but whose commit failed.
    public func recoverPendingOperations() throws {
        db.operationLock.lock(); defer { db.operationLock.unlock() }
        let rows = try db.queue.read { d in
            try Row.fetchAll(d, sql: """
                SELECT * FROM op_journal
                WHERE recoveryError IS NULL AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?)
                ORDER BY id
                """, arguments: [Date()])
        }
        for row in rows {
            let journalID: Int64 = row["id"]
            do {
                let plan: FileOperation?
                if let data: Data = row["plan"] {
                    plan = try JSONDecoder().decode(FileOperation.self, from: data)
                } else {
                    plan = try legacyPlan(row)
                }
                if let plan {
                    try finish(plan, journalID: journalID, replay: true)
                } else {
                    try db.queue.write { d in
                        try d.execute(sql: "DELETE FROM op_journal WHERE id = ?", arguments: [journalID])
                    }
                }
            } catch {
                // Isolated per entry: this capture waits or is parked, unrelated work continues.
                try recordReplayFailure(error, journalID: journalID, attempts: row["attempts"])
            }
        }
    }

    private func recordReplayFailure(_ error: Error, journalID: Int64, attempts: Int) throws {
        let message = String(describing: error)
        if error is FileVanished {
            try db.queue.write { d in
                try d.execute(sql: "DELETE FROM op_journal WHERE id = ?", arguments: [journalID])
            }
            Log.store.error("abandoned journal entry \(journalID): \(message)")
        } else if Library.isPermanentRecoveryFailure(error) {
            try db.queue.write { d in
                try d.execute(sql: "UPDATE op_journal SET recoveryError = ?, lastError = ? WHERE id = ?",
                              arguments: [message, message, journalID])
            }
            Log.store.error("quarantined journal entry \(journalID): \(message)")
        } else {
            let delay = Library.recoveryBackoff(attempts: attempts)
            try db.queue.write { d in
                try d.execute(sql: """
                    UPDATE op_journal SET attempts = attempts + 1, nextAttemptAt = ?, lastError = ?
                    WHERE id = ?
                    """, arguments: [Date().addingTimeInterval(delay), message, journalID])
            }
            Log.store.error("journal entry \(journalID) failed, retrying in \(Int(delay))s: \(message)")
        }
    }

    /// A capture with an unfinished file operation is not touched until it finishes — whether
    /// the entry is only backing off or needs a human. Otherwise an edit could overtake a rename
    /// whose filesystem half succeeded.
    private func requireRecovered(_ id: String) throws {
        guard let row = try db.queue.read({ d in
            try Row.fetchOne(d, sql: """
                SELECT recoveryError, lastError FROM op_journal WHERE captureId = ?
                ORDER BY recoveryError IS NULL, id LIMIT 1
                """, arguments: [id])
        }) else { return }
        let quarantined: String? = row["recoveryError"]
        let last: String? = row["lastError"]
        throw RecoveryBlocked(captureID: id, quarantined: quarantined != nil,
                              reason: quarantined ?? last ?? "the operation has not finished yet")
    }

    /// After repairing permissions or resolving a collision, retry only this capture's intents.
    public func retryRecovery(for id: String) throws {
        db.operationLock.lock(); defer { db.operationLock.unlock() }
        try db.queue.write { d in
            try d.execute(sql: """
                UPDATE op_journal SET recoveryError = NULL, attempts = 0, nextAttemptAt = NULL
                WHERE captureId = ?
                """, arguments: [id])
        }
        try recoverPendingOperations()
        try requireRecovered(id)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE ingest_jobs SET notBefore = ? WHERE captureId = ?", arguments: [Date(), id])
        }
    }

    // MARK: - Staging

    func removeUnjournaledStage(_ file: URL) {
        guard file.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent(".pending").standardizedFileURL else { return }
        do {
            // Directory enumeration may return /private/var while root was opened via /var.
            // These are direct children of .pending; do not derive their keys by string surgery.
            let referenced = try db.queue.read { d in
                try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM op_journal WHERE src = ?)", arguments: [".pending/" + file.lastPathComponent]) ?? false
            }
            if !referenced { try removeIfPresent(file) }
        } catch { Log.store.error("staging cleanup deferred: \(error)") }
    }

    /// Called only at startup. Live share snapshots and pre-journal staging files cannot exist
    /// yet — `Library(exclusive:)` is what guarantees no other process is mid-operation on
    /// this root.
    func cleanOrphanedStages() {
        db.operationLock.lock(); defer { db.operationLock.unlock() }
        let dir = root.appendingPathComponent(".pending")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files { removeUnjournaledStage(file) }
    }

    // MARK: - Carrying out a plan

    private func moveSidecar(from source: URL, to target: URL, fallback: Sidecar?) throws {
        guard source != target else { return }
        let src = Sidecar.url(for: source), dst = Sidecar.url(for: target)
        guard try itemExists(src) else {
            // A crash may already have moved it. Older plans may be the sole remaining copy.
            if !(try itemExists(dst)) { try fallback?.write(next: target) }
            return
        }
        // Move bytes verbatim, even when unreadable, evicted, or from a newer sidecar format.
        // A destination collision is quarantined rather than overwriting either sidecar.
        try FileManager.default.moveItem(at: src, to: dst)
    }

    /// `replay` is a plan being finished after the fact — by a later operation or a relaunch —
    /// rather than by the call that made it. The caller of that call is long gone, so what it
    /// would have done next (enqueue OCR, wake the ingest queue) falls to us.
    private func finish(_ plan: FileOperation, journalID: Int64, replay: Bool) throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent(plan.source)
        let target = url(for: plan.record)
        let replacing = plan.op == "flatten" || plan.op == "trim"
        // Before anything lands there — the file, but also a sidecar or tombstone for a discard
        // whose file is already gone, on a first launch where .trash/ has never been made.
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if source != target, try itemExists(source) {
            if replacing {
                if let original = plan.sidecar?.annotations?.original {
                    let originalURL = try checkedOriginalURL(original)
                    if !(try itemExists(originalURL)) {
                        try fm.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        // Publish only a complete original. A crash during copy must not leave
                        // a partial file that a retry mistakes for the pristine image/movie.
                        let copy = try stagingURL(ext: originalURL.pathExtension)
                        defer { try? removeIfPresent(copy) }
                        try fm.copyItem(at: target, to: copy)
                        try fm.moveItem(at: copy, to: originalURL)
                    }
                }
                _ = try fm.replaceItemAt(target, withItemAt: source)
            } else {
                // moveItem refuses collisions instead of overwriting unrelated captures.
                try fm.moveItem(at: source, to: target)
            }
        }
        if !(try itemExists(target)) {
            // A discard's end state — row trashed, file gone — is reachable without the file,
            // and is what the user asked for. Anything else has nothing left to operate on.
            guard plan.op == "discard" else {
                throw FileVanished(path: plan.op == "write" ? plan.record.relPath : plan.source)
            }
        }
        if ["discard", "restore", "rename"].contains(plan.op) {
            try moveSidecar(from: source, to: target, fallback: plan.sidecar)
        } else {
            try plan.sidecar?.write(next: target)
        }
        if plan.op == "discard", let original = plan.originalRelPath {
            let tomb = Tombstone(id: plan.record.id, originalRelPath: original,
                                 trashedAt: plan.record.trashedAt ?? Date())
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(tomb).write(to: tombstoneURL(plan.record.id), options: .atomic)
        } else if plan.op == "restore" {
            try removeIfPresent(tombstoneURL(plan.record.id))
        }
        var record = plan.record
        record.fastID = Library.fastID(of: target)
        record.bytes = Library.byteSize(of: target)
        try db.queue.write { d in
            try record.save(d)
            try Library.indexText(d, id: record.id, name: ["write", "rename", "restore"].contains(plan.op) ? target.lastPathComponent : nil,
                                  summary: plan.op == "rename" ? record.summary : nil, tags: plan.tags)
            if replacing {
                try d.execute(sql: "UPDATE fts_source SET ocr = '', summary = '', tags = '' WHERE captureId = ?",
                              arguments: [record.id])
                if record.canAnnotate || record.kind == .gif {
                    try Library.enqueueIngest(d, record: record, notBefore: Date(), replacing: true)
                }
            }
            if record.status == .trashed {
                try d.execute(sql: "DELETE FROM ingest_jobs WHERE captureId = ?", arguments: [record.id])
            } else if replay {
                // A write finished here never reached the caller that would have enqueued its
                // OCR; a first-run write leaves that to the caller and its debounce.
                if plan.op == "write", record.canAnnotate || record.kind == .gif {
                    try Library.enqueueIngest(d, record: record, notBefore: Date())
                }
                // This capture's jobs were hidden while its entry existed, and the drain loop
                // may have gone to sleep with nothing to wait for. The ingest queue observes
                // writes to ingest_jobs, not to op_journal, so touching the row is the wake-up.
                try d.execute(sql: "UPDATE ingest_jobs SET notBefore = MIN(notBefore, ?) WHERE captureId = ?",
                              arguments: [Date(), record.id])
            }
            try d.execute(sql: "DELETE FROM op_journal WHERE id = ?", arguments: [journalID])
        }
        if plan.probeMovieMetadata == true {
            let recovered = record
            Task.detached(priority: .utility) { await self.refreshMovieMetadata(recovered) }
        }
        Log.store.info("completed \(plan.op, privacy: .public) for \(record.relPath, privacy: .public)")
    }

    /// Old builds journaled only paths. Recover completed moves and reconstruct orphaned writes
    /// from their file/sidecar; an untouched source means the failed move can be abandoned.
    ///
    /// Presence is asked with `itemExists`, never `fileExists(atPath:)`: the latter answers
    /// "no" to a file it is not allowed to see, and a permission that has not been granted yet
    /// would otherwise read as a move that already happened.
    private func legacyPlan(_ row: Row) throws -> FileOperation? {
        let id: String = row["captureId"]
        let op: String = row["op"]
        let src: String? = row["src"]
        guard let dst: String = row["dst"] else { throw CocoaError(.fileReadCorruptFile) }
        let target = root.appendingPathComponent(dst)
        let existing = try db.queue.read { try CaptureRecord.fetchOne($0, key: id) }
        if let existing, existing.relPath != src, existing.relPath != dst,
           try itemExists(url(for: existing)) {
            return nil // an old failed intent was superseded by a later successful operation
        }
        if let src, src != dst, try itemExists(root.appendingPathComponent(src)) {
            // Restore in old builds flipped status before doing the move.
            if op == "restore" {
                try db.queue.write { d in
                    try d.execute(sql: "UPDATE captures SET status = 'trashed', trashedAt = COALESCE(trashedAt, ?) WHERE id = ?",
                                  arguments: [Date(), id])
                }
            }
            return nil
        }
        if !(try itemExists(target)) {
            guard let existing else { return nil } // write never reached disk
            // A discard can finish without its file; nothing else has anything to operate on.
            guard op == "discard" else { throw FileVanished(path: existing.relPath) }
        } else if ["flatten", "trim"].contains(op), src == dst,
                  let existing, existing.fastID == Library.fastID(of: target) {
            return nil // the old file operation failed before replacing any pixels
        }
        // Read leniently. A corrupt legacy sidecar is synthesised below, which is byte for byte
        // what the old build wrote for a fresh capture — parking the entry instead would leave
        // a crashed write with no row at all, and nothing to surface it for a retry.
        let sidecar = Sidecar.read(for: target)
            ?? src.flatMap { Sidecar.read(for: root.appendingPathComponent($0)) }
        let ext = target.pathExtension.lowercased()
        var record = existing ?? CaptureRecord(id: id,
            kind: ext == "gif" ? .gif : (["mp4", "mov"].contains(ext) ? .recording : .screenshot),
            createdAt: sidecar?.created ?? row["startedAt"], width: 0, height: 0,
            bytes: Library.byteSize(of: target), relPath: dst, sourceApp: sidecar?.source?.app,
            windowTitle: sidecar?.source?.window, fastID: Library.fastID(of: target))
        record.relPath = dst
        if op == "discard" { record.status = .trashed; record.trashedAt = row["startedAt"] }
        if op == "restore" { record.status = .kept; record.trashedAt = nil }
        if existing == nil || op == "flatten" || op == "trim" {
            if let image = CGImageSourceCreateWithURL(target as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
                record.width = props[kCGImagePropertyPixelWidth] as? Int ?? record.width
                record.height = props[kCGImagePropertyPixelHeight] as? Int ?? record.height
            }
        }
        if op == "flatten" || op == "trim" {
            record.contentRevision += 1; record.contentHash = nil
            record.summary = nil; record.shareStale = record.shareURL != nil; record.aiState = .none
        }
        return FileOperation(op: op, source: src ?? dst, record: record,
            sidecar: sidecar ?? Sidecar(id: id, created: record.createdAt, app: record.sourceApp, window: record.windowTitle),
            originalRelPath: op == "discard" ? src : nil,
            probeMovieMetadata: record.kind == .recording && (existing == nil || op == "trim"))
    }

    func checkedOriginalURL(_ path: String) throws -> URL {
        let base = root.appendingPathComponent(".originals").resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
        return url
    }

    /// Whether something is at `url`. Unlike `fileExists(atPath:)` a file we may not read is
    /// "yes" — the error it raises is the caller's to classify, not a silent "no".
    func itemExists(_ url: URL) throws -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return false }
    }

    func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }
}

extension Library {
    /// Legacy journals lack media dimensions/duration. Probe after recovery, without holding
    /// the operation lock or parking a thread while waiting for an async task to run.
    private func refreshMovieMetadata(_ recovered: CaptureRecord) async {
        do {
            let asset = AVURLAsset(url: url(for: recovered))
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            try withOperation(for: recovered.id) {
                try db.queue.write { d in
                    try d.execute(sql: """
                        UPDATE captures SET durationS = ?, width = ?, height = ?
                        WHERE id = ? AND contentRevision = ? AND fastID = ? AND relPath = ?
                        """, arguments: [duration, Int(abs(size.applying(transform).width)),
                                         Int(abs(size.applying(transform).height)), recovered.id,
                                         recovered.contentRevision, recovered.fastID, recovered.relPath])
                }
            }
        } catch { Log.store.error("legacy movie metadata unavailable: \(error)") }
    }
}
