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
        let original = lib.originalPath(for: capture)
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
