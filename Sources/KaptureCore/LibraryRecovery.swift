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
}

extension Library {
    func withOperation<T>(_ body: () throws -> T) throws -> T {
        db.operationLock.lock(); defer { db.operationLock.unlock() }
        try recoverPendingOperations()
        return try body()
    }

    private func stagingURL(ext: String) throws -> URL {
        let dir = root.appendingPathComponent(".pending", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    func stageData(_ data: Data) throws -> URL {
        let url = try stagingURL(ext: "png")
        try data.write(to: url, options: .atomic)
        return url
    }

    func stageFile(_ file: URL) throws -> URL {
        let url = try stagingURL(ext: file.pathExtension)
        try FileManager.default.moveItem(at: file, to: url)
        return url
    }

    func commit(_ plan: FileOperation) throws {
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
                // Finder can remove both paths before an operation runs. No amount of replay
                // can finish that intent; retain it for diagnosis without retrying it on every
                // unrelated operation (or preventing the library from opening at launch).
                guard try isUnrecoverable(row, error: error) else { throw error }
                try db.queue.write { d in
                    try d.execute(sql: "UPDATE op_journal SET recoveryError = ? WHERE id = ?",
                                  arguments: [String(describing: error), journalID])
                }
                Log.store.error("quarantined journal entry \(journalID): \(error)")
            }
        }
    }

    private func isUnrecoverable(_ row: Row, error: Error) throws -> Bool {
        if error is DecodingError { return true }
        guard let cocoa = error as? CocoaError,
              cocoa.code == .fileNoSuchFile || cocoa.code == .fileReadNoSuchFile else { return false }
        // Check for ENOENT explicitly. fileExists also returns false on access errors; those
        // must remain retryable rather than being mistaken for permanent missing-file errors.
        for column in ["src", "dst"] {
            guard let path: String = row[column] else { continue }
            do {
                _ = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
                return false
            } catch let missing as CocoaError where missing.code == .fileNoSuchFile || missing.code == .fileReadNoSuchFile {
                continue
            }
        }
        return true
    }

    private func finish(_ plan: FileOperation, journalID: Int64) throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent(plan.source)
        let target = url(for: plan.record)
        let replacing = plan.op == "flatten" || plan.op == "trim"
        if source != target, fm.fileExists(atPath: source.path) {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if replacing {
                if let original = plan.sidecar?.annotations?.original {
                    let originalURL = try checkedOriginalURL(original)
                    if !fm.fileExists(atPath: originalURL.path) {
                        try fm.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        // Publish only a complete original. A crash during copy must not leave
                        // a partial file that a retry mistakes for the pristine image/movie.
                        let copy = try stagingURL(ext: originalURL.pathExtension)
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
        guard fm.fileExists(atPath: target.path) else { throw CocoaError(.fileNoSuchFile) }
        try plan.sidecar?.write(next: target)
        if source != target { try removeIfPresent(Sidecar.url(for: source)) }
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
        let sidecar = Sidecar.read(for: target) ?? src.flatMap { Sidecar.read(for: root.appendingPathComponent($0)) }
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
            } else if record.kind == .recording {
                let metadata = LegacyMovieMetadata.read(target)
                record.durationS = metadata.duration
                record.width = metadata.width; record.height = metadata.height
            }
        }
        if op == "flatten" || op == "trim" {
            record.contentRevision += 1; record.contentHash = nil
            record.summary = nil; record.shareStale = record.shareURL != nil
        }
        return FileOperation(op: op, source: src ?? dst, record: record,
            sidecar: sidecar ?? Sidecar(id: id, created: record.createdAt, app: record.sourceApp, window: record.windowTitle),
            originalRelPath: op == "discard" ? src : nil)
    }

    func checkedOriginalURL(_ path: String) throws -> URL {
        let base = root.appendingPathComponent(".originals").resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
        return url
    }

    func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }
}

/// Only pre-plan journal entries need media probing. Library initialization is synchronous;
/// load AVFoundation properties on a detached task and publish its value before signaling.
private final class LegacyMovieMetadata: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var duration: Double?
    private var width = 0
    private var height = 0

    static func read(_ url: URL) -> (duration: Double?, width: Int, height: Int) {
        let result = LegacyMovieMetadata()
        Task.detached {
            defer { result.ready.signal() }
            let asset = AVURLAsset(url: url)
            result.duration = try? await asset.load(.duration).seconds
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                result.width = Int(abs(size.applying(transform).width))
                result.height = Int(abs(size.applying(transform).height))
            }
        }
        result.ready.wait()
        return (result.duration, result.width, result.height)
    }
}
