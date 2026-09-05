// Renaming a capture to the name the intelligence pipeline suggested, plus the in-use registry
// that decides when a rename has to wait. The suggestion itself comes from KaptureIntelligence;
// everything here is about applying it safely to a file the shell may be holding.
import Foundation
import GRDB

extension Library {
    /// Files the shell is actively using — a drag in flight, an open save panel, a running
    /// upload. An AI rename must not move a file out from under one of those (the pasteboard
    /// holds a concrete URL), so applyName refuses and the ingest job retries later.
    private static let inUseLock = NSLock()
    nonisolated(unsafe) private static var inUseIDs: Set<String> = []

    public static func markInUse(_ id: String) {
        inUseLock.lock(); defer { inUseLock.unlock() }
        inUseIDs.insert(id)
    }
    public static func clearInUse(_ id: String) {
        inUseLock.lock(); defer { inUseLock.unlock() }
        inUseIDs.remove(id)
    }
    public static func isInUse(_ id: String) -> Bool {
        inUseLock.lock(); defer { inUseLock.unlock() }
        return inUseIDs.contains(id)
    }

    /// An asynchronous naming result belongs to its job generation and content revision.
    @discardableResult
    public func applyName(_ id: String, baseName: String, tags: [String], summary: String,
                          aiState: CaptureRecord.AIState, job: IngestJob? = nil) -> Bool {
        do {
            return try withOperation(for: id) {
                guard !Library.isInUse(id),
                      var record = try db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }),
                      record.aiState.acceptsName, record.status != .trashed, record.status != .sweeping else { return false }
                if let job, try ingestRecord(job) == nil { return false }
                let current = url(for: record)
                let target = Library.uniqueURL(in: current.deletingLastPathComponent(), base: baseName, ext: current.pathExtension)
                let source = record.relPath
                record.relPath = rel(target); record.aiState = aiState; record.summary = summary
                try commit(FileOperation(op: "rename", source: source, record: record,
                    sidecar: nil, tags: tags.joined(separator: " ")))
                return true
            }
        } catch {
            Log.store.error("rename failed for \(id): \(error)")
            return false
        }
    }
}
