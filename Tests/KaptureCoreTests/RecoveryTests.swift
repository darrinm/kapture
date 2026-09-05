import XCTest
@testable import KaptureCore

final class RecoveryTests: XCTestCase {
    /// Journal a rename of `capture` to `destination` without carrying it out — the state a
    /// crash between the journal row and the move leaves behind.
    private func journalRename(_ lib: Library, _ capture: inout CaptureRecord, to destination: URL) throws {
        let source = capture.relPath
        capture.relPath = lib.rel(destination)
        try lib.journal(FileOperation(op: .rename, source: source, record: capture, sidecar: nil))
    }

    /// A pre-plan journal row, as every shipped build wrote them.
    private func legacyJournal(_ lib: Library, op: FileOperation.Op, id: String, src: String? = nil, dst: String?) throws {
        try lib.db.queue.write { d in
            try d.execute(sql: "INSERT INTO op_journal (op,captureId,src,dst,startedAt) VALUES (?,?,?,?,?)",
                          arguments: [op.rawValue, id, src, dst, Date()])
        }
    }

    /// Nothing can be moved into `dir` until `unlock` — an EACCES, the transient kind.
    private func lock(_ dir: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    }
    private func unlock(_ dir: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
    private func lockedDirectory(_ lib: Library) throws -> URL {
        let dir = lib.root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lock(dir)
        return dir
    }

    func testEveryReplayFailureIsIsolatedAndCanBeRetried() throws {
        for failure in ["collision", "permissions", "missing-edit-source"] {
            let (lib, dir) = try makeLibrary()
            defer { try? FileManager.default.removeItem(at: dir) }
            var broken = try shot(lib)
            let healthy = try shot(lib)
            try lib.enqueueIngest(broken.id, notBefore: Date())
            try lib.enqueueIngest(healthy.id, notBefore: Date())
            let destinationDir = lib.root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            let destination = destinationDir.appendingPathComponent("capture.png")
            switch failure {
            case "missing-edit-source":
                try FileManager.default.removeItem(at: lib.url(for: broken))
                XCTAssertThrowsError(try lib.applyEdit(broken.id, flattenedPNG: Data([9]), layersJSON: "[]", width: 1, height: 1))
            case "collision":
                try journalRename(lib, &broken, to: destination)
                try Data([8]).write(to: destination)
            default:
                try journalRename(lib, &broken, to: destination)
                try lock(destinationDir)
            }
            let reopened = try reopen(lib)
            XCTAssertThrowsError(try reopened.setStatus(broken.id, .kept))
            XCTAssertNoThrow(try shot(reopened))
            let job = try XCTUnwrap(reopened.nextIngestJob())
            XCTAssertEqual(job.captureId, healthy.id)
            XCTAssertTrue(try reopened.finishOCR(job, text: "healthy", naming: false))
            XCTAssertEqual(try reopened.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ingest_jobs WHERE captureId = ?", arguments: [broken.id]) }, 1)
            switch failure {
            case "missing-edit-source": try Data([1, 2, 3]).write(to: lib.url(for: broken))
            case "collision": try FileManager.default.removeItem(at: destination)
            default: try unlock(destinationDir)
            }
            try reopened.retryRecovery(for: broken.id)
            XCTAssertNoThrow(try reopened.setStatus(broken.id, .kept))
            XCTAssertEqual(try journalCount(reopened, where: "captureId = '\(broken.id)'"), 0)
        }
    }

    func testUnreadableSidecarMovesVerbatimThroughRenameDiscardAndRestore() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        try lib.applyEdit(capture.id, flattenedPNG: Data([9]), layersJSON: "[layers]", width: 1, height: 1)
        let initial = Sidecar.url(for: lib.url(for: capture))
        let bytes = try Data(contentsOf: initial)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: initial.path)
        XCTAssertNil(Sidecar.read(for: lib.url(for: capture)))
        XCTAssertTrue(lib.applyName(capture.id, baseName: "renamed", tags: [], summary: "", aiState: .namedLocal))
        try lib.discard(record(lib, capture.id))
        let restored = try XCTUnwrap(lib.restore(id: capture.id))
        let sidecar = Sidecar.url(for: lib.url(for: restored))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: sidecar.path)[.posixPermissions] as? NSNumber)?.intValue, 0)
        XCTAssertThrowsError(try lib.applyEdit(capture.id, flattenedPNG: Data([8]), layersJSON: "[]", width: 1, height: 1))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
        XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        XCTAssertEqual(try Data(contentsOf: lib.editBase(for: restored).image), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: lib.url(for: restored)), Data([9]))
    }

    func testUnjournaledStagesAreRemovedAfterInsertFailureAndRestart() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        let trimmed = dir.appendingPathComponent("trimmed.mp4")
        try Data(repeating: 7, count: 4 * 1024 * 1024).write(to: trimmed)
        try lib.db.queue.write { d in
            try d.execute(sql: "CREATE TEMP TRIGGER fail_insert BEFORE INSERT ON op_journal BEGIN SELECT RAISE(FAIL, 'journal unavailable'); END")
        }
        XCTAssertThrowsError(try shot(lib))
        XCTAssertThrowsError(try lib.applyTrim(capture.id, trimmedURL: trimmed, duration: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trimmed.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lib.root.appendingPathComponent(".pending").path), [])
        try lib.db.queue.write { try $0.execute(sql: "DROP TRIGGER fail_insert") }
        let orphan = try lib.stageData(Data([5]))
        let retained = try lib.stageData(Data([6]))
        var blocked = capture
        blocked.relPath = "collision.png"
        try Data([8]).write(to: lib.url(for: blocked))
        try lib.journal(FileOperation(op: .write, source: lib.rel(retained), record: blocked, sidecar: nil))
        // Only the instance holding the root sweeps .pending — the app at launch.
        let reopened = try reopen(lib, exclusive: true)
        XCTAssertEqual(try journalCount(reopened, where: "recoveryError IS NOT NULL"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let sources = try reopened.db.queue.read { try String.fetchAll($0, sql: "SELECT src FROM op_journal") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path), "retained=\(lib.rel(retained)); journal=\(sources)")
    }

    func testSweepPreservesLegacyOriginalUntilItsLastReferentIsGone() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try shot(lib), second = try shot(lib)
        let shared = lib.root.appendingPathComponent(".originals/2026/09/reused-name.png")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: shared)
        for capture in [first, second] {
            var sidecar = try XCTUnwrap(Sidecar.read(for: lib.url(for: capture)))
            sidecar.annotations = .init(original: lib.rel(shared), layersJSON: "[]")
            try sidecar.write(next: lib.url(for: capture))
        }
        try lib.discard(first)
        lib.sweepTrash(olderThanDays: -1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertEqual(try Data(contentsOf: lib.editBase(for: second).image), Data([1, 2, 3]))
        try lib.discard(second)
        lib.sweepTrash(olderThanDays: -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
    }

    func testSweepChecksSidecarMovedByAnUncommittedRename() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try shot(lib), second = try shot(lib)
        let shared = lib.root.appendingPathComponent(".originals/shared.png")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: shared)
        for capture in [first, second] {
            var sidecar = try XCTUnwrap(Sidecar.read(for: lib.url(for: capture)))
            sidecar.annotations = .init(original: lib.rel(shared), layersJSON: "[]")
            try sidecar.write(next: lib.url(for: capture))
        }
        try lib.discard(first)
        try lib.db.queue.write { d in
            try d.execute(sql: "CREATE TEMP TRIGGER fail_rename BEFORE UPDATE ON captures WHEN OLD.id = '\(second.id)' BEGIN SELECT RAISE(FAIL, 'commit failure'); END")
        }
        XCTAssertFalse(lib.applyName(second.id, baseName: "moved", tags: [], summary: "", aiState: .namedLocal))
        lib.sweepTrash(olderThanDays: -1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.url(for: lib.url(for: second)).path))
        XCTAssertNil(try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: first.id) })
        try lib.db.queue.write { try $0.execute(sql: "DROP TRIGGER fail_rename") }
        try lib.retryRecovery(for: second.id)
        let recovered = try record(lib, second.id)
        XCTAssertEqual(try Data(contentsOf: lib.editBase(for: recovered).image), Data([1]))
    }

    func testUntouchedLegacyEditsDoNotInvalidateSearchOrShares() throws {
        for op in [FileOperation.Op.flatten, .trim] {
            let (lib, dir) = try makeLibrary()
            defer { try? FileManager.default.removeItem(at: dir) }
            let capture = try shot(lib)
            XCTAssertTrue(lib.applyName(capture.id, baseName: "invoice", tags: ["stripe"], summary: "invoice", aiState: .namedAPI))
            let named = try record(lib, capture.id)
            try lib.updateSearchText(named.id, ocr: "paid")
            try lib.setShareLink(named.id, url: "https://kapture.sh/existing", revision: named.contentRevision)
            try legacyJournal(lib, op: op, id: named.id, src: named.relPath, dst: named.relPath)
            let reopened = try reopen(lib)
            let recovered = try record(reopened, named.id)
            XCTAssertEqual(recovered.contentRevision, named.contentRevision)
            XCTAssertFalse(recovered.shareStale)
            XCTAssertEqual(recovered.aiState, .namedAPI)
            XCTAssertEqual(reopened.search("stripe").count, 1)
            XCTAssertEqual(reopened.search("paid").count, 1)
        }
    }

    func testConcurrentLegacyMovieRecoveryDoesNotWaitForAsyncMetadata() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let (lib, dir) = try self.makeLibrary()
                    defer { try? FileManager.default.removeItem(at: dir) }
                    let file = lib.root.appendingPathComponent("legacy.mp4")
                    // Even malformed media must not block recovery waiting for a metadata task.
                    try Data([1, 2, 3]).write(to: file)
                    try self.legacyJournal(lib, op: .write, id: "legacy", dst: "legacy.mp4")
                    let reopened = try self.reopen(lib)
                    XCTAssertEqual(try self.record(reopened, "legacy").kind, .recording)
                    XCTAssertNoThrow(try self.shot(reopened))
                }
            }
            try await group.waitForAll()
        }
    }

    func testFinderDeletedCaptureCanStillBeDiscardedAndSwept() throws {
        for restartFirst in [false, true] {
            let (lib, dir) = try makeLibrary()
            defer { try? FileManager.default.removeItem(at: dir) }
            let missing = try shot(lib)
            try FileManager.default.removeItem(at: lib.url(for: missing))
            let usable = restartFirst ? try reopen(lib) : lib
            // The end state the user asked for — row trashed, file gone — needs no file.
            XCTAssertNoThrow(try usable.discard(missing))
            XCTAssertEqual(try record(usable, missing.id).status, .trashed)
            XCTAssertEqual(try journalCount(usable), 0)
            // Restoring it is the honest failure: said once, and the capture is not parked.
            XCTAssertThrowsError(try usable.restore(id: missing.id)) { XCTAssertTrue($0 is FileVanished, "\($0)") }
            XCTAssertEqual(try record(usable, missing.id).status, .trashed)
            XCTAssertEqual(try journalCount(usable), 0)
            XCTAssertNoThrow(try usable.setStatus(missing.id, .trashed))
            usable.sweepTrash(olderThanDays: -1)
            XCTAssertNil(try usable.db.queue.read { try CaptureRecord.fetchOne($0, key: missing.id) })
            XCTAssertNoThrow(try shot(try reopen(usable)))
        }
    }

    func testARowLeftByADeletedFileDoesNotClaimTheNextCapturesName() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try shot(lib), other = try shot(lib)
        XCTAssertTrue(lib.applyName(first.id, baseName: "ghost", tags: [], summary: "", aiState: .namedLocal))
        let ghost = try record(lib, first.id)
        try FileManager.default.removeItem(at: lib.url(for: ghost))
        try FileManager.default.removeItem(at: Sidecar.url(for: lib.url(for: ghost)))
        // Same directory, same name: the filesystem says free, the row says taken.
        XCTAssertTrue(lib.applyName(other.id, baseName: "ghost", tags: [], summary: "", aiState: .namedLocal))
        let renamed = try record(lib, other.id)
        XCTAssertNotEqual(renamed.relPath, ghost.relPath)
        XCTAssertTrue(renamed.relPath.hasSuffix("ghost-2.png"), renamed.relPath)
        XCTAssertEqual(try journalCount(lib), 0)
    }

    func testAPendingPlansDestinationIsAlsoATakenName() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        var waiting = try shot(lib)
        let other = try shot(lib)
        // A rename to "claimed" is journaled but backing off: no file there yet, no row yet.
        let lockedDir = try lockedDirectory(lib)
        try journalRename(lib, &waiting, to: lockedDir.appendingPathComponent("claimed.png"))
        try lib.recoverPendingOperations()
        try unlock(lockedDir)
        // Nothing else may take that name meanwhile, or the replay collides and is quarantined.
        try FileManager.default.moveItem(at: lib.url(for: other), to: lockedDir.appendingPathComponent("other.png"))
        try lib.db.queue.write { try $0.execute(sql: "UPDATE captures SET relPath = ? WHERE id = ?",
                                                 arguments: [lib.rel(lockedDir.appendingPathComponent("other.png")), other.id]) }
        XCTAssertTrue(lib.applyName(other.id, baseName: "claimed", tags: [], summary: "", aiState: .namedLocal))
        XCTAssertTrue(try record(lib, other.id).relPath.hasSuffix("claimed-2.png"))
    }

    func testAUniqueConstraintOnReplayIsQuarantinedNotRetriedForever() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghost = try shot(lib)
        var other = try shot(lib)
        try FileManager.default.removeItem(at: lib.url(for: ghost))
        // A plan that bypassed availableURL, as an older build's could have.
        try journalRename(lib, &other, to: lib.url(for: ghost))
        let reopened = try reopen(lib)
        XCTAssertEqual(try journalCount(reopened, where: "recoveryError IS NOT NULL"), 1)
        XCTAssertThrowsError(try reopened.setStatus(other.id, .kept)) {
            XCTAssertEqual(($0 as? RecoveryBlocked)?.quarantined, true)
        }
    }

    func testFinishingAReplayPullsTheCapturesIngestJobForward() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        var capture = try shot(lib)
        try lib.enqueueIngest(capture.id, notBefore: Date().addingTimeInterval(3600))
        let lockedDir = try lockedDirectory(lib)
        try journalRename(lib, &capture, to: lockedDir.appendingPathComponent("capture.png"))
        let reopened = try reopen(lib)
        XCTAssertNil(try reopened.nextIngestJob(), "hidden while the capture is blocked")
        try unlock(lockedDir)
        try reopened.db.queue.write { try $0.execute(sql: "UPDATE op_journal SET nextAttemptAt = NULL") }
        XCTAssertNoThrow(try shot(reopened))   // any operation replays it
        // The drain loop may have gone to sleep with nothing to wait for; the job it could not
        // see is due now, not in an hour.
        XCTAssertEqual(try reopened.nextIngestJob()?.captureId, capture.id)
    }

    func testSweepKeepsALegacyOriginalAndItsRowWhileAnotherSidecarIsUnreadable() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = try shot(lib), bystander = try shot(lib)
        let shared = lib.root.appendingPathComponent(".originals/2026/09/legacy-name.png")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: shared)
        var sidecar = try XCTUnwrap(Sidecar.read(for: lib.url(for: legacy)))
        sidecar.annotations = .init(original: lib.rel(shared), layersJSON: "[]")
        try sidecar.write(next: lib.url(for: legacy))
        let bystanderSidecar = Sidecar.url(for: lib.url(for: bystander))
        let good = try Data(contentsOf: bystanderSidecar)
        try Data("not json".utf8).write(to: bystanderSidecar)
        try lib.discard(legacy)
        lib.sweepTrash(olderThanDays: -1)
        // Undecidable: nothing deleted, and the row stays so its sidecar still names the original.
        XCTAssertEqual(try record(lib, legacy.id).status, .trashed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        try good.write(to: bystanderSidecar)
        lib.sweepTrash(olderThanDays: -1)
        XCTAssertNil(try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: legacy.id) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
    }

    func testRecoveryContinuesPastMissingLegacyEntryAndCorruptPlan() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = try shot(lib)
        try FileManager.default.removeItem(at: lib.url(for: missing))
        try legacyJournal(lib, op: .discard, id: missing.id, src: missing.relPath, dst: ".trash/missing.png")
        try lib.db.queue.write { d in
            try d.execute(sql: "INSERT INTO op_journal (op,captureId,startedAt,plan) VALUES ('write','corrupt',?,?)",
                          arguments: [Date(), Data("not JSON".utf8)])
        }
        let staged = try lib.stageData(Data([9]))
        let pending = CaptureRecord(kind: .screenshot, width: 1, height: 1, bytes: 1, relPath: "healthy.png", fastID: "")
        try lib.journal(FileOperation(op: .write, source: lib.rel(staged), record: pending, sidecar: nil))
        let reopened = try reopen(lib)
        XCTAssertEqual(try Data(contentsOf: reopened.url(for: record(reopened, pending.id))), Data([9]))
        // The legacy discard finished without its file; only the corrupt plan needs a human.
        XCTAssertEqual(try record(reopened, missing.id).status, .trashed)
        XCTAssertEqual(try journalCount(reopened, where: "recoveryError IS NOT NULL"), 1)
        XCTAssertEqual(try journalCount(reopened, where: "recoveryError IS NULL"), 0)
    }

    func testRestartFinishesAWriteBeforeOrAfterItsFileMove() throws {
        for moved in [false, true] {
            let (lib, dir) = try makeLibrary()
            defer { try? FileManager.default.removeItem(at: dir) }
            let staged = try lib.stageData(Data([4, 5, 6]))
            let pending = CaptureRecord(kind: .screenshot, width: 3, height: 4, bytes: 3,
                                        relPath: "recovered.png", fastID: "")
            let sidecar = Sidecar(id: pending.id, created: pending.createdAt, app: "test", window: nil)
            try lib.journal(FileOperation(op: .write, source: lib.rel(staged), record: pending, sidecar: sidecar))
            if moved { try FileManager.default.moveItem(at: staged, to: lib.url(for: pending)) }
            let reopened = try reopen(lib)
            XCTAssertEqual(try record(reopened, pending.id).width, 3)
            XCTAssertEqual(Sidecar.read(for: reopened.url(for: pending))?.id, pending.id)
            XCTAssertEqual(try Data(contentsOf: reopened.url(for: pending)), Data([4, 5, 6]))
            try reopened.recoverPendingOperations()
            XCTAssertEqual(reopened.search().count, 1)
            XCTAssertEqual(try journalCount(lib), 0)
            // The caller that would have enqueued OCR never returned; recovery owes it one.
            XCTAssertEqual(try reopened.nextIngestJob()?.captureId, pending.id)
        }
    }

    func testRestartCompletesEditAfterPixelsChangedBeforeSidecarOrDatabase() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        var capture = try shot(lib)
        try lib.updateSearchText(capture.id, ocr: "secret")
        try lib.setShareLink(capture.id, url: "https://kapture.sh/old", revision: 0)
        capture = try record(lib, capture.id)
        let original = try lib.originalPath(for: capture)
        let originalURL = lib.root.appendingPathComponent(original)
        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: lib.url(for: capture), to: originalURL)
        let staged = try lib.stageData(Data([9, 8]))
        var sidecar = try XCTUnwrap(Sidecar.read(for: lib.url(for: capture)))
        sidecar.annotations = .init(original: original, layersJSON: "[redaction]")
        capture.contentRevision += 1; capture.width = 5; capture.height = 6
        capture.shareStale = true; capture.summary = nil
        try lib.journal(FileOperation(op: .flatten, source: lib.rel(staged), record: capture, sidecar: sidecar))
        _ = try FileManager.default.replaceItemAt(lib.url(for: capture), withItemAt: staged)
        let reopened = try reopen(lib)
        let recovered = try record(reopened, capture.id)
        XCTAssertEqual(recovered.contentRevision, 1)
        XCTAssertEqual(recovered.width, 5)
        XCTAssertEqual(recovered.bytes, 2)
        XCTAssertTrue(recovered.shareStale)
        XCTAssertTrue(reopened.search("secret").isEmpty)
        XCTAssertEqual(Sidecar.read(for: reopened.url(for: recovered))?.annotations?.layersJSON, "[redaction]")
        XCTAssertEqual(try Data(contentsOf: reopened.editBase(for: recovered).image), Data([1, 2, 3]))
        XCTAssertEqual(try reopened.nextIngestJob()?.stage, .ocr)
    }

    func testRestartCompletesDiscardAndRestoreWithTheSidecarLeftAtSource() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        var capture = try shot(lib)
        let initial = capture.relPath
        let source = lib.url(for: capture)
        let sidecar = Sidecar.read(for: source)
        capture.relPath = ".trash/interrupted.png"; capture.status = .trashed; capture.trashedAt = Date()
        try FileManager.default.createDirectory(at: lib.trashDir, withIntermediateDirectories: true)
        try lib.journal(FileOperation(op: .discard, source: initial, record: capture, sidecar: sidecar,
                                      originalRelPath: initial))
        try FileManager.default.moveItem(at: source, to: lib.url(for: capture))
        let reopened = try reopen(lib)
        XCTAssertEqual(try record(reopened, capture.id).status, .trashed)
        XCTAssertNotNil(Sidecar.read(for: reopened.url(for: capture)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.url(for: source).path))
        let trashPath = capture.relPath
        capture.relPath = initial; capture.status = .kept; capture.trashedAt = nil
        try reopened.journal(FileOperation(op: .restore, source: trashPath, record: capture, sidecar: sidecar))
        try FileManager.default.moveItem(at: reopened.root.appendingPathComponent(trashPath), to: source)
        let restored = try reopen(reopened)
        XCTAssertEqual(try record(restored, capture.id).status, .kept)
        XCTAssertNotNil(Sidecar.read(for: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.tombstoneURL(capture.id).path))
    }

    func testActualEditRecoversAfterTheDatabaseCommitFails() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        try lib.updateSearchText(capture.id, ocr: "secret")
        try lib.db.queue.write { d in
            try d.execute(sql: """
                CREATE TEMP TRIGGER fail_commit BEFORE UPDATE ON captures
                BEGIN SELECT RAISE(FAIL, 'simulated commit failure'); END
                """)
        }
        XCTAssertThrowsError(try lib.applyEdit(capture.id, flattenedPNG: Data([9]), layersJSON: "[redacted]",
                                              width: 2, height: 3))
        XCTAssertEqual(try record(lib, capture.id).contentRevision, 0)
        XCTAssertEqual(try Data(contentsOf: lib.url(for: capture)), Data([9]))
        try lib.db.queue.write { try $0.execute(sql: "DROP TRIGGER fail_commit") }
        let reopened = try reopen(lib)
        XCTAssertEqual(try record(reopened, capture.id).contentRevision, 1)
        XCTAssertEqual(try record(reopened, capture.id).width, 2)
        XCTAssertTrue(reopened.search("secret").isEmpty)
        XCTAssertEqual(try Data(contentsOf: reopened.editBase(for: record(reopened, capture.id)).image), Data([1, 2, 3]))
    }

    func testRestoreAvoidsSidecarCollisionsWithAnotherMediaType() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        let original = lib.url(for: capture)
        try lib.discard(capture)
        let other = original.deletingPathExtension().appendingPathExtension("gif")
        try Data([7]).write(to: other)
        try Sidecar(id: "other", created: Date(), app: nil, window: nil).write(next: other)
        let restored = try XCTUnwrap(lib.restore(id: capture.id))
        XCTAssertNotEqual(restored.relPath, capture.relPath)
        XCTAssertEqual(Sidecar.read(for: other)?.id, "other")
    }

    func testLegacyRenameJournalIsRecoveredOnLaunch() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        let target = lib.root.appendingPathComponent("renamed.png")
        try legacyJournal(lib, op: .rename, id: capture.id, src: capture.relPath, dst: "renamed.png")
        try FileManager.default.moveItem(at: lib.url(for: capture), to: target)
        let reopened = try reopen(lib)
        XCTAssertEqual(try record(reopened, capture.id).relPath, "renamed.png")
        XCTAssertEqual(reopened.search("renamed").count, 1)
        XCTAssertNotNil(Sidecar.read(for: target))
    }

    func testSweepRemovesOriginalAndRetriesEachFailureBoundary() throws {
        for failedPart in ["original", "capture", "sidecar", "tombstone"] {
            let (lib, dir) = try makeLibrary()
            defer { try? FileManager.default.removeItem(at: dir) }
            let capture = try shot(lib)
            try lib.applyEdit(capture.id, flattenedPNG: Data([4]), layersJSON: "[]", width: 1, height: 1)
            let edited = try record(lib, capture.id)
            let original = lib.editBase(for: edited).image
            try lib.discard(edited)
            let trashed = try record(lib, capture.id)
            let file = lib.url(for: trashed)
            let failures = ["original": original, "capture": file,
                            "sidecar": Sidecar.url(for: file), "tombstone": lib.tombstoneURL(capture.id)]
            lib.sweepTrash(olderThanDays: -1) { url in
                if url == failures[failedPart] { throw CocoaError(.fileWriteNoPermission) }
                try lib.removeIfPresent(url)
            }
            XCTAssertEqual(try record(lib, capture.id).status, .sweeping, failedPart)
            // A restart must keep the failed item discoverable, even if the media/sidecar is gone.
            let reopened = try reopen(lib)
            reopened.sweepTrash()
            XCTAssertNil(try reopened.db.queue.read { try CaptureRecord.fetchOne($0, key: capture.id) })
            for url in failures.values { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path) }
        }
    }

    func testRestoreRepeatedCollisionsPreservesMovieAndGIFExtensions() throws {
        for ext in ["mp4", "gif"] {
            let (lib, dir) = try makeLibrary()
            defer { try? FileManager.default.removeItem(at: dir) }
            let temp = dir.appendingPathComponent("movie.\(ext)")
            try Data([1, 2]).write(to: temp)
            let (capture, file) = try lib.storeMovie(from: temp, width: 4, height: 6, duration: 2,
                                                    sourceApp: nil, ext: ext, kind: ext == "gif" ? .gif : .recording)
            try lib.discard(capture)
            try Data([9]).write(to: file)
            let collision = file.deletingLastPathComponent()
                .appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-2").appendingPathExtension(ext)
            try Data([8]).write(to: collision)
            let restored = try XCTUnwrap(lib.restore(id: capture.id))
            let restoredURL = lib.url(for: restored)
            XCTAssertEqual(restoredURL.pathExtension, ext)
            XCTAssertTrue(restoredURL.deletingPathExtension().lastPathComponent.hasSuffix("-3"))
            XCTAssertEqual(try Data(contentsOf: restoredURL), Data([1, 2]))
            XCTAssertEqual(try Data(contentsOf: file), Data([9]))
            XCTAssertEqual(try Data(contentsOf: collision), Data([8]))
        }
    }

    // MARK: replay failures are classified, not all parked

    func testTransientReplayFailureBacksOffAndHealsOnItsOwn() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        var capture = try shot(lib)
        let lockedDir = try lockedDirectory(lib)
        try journalRename(lib, &capture, to: lockedDir.appendingPathComponent("capture.png"))

        let reopened = try reopen(lib)
        // Waiting, not parked — and the capture is blocked meanwhile, with the reason attached.
        XCTAssertEqual(try journalCount(reopened, where: "recoveryError IS NOT NULL"), 0)
        XCTAssertEqual(try reopened.db.queue.read { try Int.fetchOne($0, sql: "SELECT attempts FROM op_journal") }, 1)
        XCTAssertNotNil(try reopened.db.queue.read { try Date.fetchOne($0, sql: "SELECT nextAttemptAt FROM op_journal") })
        XCTAssertThrowsError(try reopened.setStatus(capture.id, .kept)) { error in
            XCTAssertEqual((error as? RecoveryBlocked)?.quarantined, false)
        }
        // The permission arrives. Once the backoff elapses, the next operation on anything
        // finishes it — no retryRecovery, no relaunch, no hand-edited row.
        try unlock(lockedDir)
        try reopened.db.queue.write { try $0.execute(sql: "UPDATE op_journal SET nextAttemptAt = NULL") }
        XCTAssertNoThrow(try reopened.setStatus(capture.id, .kept))
        XCTAssertEqual(try journalCount(reopened), 0)
        XCTAssertEqual(try record(reopened, capture.id).relPath, capture.relPath)
    }

    func testPermanentReplayFailureIsQuarantinedAndSaysSo() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        var capture = try shot(lib)
        let taken = lib.root.appendingPathComponent("taken.png")
        try Data([8]).write(to: taken)
        try journalRename(lib, &capture, to: taken)
        let reopened = try reopen(lib)
        XCTAssertEqual(try journalCount(reopened, where: "recoveryError IS NOT NULL"), 1)
        XCTAssertThrowsError(try reopened.setStatus(capture.id, .kept)) { error in
            XCTAssertEqual((error as? RecoveryBlocked)?.quarantined, true)
            XCTAssertTrue(error.localizedDescription.contains("needs attention"))
        }
        // A name collision is not retried behind the user's back, however many operations pass.
        XCTAssertNoThrow(try shot(reopened))
        XCTAssertEqual(try reopened.db.queue.read { try Int.fetchOne($0, sql: "SELECT attempts FROM op_journal") }, 0)
        XCTAssertEqual(try Data(contentsOf: taken), Data([8]))
    }

    func testLegacyWriteWithACorruptSidecarStillGetsARow() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = lib.root.appendingPathComponent("legacy.png")
        try Data([1, 2, 3]).write(to: file)
        try Data("not json".utf8).write(to: Sidecar.url(for: file))
        try legacyJournal(lib, op: .write, id: "legacy", dst: "legacy.png")
        let reopened = try reopen(lib)
        XCTAssertEqual(try record(reopened, "legacy").relPath, "legacy.png")
        XCTAssertEqual(Sidecar.read(for: file)?.id, "legacy", "synthesised, as the old build would have written it")
        XCTAssertEqual(try journalCount(reopened), 0)
    }

    // MARK: sweep decides before it marks

    func testSweepWithAnUnreadableSidecarKeepsTheOriginalAndSweepsTheRest() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        try lib.applyEdit(capture.id, flattenedPNG: Data([4]), layersJSON: "[]", width: 1, height: 1)
        let original = lib.editBase(for: try record(lib, capture.id)).image
        try lib.discard(try record(lib, capture.id))
        let trashed = try record(lib, capture.id)
        let sidecar = Sidecar.url(for: lib.url(for: trashed))
        try Data("not json".utf8).write(to: sidecar)
        lib.sweepTrash(olderThanDays: -1)
        // Swept, not stuck at 'sweeping': row and file gone; the original we could not vouch
        // for stays on disk.
        XCTAssertNil(try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: capture.id) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.url(for: trashed).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testSweepDeletesAnIdKeyedOriginalDespiteACorruptSidecarElsewhere() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib), bystander = try shot(lib)
        try Data("not json".utf8).write(to: Sidecar.url(for: lib.url(for: bystander)))
        try lib.applyEdit(capture.id, flattenedPNG: Data([4]), layersJSON: "[]", width: 1, height: 1)
        let original = lib.editBase(for: try record(lib, capture.id)).image
        XCTAssertEqual(lib.rel(original), Library.ownOriginalPath(id: capture.id, ext: "png"))
        try lib.discard(try record(lib, capture.id))
        lib.sweepTrash(olderThanDays: -1)
        // An id-keyed original is nobody else's by construction, so the bystander's unreadable
        // sidecar — which would make a legacy referent scan say "unknown" — never comes into it.
        XCTAssertNil(try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: capture.id) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertNotNil(try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: bystander.id) })
    }

    // MARK: one process per root

    func testExclusiveLibraryRefusesASecondOpenerOnTheSameRoot() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = try Library(db: lib.db, root: lib.root, exclusive: true)
        XCTAssertThrowsError(try Library(db: Database(directory: dir.appendingPathComponent("db2")),
                                         root: lib.root, exclusive: true)) { error in
            XCTAssertTrue(error is LibraryBusy, "\(error)")
        }
        // An opener that did not ask for exclusivity — a test's reopen — is still allowed.
        XCTAssertNoThrow(try Library(db: lib.db, root: lib.root))
        withExtendedLifetime(held) {}
    }

    func testRenameBetweenEditsKeepsTheSameOriginal() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        try lib.applyEdit(capture.id, flattenedPNG: Data([4]), layersJSON: "[]", width: 1, height: 1)
        XCTAssertTrue(lib.applyName(capture.id, baseName: "renamed", tags: [], summary: "", aiState: .namedLocal))
        try lib.applyEdit(capture.id, flattenedPNG: Data([5]), layersJSON: "[]", width: 1, height: 1)
        let edited = try record(lib, capture.id)
        XCTAssertEqual(try Data(contentsOf: lib.editBase(for: edited).image), Data([1, 2, 3]))
    }
}
