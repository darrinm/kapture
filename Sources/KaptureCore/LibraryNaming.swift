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

    /// Rename a capture's file to an AI-suggested base name (extension preserved), journaled and
    /// compare-and-swapped: the rename is skipped if the row changed underneath (a manual rename
    /// pins aiState) or the target already exists. Sidecar, search index and identity follow.
    @discardableResult
    public func applyName(_ id: String, baseName: String, tags: [String], summary: String,
                          aiState: CaptureRecord.AIState) -> Bool {
        guard !Library.isInUse(id) else { return false }   // drag/upload/save panel holds the path
        guard let record = try? db.queue.read({ try CaptureRecord.fetchOne($0, key: id) }),
              record.aiState.acceptsName,   // never overwrite a named/manual row
              record.status != .trashed, record.status != .sweeping else { return false }

        let fm = FileManager.default
        let current = url(for: record)
        let ext = current.pathExtension
        let dir = current.deletingLastPathComponent()
        let target = Library.uniqueURL(in: dir, base: baseName, ext: ext)
        guard target.lastPathComponent != current.lastPathComponent else { return false }
        let newRel = rel(target)

        do {
            _ = try OpJournal.run(db, op: "rename", captureId: id, src: record.relPath, dst: newRel,
                fileOp: {
                    guard fm.fileExists(atPath: current.path), !fm.fileExists(atPath: target.path) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try moveWithSidecar(from: current, to: target)
                },
                stateUpdate: { d, _ in
                    // CAS: only rewrite the row if nothing moved it while we worked
                    try d.execute(sql: """
                        UPDATE captures SET relPath = ?, fastID = ?, aiState = ?, summary = ?
                        WHERE id = ? AND relPath = ?
                        """, arguments: [newRel, Library.fastID(of: target), aiState.rawValue,
                                         summary, id, record.relPath])
                    // CAS missed: something moved the row while the file op ran. Throw so the
                    // journal entry survives for recovery rather than leaving the row pointing
                    // at a path the file has already left.
                    guard d.changesCount > 0 else { throw CocoaError(.fileWriteFileExists) }
                    try Library.indexText(d, id: id, name: target.lastPathComponent,
                                          summary: summary, tags: tags.joined(separator: " "))
                })
            Log.store.info("named \(record.relPath, privacy: .public) → \(newRel, privacy: .public)")
            return true
        } catch {
            Log.store.error("rename failed for \(id): \(error)")
            return false
        }
    }
}
