// Background ingest: every kept capture gets OCR'd so the library's search index has text to
// match (spec §8). Jobs are persisted in ingest_jobs, so quitting mid-index resumes cleanly;
// they run serially at utility QoS and never block a capture. A discard cancels its job, and a
// result that arrives for a trashed capture is dropped rather than applied.
import Foundation
import AppKit
import AVFoundation
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
        while true {
            while let job = nextDueJob() { await process(job) }
            // Nothing due *yet*. Every enqueue is debounced and every retry is deferred, so
            // exiting here would strand a lone capture until the next capture, keep gesture or
            // app launch. Wait for the earliest pending job instead — capped so a job enqueued
            // while we sleep still starts promptly — and stop only when the table is empty.
            guard let wait = secondsUntilNextJob() else { return }
            try? await Task.sleep(for: .seconds(min(max(wait, 0.5), 5)))
            if Task.isCancelled { return }
        }
    }

    /// Seconds until the earliest pending job comes due; nil when no jobs remain.
    private func secondsUntilNextJob() -> TimeInterval? {
        guard let library else { return nil }
        return (try? library.db.queue.read { d -> TimeInterval? in
            guard let next = try Date.fetchOne(d, sql: "SELECT MIN(notBefore) FROM ingest_jobs")
            else { return nil }
            return max(0, next.timeIntervalSinceNow)
        }) ?? nil
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
        if Settings.shared.aiNamingEnabled {
            var naming: CaptureNaming?
            var engine = "local"
            // API engine when the user has set a key: verified far better than the heuristic
            if let key = Keychain.anthropicKey, !key.isEmpty,
               let image = OverlayPosterDecoder.decode(url) {
                do {
                    naming = try await AnthropicNamer.name(image: image, ocr: text, app: record.sourceApp,
                                                           windowTitle: record.windowTitle,
                                                           kind: record.kind, key: key)
                    engine = "api"
                } catch {
                    Log.store.error("api naming failed, falling back: \(error)")
                }
            }
            if naming == nil {
                naming = NamingService.local(ocr: text, app: record.sourceApp,
                                             windowTitle: record.windowTitle, kind: record.kind)
            }
            if let naming {
                let applied = library.applyName(job.captureId, baseName: naming.filename,
                                                tags: naming.tags, summary: naming.summary,
                                                engine: engine)
                // applyName refuses while a drag/save panel holds the path (it must not move a
                // file out from under one). Leave the job in place so a later pass renames it —
                // bounded, so a stuck in-use flag can't spin the queue forever.
                if !applied, Library.isInUse(job.captureId), job.attempts < 5 {
                    try? await library.db.queue.write { d in
                        try d.execute(sql: """
                            UPDATE ingest_jobs SET attempts = attempts + 1, notBefore = ?,
                                                   lastError = 'in use'
                            WHERE captureId = ?
                            """, arguments: [Date().addingTimeInterval(30), job.captureId])
                    }
                    return
                }
            }
        }
        clearJob(job.captureId)
    }
}

/// Decoding a library file to a CGImage: stills directly, movies via their first frame
/// (NSImage returns nil for .mp4, which silently skipped every recording).
public enum OverlayPosterDecoder {
    public static func decode(_ url: URL) -> CGImage? {
        if let still = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return still
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }
}
