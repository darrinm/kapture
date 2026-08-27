// Background ingest: every kept capture gets OCR'd so the library's search index has text to
// match (spec §8). Jobs are persisted in ingest_jobs, so quitting mid-index resumes cleanly;
// they run serially at utility QoS and never block a capture. A discard cancels its job, and a
// result that arrives for a trashed capture is dropped rather than applied.
import Foundation
import AppKit
import GRDB
import KaptureCore

public actor IngestQueue {
    public static let shared = IngestQueue()
    private var library: Library?
    private var running = false
    /// Captures wait this long before OCR — a burst-triage discard shouldn't cost any work.
    private let debounce: TimeInterval = 30

    public func configure(library: Library) {
        self.library = library
    }

    /// Enqueue a capture for OCR. Safe to call repeatedly; the row is the queue.
    public func enqueue(_ id: String, after delay: TimeInterval? = nil) {
        guard let library else { return }
        let notBefore = Date().addingTimeInterval(delay ?? debounce)
        try? library.db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO ingest_jobs (captureId, stage, notBefore, attempts)
                VALUES (?, 'ocr', ?, 0)
                ON CONFLICT(captureId) DO UPDATE SET notBefore = MIN(notBefore, excluded.notBefore)
                """, arguments: [id, notBefore])
        }
        Task { await drainLoop() }
    }

    /// A keep/act gesture means the capture is worth indexing now rather than after the debounce.
    public func expedite(_ id: String) {
        guard let library else { return }
        try? library.db.queue.write { d in
            try d.execute(sql: "UPDATE ingest_jobs SET notBefore = ? WHERE captureId = ?",
                          arguments: [Date(), id])
        }
        Task { await drainLoop() }
    }

    public func cancel(_ id: String) { clearJob(id) }

    private func clearJob(_ id: String) {
        guard let library else { return }
        try? library.db.queue.write { d in
            try d.execute(sql: "DELETE FROM ingest_jobs WHERE captureId = ?", arguments: [id])
        }
    }

    /// Called at launch: pick up anything left over from a previous run.
    public func resume() {
        Task { await drainLoop() }
    }

    // MARK: draining

    private func drainLoop() async {
        guard !running, library != nil else { return }
        running = true
        defer { running = false }
        while let job = nextDueJob() {
            await process(job)
        }
    }

    private struct Job { let captureId: String; let attempts: Int }

    private func nextDueJob() -> Job? {
        guard let library else { return nil }
        return try? library.db.queue.read { d -> Job? in
            guard let row = try Row.fetchOne(d, sql: """
                SELECT captureId, attempts FROM ingest_jobs
                WHERE notBefore <= ? ORDER BY notBefore LIMIT 1
                """, arguments: [Date()]) else { return nil }
            return Job(captureId: row["captureId"], attempts: row["attempts"])
        }
    }

    private func process(_ job: Job) async {
        guard let library else { return }
        // the record must still be worth indexing when the job runs
        guard let record = try? await library.db.queue.read({ d in
            try CaptureRecord.fetchOne(d, key: job.captureId)
        }), record.status != .trashed, record.status != .sweeping else {
            clearJob(job.captureId)
            return
        }
        guard record.canAnnotate || record.kind == .gif else {   // stills and GIFs only for now
            clearJob(job.captureId)
            return
        }

        let url = library.url(for: record)
        let text = await Task.detached(priority: .utility) { () -> String in
            guard let image = OverlayPosterDecoder.decode(url) else { return "" }
            return OCRService.clipboardText(for: image)
        }.value

        // re-check status: the capture may have been discarded while OCR ran
        guard let fresh = try? await library.db.queue.read({ d in
            try CaptureRecord.fetchOne(d, key: job.captureId)
        }), fresh.status != .trashed else {
            clearJob(job.captureId)
            return
        }

        if text.isEmpty, job.attempts < 2 {
            // transient failures (a file still being written) get one more go
            try? await library.db.queue.write { d in
                try d.execute(sql: """
                    UPDATE ingest_jobs SET attempts = attempts + 1, notBefore = ?, lastError = 'empty'
                    WHERE captureId = ?
                    """, arguments: [Date().addingTimeInterval(20), job.captureId])
            }
            return
        }

        try? library.updateSearchText(job.captureId, ocr: String(text.prefix(20_000)))
        try? await library.db.queue.write { d in
            try d.execute(sql: "UPDATE captures SET aiState = 'ocr' WHERE id = ?", arguments: [job.captureId])
        }
        Log.store.info("ingest: indexed \(record.relPath, privacy: .public) (\(text.count) chars)")

        // Stage 2 — name it from what we just read. Optional: with naming off, captures keep
        // their timestamp names and everything else still works (spec §8).
        if Settings.shared.aiNamingEnabled,
           let naming = NamingService.local(ocr: text, app: record.sourceApp,
                                            windowTitle: record.windowTitle, kind: record.kind) {
            _ = library.applyName(job.captureId, baseName: naming.filename, tags: naming.tags,
                                  summary: naming.summary, engine: "local")
        }
        clearJob(job.captureId)
    }
}

/// Decoding a library file to a CGImage without pulling AppKit UI code into the actor.
public enum OverlayPosterDecoder {
    public static func decode(_ url: URL) -> CGImage? {
        NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
