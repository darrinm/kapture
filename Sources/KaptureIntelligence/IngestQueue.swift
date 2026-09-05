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
    private var observation: AnyDatabaseCancellable?
    /// Captures wait this long before OCR — a burst-triage discard shouldn't cost any work.
    private let debounce: TimeInterval = 30
    /// Resumed by enqueue/expedite so a job filed while the drain loop sleeps starts at once.
    private var waiter: CheckedContinuation<Void, Never>?
    /// Handoff from the OCR stage to the name stage, which runs moments later in the same drain
    /// pass: the encoded JPEG (~100 KB) rather than a second decode of the full-size capture.
    private var pendingJPEG: (generation: String, data: Data)?

    public func configure(library: Library) {
        self.library = library
        // Edits and journal recovery enqueue transactionally in Core, including saves that
        // leave the editor open. Observe the durable queue so every producer wakes the drain.
        observation = DatabaseRegionObservation(tracking: Table("ingest_jobs"))
            .start(in: library.db.queue,
                   onError: { Log.store.error("ingest observation failed: \($0)") },
                   onChange: { [weak self] _ in Task { await self?.kick() } })
    }

    /// Enqueue a capture for OCR. Safe to call repeatedly; the row is the queue.
    public func enqueue(_ id: String, after delay: TimeInterval? = nil) {
        guard let library else { return }
        let notBefore = Date().addingTimeInterval(delay ?? debounce)
        try? library.enqueueIngest(id, notBefore: notBefore)
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

    public func cancel(_ id: String) {
        try? library?.cancelIngest(id)
    }

    private func clearJob(_ job: IngestJob) {
        if pendingJPEG?.generation == job.generation { pendingJPEG = nil }
        try? library?.clearIngestJob(job)
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
            guard let next = try Date.fetchOne(d, sql: """
                SELECT MIN(notBefore) FROM ingest_jobs
                WHERE captureId NOT IN (SELECT captureId FROM blocked_captures)
                """)
            else { return nil }
            return max(0, next.timeIntervalSinceNow)
        }) ?? nil
    }

    private func nextDueJob() -> IngestJob? { try? library?.nextIngestJob() }

    private func liveRecord(_ job: IngestJob) -> CaptureRecord? {
        do {
            guard let record = try library?.ingestRecord(job), record.canAnnotate || record.kind == .gif else {
                clearJob(job)
                return nil
            }
            return record
        } catch {
            // A failed read/recovery is not a deletion. Retain this generation for retry.
            try? library?.retryIngestJob(job, after: 20, error: "capture temporarily unavailable")
            return nil
        }
    }

    private func process(_ job: IngestJob) async {
        switch job.stage {
        case .ocr: await ocrStage(job)
        case .name: await nameStage(job)
        }
    }

    // MARK: stage 1 — read the capture and index what it says

    private func ocrStage(_ job: IngestJob) async {
        guard let library, let record = liveRecord(job) else { return }

        // Decide up front whether the name stage will want pixels, so this one decode can
        // produce them too. The CGImage never leaves the detached task — only the JPEG does.
        let naming = Settings.shared.aiNamingEnabled && record.aiState.acceptsName
        let wantsAPI = naming && !(Keychain.anthropicKey ?? "").isEmpty
        let url = library.url(for: record)
        let result = await Task.detached(priority: .utility) { () -> (text: String, jpeg: Data?) in
            guard let image = OverlayPosterDecoder.decode(url) else { return ("", nil) }
            return (OCRService.indexText(for: image), wantsAPI ? ImageEncoding.jpegData(image) : nil)
        }.value

        // No re-check here: finishOCR makes the same generation-and-status check inside its own
        // transaction, and a retry for a capture discarded meanwhile updates no row.
        if result.text.isEmpty, job.attempts < 2 {
            // transient failures (a file still being written) get one more go
            try? library.retryIngestJob(job, after: 20, error: "empty")
            return
        }

        do {
            guard try library.finishOCR(job, text: result.text, naming: naming) else { return }
        } catch {
            try? library.retryIngestJob(job, after: 20, error: "index write failed")
            return
        }
        pendingJPEG = naming ? result.jpeg.map { (job.generation, $0) } : nil
    }

    // MARK: stage 2 — turn that text (and, with a key, the pixels) into a name

    private func nameStage(_ job: IngestJob) async {
        guard let library, let record = liveRecord(job) else { return }
        guard Settings.shared.aiNamingEnabled, record.aiState.acceptsName else {   // turned off between the stages
            clearJob(job)
            return
        }

        let key = Keychain.anthropicKey
        let wantsAPI = !(key ?? "").isEmpty
        let jpeg: Data?
        if let pending = pendingJPEG, pending.generation == job.generation {
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

        guard liveRecord(job) != nil else { return }
        let ocr = library.ocrText(job.captureId) ?? ""
        guard let (naming, engine) = await NamingService.best(jpeg: jpeg, ocr: ocr, record: record,
                                                             key: key) else {
            clearJob(job)
            return
        }
        let applied = library.applyName(job.captureId, baseName: naming.filename, tags: naming.tags,
                                        summary: naming.summary, aiState: engine.aiState, job: job)
        // applyName refuses while a drag/save panel holds the path (it must not move a file out
        // from under one). Leave the job in place so a later pass renames it — bounded, so a
        // stuck in-use flag can't spin the queue forever.
        if !applied, Library.isInUse(job.captureId), job.attempts < 5 {
            try? library.retryIngestJob(job, after: 30, error: "in use")
            return
        }
        clearJob(job)
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
