// Background ingest: every kept capture gets OCR'd so the library's search index has text to
// match (spec §8), then named if naming is on. Jobs are persisted in ingest_jobs, so quitting
// mid-index resumes cleanly; they run serially at utility QoS and never block a capture. A
// discard cancels its job, and a result that arrives for a trashed capture is dropped rather
// than applied.
//
// A job carries its stage in the row: 'ocr' → index the text → 'name' → rename the file. Two
// stages, two retry budgets, one `attempts` counter each because the transition resets it.
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
    /// Resumed by enqueue/expedite so a job filed while the drain loop sleeps starts at once.
    private var waiter: CheckedContinuation<Void, Never>?
    /// Handoff from the OCR stage to the name stage, which runs moments later in the same drain
    /// pass: the encoded JPEG (~100 KB) rather than a second decode of the full-size capture.
    private var pendingJPEG: (id: String, data: Data)?

    private enum Stage: String {
        case ocr, name
    }

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
        kick()
    }

    /// A keep/act gesture means the capture is worth indexing now rather than after the debounce.
    public func expedite(_ id: String) {
        guard let library else { return }
        try? library.db.queue.write { d in
            try d.execute(sql: "UPDATE ingest_jobs SET notBefore = ? WHERE captureId = ?",
                          arguments: [Date(), id])
        }
        kick()
    }

    public func cancel(_ id: String) { clearJob(id) }

    private func clearJob(_ id: String) {
        guard let library else { return }
        if pendingJPEG?.id == id { pendingJPEG = nil }
        try? library.db.queue.write { d in
            try d.execute(sql: "DELETE FROM ingest_jobs WHERE captureId = ?", arguments: [id])
        }
    }

    /// Called at launch: pick up anything left over from a previous run.
    public func resume() {
        kick()
    }

    // MARK: draining

    /// Start the drain loop, or wake it if it is already asleep waiting for the next job.
    private func kick() {
        waiter?.resume()
        waiter = nil
        Task { await drainLoop() }
    }

    private func drainLoop() async {
        guard !running, library != nil else { return }
        running = true
        defer { running = false; waiter = nil }
        while true {
            while let job = nextDueJob() { await process(job) }
            // Nothing due *yet*. Every enqueue is debounced and every retry is deferred, so
            // exiting here would strand a lone capture until the next capture, keep gesture or
            // app launch. Wait for the earliest pending job instead — interruptibly, so a job
            // filed while we sleep starts at once — and stop only when the table is empty.
            //
            // Everything from here to installing the continuation runs without an await, so a
            // kick() cannot slip between "no job is due" and "we are listening for one".
            guard let wait = secondsUntilNextJob() else { return }
            await waitForJob(seconds: max(wait, 0))
            if Task.isCancelled { return }
        }
    }

    /// Sleep up to `seconds`, or until enqueue/expedite wakes us, whichever comes first.
    private func waitForJob(seconds: TimeInterval) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            // A cancelled sleep throws, and `try?` swallows it — without this check the woken
            // timer would go on to fire anyway and resume the *next* wait's continuation the
            // moment it was installed, which spins the drain loop instead of letting it sleep.
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
        }
        timer.cancel()
    }

    private func timerFired() {
        waiter?.resume()
        waiter = nil
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

    private struct Job {
        let captureId: String
        let stage: Stage
        let attempts: Int
    }

    private func nextDueJob() -> Job? {
        guard let library else { return nil }
        return try? library.db.queue.read { d -> Job? in
            guard let row = try Row.fetchOne(d, sql: """
                SELECT captureId, stage, attempts FROM ingest_jobs
                WHERE notBefore <= ? ORDER BY notBefore LIMIT 1
                """, arguments: [Date()]) else { return nil }
            return Job(captureId: row["captureId"],
                       stage: Stage(rawValue: row["stage"] ?? "") ?? .ocr,
                       attempts: row["attempts"])
        }
    }

    /// Defer this job and count the attempt against the current stage's budget.
    private func retry(_ id: String, after delay: TimeInterval, error: String) async {
        guard let library else { return }
        try? await library.db.queue.write { d in
            try d.execute(sql: """
                UPDATE ingest_jobs SET attempts = attempts + 1, notBefore = ?, lastError = ?
                WHERE captureId = ?
                """, arguments: [Date().addingTimeInterval(delay), error, id])
        }
    }

    /// The record this job is for, if it is still worth working on. Clears the job and returns
    /// nil for anything discarded, sweeping, or of a kind ingest doesn't handle yet.
    private func liveRecord(_ id: String) async -> CaptureRecord? {
        guard let library,
              let record = try? await library.db.queue.read({ d in
                  try CaptureRecord.fetchOne(d, key: id)
              }),
              record.status != .trashed, record.status != .sweeping,
              record.canAnnotate || record.kind == .gif else {   // stills and GIFs only for now
            clearJob(id)
            return nil
        }
        return record
    }

    private func process(_ job: Job) async {
        switch job.stage {
        case .ocr: await ocrStage(job)
        case .name: await nameStage(job)
        }
    }

    // MARK: stage 1 — read the capture and index what it says

    private func ocrStage(_ job: Job) async {
        guard let library, let record = await liveRecord(job.captureId) else { return }

        // Decide up front whether the name stage will want pixels, so this one decode can
        // produce them too. The CGImage never leaves the detached task — only the JPEG does.
        let naming = Settings.shared.aiNamingEnabled
        let wantsAPI = naming && !(Keychain.anthropicKey ?? "").isEmpty
        let url = library.url(for: record)
        let result = await Task.detached(priority: .utility) { () -> (text: String, jpeg: Data?) in
            guard let image = OverlayPosterDecoder.decode(url) else { return ("", nil) }
            return (OCRService.indexText(for: image), wantsAPI ? ImageEncoding.jpegData(image) : nil)
        }.value

        // re-check status: the capture may have been discarded while OCR ran
        guard await liveRecord(job.captureId) != nil else { return }

        if result.text.isEmpty, job.attempts < 2 {
            // transient failures (a file still being written) get one more go
            await retry(job.captureId, after: 20, error: "empty")
            return
        }

        try? library.updateSearchText(job.captureId, ocr: String(result.text.prefix(20_000)))
        try? await library.db.queue.write { d in
            try d.execute(sql: "UPDATE captures SET aiState = ? WHERE id = ?",
                          arguments: [CaptureRecord.AIState.ocr.rawValue, job.captureId])
        }
        Log.store.info("ingest: indexed \(record.relPath, privacy: .public) (\(result.text.count) chars)")

        // Stage 2 — name it from what we just read. Optional: with naming off, captures keep
        // their timestamp names and everything else still works (spec §8).
        guard naming else {
            clearJob(job.captureId)
            return
        }
        pendingJPEG = result.jpeg.map { (job.captureId, $0) }
        try? await library.db.queue.write { d in
            try d.execute(sql: """
                UPDATE ingest_jobs SET stage = 'name', attempts = 0, lastError = NULL
                WHERE captureId = ?
                """, arguments: [job.captureId])
        }
    }

    // MARK: stage 2 — turn that text (and, with a key, the pixels) into a name

    private func nameStage(_ job: Job) async {
        guard let library, let record = await liveRecord(job.captureId) else { return }
        guard Settings.shared.aiNamingEnabled else {   // turned off between the stages
            clearJob(job.captureId)
            return
        }

        let key = Keychain.anthropicKey
        let wantsAPI = !(key ?? "").isEmpty
        let jpeg: Data?
        if let pending = pendingJPEG, pending.id == job.captureId {
            jpeg = pending.data
        } else if wantsAPI {
            // the handoff missed (a restart between the stages): encode once, off this actor
            let url = library.url(for: record)
            jpeg = await Task.detached(priority: .utility) { () -> Data? in
                guard let image = OverlayPosterDecoder.decode(url) else { return nil }
                return ImageEncoding.jpegData(image)
            }.value
        } else {
            jpeg = nil
        }
        pendingJPEG = nil

        let ocr = library.ocrText(job.captureId) ?? ""
        guard let (naming, engine) = await NamingService.best(jpeg: jpeg, ocr: ocr, record: record,
                                                             key: key) else {
            clearJob(job.captureId)
            return
        }
        let applied = library.applyName(job.captureId, baseName: naming.filename, tags: naming.tags,
                                        summary: naming.summary, aiState: engine.aiState)
        // applyName refuses while a drag/save panel holds the path (it must not move a file out
        // from under one). Leave the job in place so a later pass renames it — bounded, so a
        // stuck in-use flag can't spin the queue forever.
        if !applied, Library.isInUse(job.captureId), job.attempts < 5 {
            await retry(job.captureId, after: 30, error: "in use")
            return
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
