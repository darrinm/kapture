import XCTest
@testable import KaptureCore

final class RecoveryTests: XCTestCase {
    private func library() throws -> (Library, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try Database(directory: dir.appendingPathComponent("db"))
        return (try Library(db: db, root: dir.appendingPathComponent("files")), dir)
    }

    private func shot(_ lib: Library) throws -> CaptureRecord {
        try lib.storePNG(Data([1, 2, 3]), width: 10, height: 20,
                         sourceApp: "test", windowTitle: nil, screenID: nil).0
    }

    private func record(_ lib: Library, _ id: String) throws -> CaptureRecord {
        try XCTUnwrap(lib.db.queue.read { try CaptureRecord.fetchOne($0, key: id) })
    }

    private func journal(_ lib: Library, _ plan: FileOperation) throws {
        let data = try JSONEncoder().encode(plan)
        try lib.db.queue.write { d in
            try d.execute(sql: "INSERT INTO op_journal (op,captureId,src,dst,startedAt,plan) VALUES (?,?,?,?,?,?)",
                          arguments: [plan.op, plan.record.id, plan.source, plan.record.relPath, Date(), data])
        }
    }

    private func reopen(_ lib: Library) throws -> Library {
        try Library(db: Database(directory: lib.root.deletingLastPathComponent().appendingPathComponent("db")), root: lib.root)
    }

