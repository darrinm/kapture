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

    func commit(_ plan: FileOperation) throws {
        defer { removeUnjournaledStage(root.appendingPathComponent(plan.source)) }
        let data = try JSONEncoder().encode(plan)
        let journalID = try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO op_journal (op, captureId, src, dst, startedAt, plan) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [plan.op, plan.record.id, plan.source, plan.record.relPath, Date(), data])
            return d.lastInsertedRowID
        }
        try finish(plan, journalID: journalID)
    }

    /// Testable separately from launch; the operation lock also prevents a later edit/rename
    /// from overtaking an operation whose filesystem half succeeded but whose commit failed.
    public func recoverPendingOperations() throws {
        db.operationLock.lock(); defer { db.operationLock.unlock() }
        let rows = try db.queue.read { try Row.fetchAll($0, sql: "SELECT * FROM op_journal WHERE recoveryError IS NULL ORDER BY id") }
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
                    try finish(plan, journalID: journalID)
                } else {
                    try db.queue.write { d in
                        try d.execute(sql: "DELETE FROM op_journal WHERE id = ?", arguments: [journalID])
                    }
                }
            } catch {
                // Any per-entry failure is isolated. Keep its bytes and plan, and require an
                // explicit retry before changing that capture; unrelated work can continue.
                try db.queue.write { d in
                    try d.execute(sql: "UPDATE op_journal SET recoveryError = ? WHERE id = ?",
                                  arguments: [String(describing: error), journalID])
                }
                Log.store.error("quarantined journal entry \(journalID): \(error)")
            }
        }
    }

    private func requireRecovered(_ id: String) throws {
        if let message = try db.queue.read({ d in
            try String.fetchOne(d, sql: "SELECT recoveryError FROM op_journal WHERE captureId = ? AND recoveryError IS NOT NULL LIMIT 1",
                                arguments: [id])
        }) {
            throw RecoveryBlocked(description: "Capture has an unfinished file operation: " + message)
        }
    }

    /// After repairing permissions or resolving a collision, retry only this capture's intents.
    public func retryRecovery(for id: String) throws {
        db.operationLock.lock(); defer { db.operationLock.unlock() }
        try db.queue.write { d in
            try d.execute(sql: "UPDATE op_journal SET recoveryError = NULL WHERE captureId = ?", arguments: [id])
        }
        try recoverPendingOperations()
        try requireRecovered(id)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE ingest_jobs SET notBefore = ? WHERE captureId = ?", arguments: [Date(), id])
        }
    }

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

    /// Called only at startup: live snapshots and pre-journal staging files cannot exist yet.
    func cleanOrphanedStages() {
        db.operationLock.lock(); defer { db.operationLock.unlock() }
        let dir = root.appendingPathComponent(".pending")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files { removeUnjournaledStage(file) }
    }

    private func moveSidecar(from source: URL, to target: URL, fallback: Sidecar?) throws {
        guard source != target else { return }
        let src = Sidecar.url(for: source), dst = Sidecar.url(for: target)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: src.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // A crash may already have moved it. Older plans may be the sole remaining copy.
            if !(try itemExists(dst)) { try fallback?.write(next: target) }
            return
        }
        // Move bytes verbatim, even when unreadable, evicted, or from a newer sidecar format.
        // A destination collision is quarantined rather than overwriting either sidecar.
        try FileManager.default.moveItem(at: src, to: dst)
    }

    private func finish(_ plan: FileOperation, journalID: Int64) throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent(plan.source)
        let target = url(for: plan.record)
        let replacing = plan.op == "flatten" || plan.op == "trim"
        if source != target, try itemExists(source) {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        guard try itemExists(target) else { throw CocoaError(.fileNoSuchFile) }
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
    private func legacyPlan(_ row: Row) throws -> FileOperation? {
        let id: String = row["captureId"]
        let op: String = row["op"]
        let src: String? = row["src"]
        guard let dst: String = row["dst"] else { throw CocoaError(.fileReadCorruptFile) }
        let target = root.appendingPathComponent(dst)
        let existing = try db.queue.read { try CaptureRecord.fetchOne($0, key: id) }
        if let existing, existing.relPath != src, existing.relPath != dst,
           FileManager.default.fileExists(atPath: url(for: existing).path) {
            return nil // an old failed intent was superseded by a later successful operation
        }
        if let src, src != dst, FileManager.default.fileExists(atPath: root.appendingPathComponent(src).path) {
            // Restore in old builds flipped status before doing the move.
            if op == "restore" {
                try db.queue.write { d in
                    try d.execute(sql: "UPDATE captures SET status = 'trashed', trashedAt = COALESCE(trashedAt, ?) WHERE id = ?",
                                  arguments: [Date(), id])
                }
            }
            return nil
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            if existing == nil { return nil } // write never reached disk
            throw CocoaError(.fileNoSuchFile)
        }
        if ["flatten", "trim"].contains(op), src == dst,
           let existing, existing.fastID == Library.fastID(of: target) {
            return nil // the old file operation failed before replacing any pixels
        }
        let sidecar: Sidecar?
        if ["rename", "discard", "restore"].contains(op) {
            sidecar = Sidecar.read(for: target) ?? src.flatMap { Sidecar.read(for: root.appendingPathComponent($0)) }
        } else {
            sidecar = try Sidecar.readIfPresent(for: target)
        }
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

    private func itemExists(_ url: URL) throws -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return false }
    }

    func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }
}

private struct RecoveryBlocked: Error, CustomStringConvertible {
    let description: String
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