    func testEveryReplayFailureIsIsolatedAndCanBeRetried() throws {
        for failure in ["collision", "permissions", "missing-edit-source"] {
            let (lib, dir) = try library()
            defer { try? FileManager.default.removeItem(at: dir) }
            var broken = try shot(lib)
            let healthy = try shot(lib)
            try lib.enqueueIngest(broken.id, notBefore: Date())
            try lib.enqueueIngest(healthy.id, notBefore: Date())
            let destinationDir = lib.root.appendingPathComponent("destination")
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destinationDir.path) }
            let destination = destinationDir.appendingPathComponent("capture.png")
            if failure == "missing-edit-source" {
                try FileManager.default.removeItem(at: lib.url(for: broken))
                XCTAssertThrowsError(try lib.applyEdit(broken.id, flattenedPNG: Data([9]), layersJSON: "[]", width: 1, height: 1))
            } else {
                let source = broken.relPath
                broken.relPath = lib.rel(destination)
                try journal(lib, FileOperation(op: "rename", source: source, record: broken, sidecar: nil))
                if failure == "collision" { try Data([8]).write(to: destination) }
                else { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destinationDir.path) }
            }
            let reopened = try reopen(lib)
            XCTAssertThrowsError(try reopened.setStatus(broken.id, .kept))
            XCTAssertNoThrow(try shot(reopened))
            let job = try XCTUnwrap(reopened.nextIngestJob())
            XCTAssertEqual(job.captureId, healthy.id)
            XCTAssertTrue(try reopened.finishOCR(job, text: "healthy", naming: false))
            XCTAssertEqual(try reopened.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ingest_jobs WHERE captureId = ?", arguments: [broken.id]) }, 1)
            if failure == "collision" { try FileManager.default.removeItem(at: destination) }
            if failure == "permissions" { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destinationDir.path) }
            if failure == "missing-edit-source" {
                try Data([1, 2, 3]).write(to: lib.url(for: broken))
            }
            try reopened.retryRecovery(for: broken.id)
            XCTAssertNoThrow(try reopened.setStatus(broken.id, .kept))
            XCTAssertEqual(try reopened.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM op_journal WHERE captureId = ?", arguments: [broken.id]) }, 0)
        }
    }

    func testUnreadableSidecarMovesVerbatimThroughRenameDiscardAndRestore() throws {
        let (lib, dir) = try library()
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
        let (lib, dir) = try library()
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
        try journal(lib, FileOperation(op: "write", source: lib.rel(retained), record: blocked, sidecar: nil))
        let reopened = try reopen(lib)
        XCTAssertEqual(try reopened.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM op_journal WHERE recoveryError IS NOT NULL") }, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let sources = try reopened.db.queue.read { try String.fetchAll($0, sql: "SELECT src FROM op_journal") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path), "retained=\(lib.rel(retained)); journal=\(sources)")
    }

    func testSweepPreservesLegacyOriginalUntilItsLastReferentIsGone() throws {
        let (lib, dir) = try library()
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
        let (lib, dir) = try library()
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
        for op in ["flatten", "trim"] {
            let (lib, dir) = try library()
            defer { try? FileManager.default.removeItem(at: dir) }
            let capture = try shot(lib)
            XCTAssertTrue(lib.applyName(capture.id, baseName: "invoice", tags: ["stripe"], summary: "invoice", aiState: .namedAPI))
            let named = try record(lib, capture.id)
            try lib.updateSearchText(named.id, ocr: "paid")
            try lib.setShareLink(named.id, url: "https://kapture.sh/existing", revision: named.contentRevision)
            try lib.db.queue.write { d in
                try d.execute(sql: "INSERT INTO op_journal (op,captureId,src,dst,startedAt) VALUES (?,?,?,?,?)",
                              arguments: [op, named.id, named.relPath, named.relPath, Date()])
            }
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
                    let (lib, dir) = try self.library()
                    defer { try? FileManager.default.removeItem(at: dir) }
                    let file = lib.root.appendingPathComponent("legacy.mp4")
                    // Even malformed media must not block recovery waiting for a metadata task.
                    try Data([1, 2, 3]).write(to: file)
                    try lib.db.queue.write { d in
                        try d.execute(sql: "INSERT INTO op_journal (op,captureId,dst,startedAt) VALUES ('write','legacy','legacy.mp4',?)", arguments: [Date()])
                    }
                    let reopened = try self.reopen(lib)
                    XCTAssertEqual(try self.record(reopened, "legacy").kind, .recording)
                    XCTAssertNoThrow(try self.shot(reopened))
                }
            }
            try await group.waitForAll()
        }
    }

    func testFinderDeletedCaptureDoesNotBlockOperationsOrRestart() throws {
        for restartFirst in [false, true] {
            let (lib, dir) = try library()
            defer { try? FileManager.default.removeItem(at: dir) }
            let missing = try shot(lib)
            try FileManager.default.removeItem(at: lib.url(for: missing))
            XCTAssertThrowsError(try lib.discard(missing))

            let usable = restartFirst ? try reopen(lib) : lib
            let unrelated = try shot(usable)
            try usable.discard(unrelated)
            XCTAssertNotNil(try usable.restore(id: unrelated.id))
            let reopened = try reopen(usable)
            XCTAssertNotNil(try shot(reopened))
            // Keep the failed plan and the old sidecar, but never replay it automatically.
            let errors = try reopened.db.queue.read { d in
                try String.fetchAll(d, sql: "SELECT recoveryError FROM op_journal WHERE captureId = ?",
                                    arguments: [missing.id])
            }
            XCTAssertEqual(errors.count, 1)
            XCTAssertFalse(errors[0].isEmpty)
            XCTAssertNotNil(Sidecar.read(for: lib.url(for: missing)))
            XCTAssertEqual(try record(reopened, missing.id).relPath, missing.relPath)
        }
    }

    func testRecoveryContinuesPastMissingLegacyEntryAndCorruptPlan() throws {
        let (lib, dir) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = try shot(lib)
        try FileManager.default.removeItem(at: lib.url(for: missing))
        try lib.db.queue.write { d in
            try d.execute(sql: "INSERT INTO op_journal (op,captureId,src,dst,startedAt) VALUES ('discard',?,?,?,?)",
                          arguments: [missing.id, missing.relPath, ".trash/missing.png", Date()])
            try d.execute(sql: "INSERT INTO op_journal (op,captureId,startedAt,plan) VALUES ('write','corrupt',?,?)",
                          arguments: [Date(), Data("not JSON".utf8)])
        }
        let staged = try lib.stageData(Data([9]))
        let pending = CaptureRecord(kind: .screenshot, width: 1, height: 1, bytes: 1, relPath: "healthy.png", fastID: "")
        try journal(lib, FileOperation(op: "write", source: lib.rel(staged), record: pending, sidecar: nil))
        let reopened = try reopen(lib)
        XCTAssertEqual(try Data(contentsOf: reopened.url(for: record(reopened, pending.id))), Data([9]))
        XCTAssertEqual(try reopened.db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM op_journal WHERE recoveryError IS NOT NULL")
        }, 2)
        XCTAssertEqual(try reopened.db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM op_journal WHERE recoveryError IS NULL")
        }, 0)
    }

    func testRestartFinishesAWriteBeforeOrAfterItsFileMove() throws {
        for moved in [false, true] {
            let (lib, dir) = try library()
            defer { try? FileManager.default.removeItem(at: dir) }
            let staged = try lib.stageData(Data([4, 5, 6]))
            let pending = CaptureRecord(kind: .screenshot, width: 3, height: 4, bytes: 3,
                                        relPath: "recovered.png", fastID: "")
            let sidecar = Sidecar(id: pending.id, created: pending.createdAt, app: "test", window: nil)
            try journal(lib, FileOperation(op: "write", source: lib.rel(staged), record: pending, sidecar: sidecar))
            if moved { try FileManager.default.moveItem(at: staged, to: lib.url(for: pending)) }
            let reopened = try reopen(lib)
            XCTAssertEqual(try record(reopened, pending.id).width, 3)
            XCTAssertEqual(Sidecar.read(for: reopened.url(for: pending))?.id, pending.id)
            XCTAssertEqual(try Data(contentsOf: reopened.url(for: pending)), Data([4, 5, 6]))
            try reopened.recoverPendingOperations()
            XCTAssertEqual(reopened.search().count, 1)
            XCTAssertEqual(try lib.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM op_journal") }, 0)
        }
    }

    func testRestartCompletesEditAfterPixelsChangedBeforeSidecarOrDatabase() throws {
        let (lib, dir) = try library()
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
        try journal(lib, FileOperation(op: "flatten", source: lib.rel(staged), record: capture, sidecar: sidecar))
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
        XCTAssertEqual(try reopened.nextIngestJob()?.revision, 1)
    }

    func testRestartCompletesDiscardAndRestoreWithTheSidecarLeftAtSource() throws {
        let (lib, dir) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        var capture = try shot(lib)
        let initial = capture.relPath
        let source = lib.url(for: capture)
        let sidecar = Sidecar.read(for: source)
        capture.relPath = ".trash/interrupted.png"; capture.status = .trashed; capture.trashedAt = Date()
        try FileManager.default.createDirectory(at: lib.trashDir, withIntermediateDirectories: true)
        try journal(lib, FileOperation(op: "discard", source: initial, record: capture, sidecar: sidecar,
                                       originalRelPath: initial))
        try FileManager.default.moveItem(at: source, to: lib.url(for: capture))
        let reopened = try reopen(lib)
        XCTAssertEqual(try record(reopened, capture.id).status, .trashed)
        XCTAssertNotNil(Sidecar.read(for: reopened.url(for: capture)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.url(for: source).path))
        let trashPath = capture.relPath
        capture.relPath = initial; capture.status = .kept; capture.trashedAt = nil
        try journal(reopened, FileOperation(op: "restore", source: trashPath, record: capture, sidecar: sidecar))
        try FileManager.default.moveItem(at: reopened.root.appendingPathComponent(trashPath), to: source)
        let restored = try reopen(reopened)
        XCTAssertEqual(try record(restored, capture.id).status, .kept)
        XCTAssertNotNil(Sidecar.read(for: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.tombstoneURL(capture.id).path))
    }

    func testActualEditRecoversAfterTheDatabaseCommitFails() throws {
        let (lib, dir) = try library()
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
        let (lib, dir) = try library()
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
        let (lib, dir) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        let target = lib.root.appendingPathComponent("renamed.png")
        try lib.db.queue.write { d in
            try d.execute(sql: "INSERT INTO op_journal (op,captureId,src,dst,startedAt) VALUES ('rename',?,?,?,?)",
                          arguments: [capture.id, capture.relPath, "renamed.png", Date()])
        }
        try FileManager.default.moveItem(at: lib.url(for: capture), to: target)
        let reopened = try reopen(lib)
        XCTAssertEqual(try record(reopened, capture.id).relPath, "renamed.png")
        XCTAssertEqual(reopened.search("renamed").count, 1)
        XCTAssertNotNil(Sidecar.read(for: target))
    }

    func testSweepRemovesOriginalAndRetriesEachFailureBoundary() throws {
        for failedPart in ["original", "capture", "sidecar", "tombstone"] {
            let (lib, dir) = try library()
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
            let (lib, dir) = try library()
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

    func testRenameBetweenEditsKeepsTheSameOriginal() throws {
        let (lib, dir) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        try lib.applyEdit(capture.id, flattenedPNG: Data([4]), layersJSON: "[]", width: 1, height: 1)
        XCTAssertTrue(lib.applyName(capture.id, baseName: "renamed", tags: [], summary: "", aiState: .namedLocal))
        try lib.applyEdit(capture.id, flattenedPNG: Data([5]), layersJSON: "[]", width: 1, height: 1)
        let edited = try record(lib, capture.id)
        XCTAssertEqual(try Data(contentsOf: lib.editBase(for: edited).image), Data([1, 2, 3]))
    }
}
