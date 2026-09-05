import XCTest
@testable import KaptureCore

final class RevisionTests: XCTestCase {
    private func fixture() throws -> (Library, CaptureRecord, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = try Library(db: Database(directory: dir.appendingPathComponent("db")), root: dir.appendingPathComponent("files"))
        let record = try lib.storePNG(Data([1, 2, 3]), width: 4, height: 5, sourceApp: nil, windowTitle: nil, screenID: nil).0
        return (lib, record, dir)
    }

    func testEditingNamedCaptureRefreshesTagsWithoutMovingAnUnchangedName() throws {
        let (lib, record, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(lib.applyName(record.id, baseName: "invoice", tags: ["oldtag"], summary: "old", aiState: .namedAPI))
        let named = try XCTUnwrap(lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) })
        try lib.enqueueIngest(record.id, notBefore: Date())
        let redundant = try XCTUnwrap(lib.nextIngestJob())
        XCTAssertTrue(try lib.finishOCR(redundant, text: "invoice", naming: true))
        XCTAssertNil(try lib.nextIngestJob(), "An already named revision must not enqueue a paid naming call")
        try lib.applyEdit(record.id, flattenedPNG: Data([9]), layersJSON: "[]", width: 1, height: 1)
        let ocr = try XCTUnwrap(lib.nextIngestJob())
        XCTAssertTrue(try lib.finishOCR(ocr, text: "invoice", naming: true))
        let name = try XCTUnwrap(lib.nextIngestJob())
        XCTAssertEqual(name.stage, "name")
        // Naming usually comes back with the same answer. That refreshes the tags and summary
        // and leaves the file where it is — not invoice-2.png, then invoice-3.png next edit.
        XCTAssertTrue(lib.applyName(record.id, baseName: "invoice", tags: ["stripe"], summary: "invoice", aiState: .namedAPI, job: name))
        let renamed = try XCTUnwrap(lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) })
        XCTAssertEqual(renamed.relPath, named.relPath)
        XCTAssertEqual(renamed.aiState, .namedAPI)
        XCTAssertEqual(lib.search("stripe").count, 1)
        XCTAssertTrue(lib.search("oldtag").isEmpty)
    }

    func testSnapshotUsesAHardLinkAndSupportsFilesystemsWithoutLinks() throws {
        let (lib, record, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let linked = try lib.shareSnapshot(record.id)
        defer { try? FileManager.default.removeItem(at: linked.file) }
        let fm = FileManager.default
        XCTAssertEqual(try fm.attributesOfItem(atPath: linked.file.path)[.systemFileNumber] as? NSNumber,
                       try fm.attributesOfItem(atPath: lib.url(for: record).path)[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(linked.file.deletingLastPathComponent().lastPathComponent, ".pending")
        let copied = try lib.shareSnapshot(record.id, linking: { _, _ in throw CocoaError(.featureUnsupported) })
        defer { try? fm.removeItem(at: copied.file) }
        try lib.applyEdit(record.id, flattenedPNG: Data([9]), layersJSON: "[]", width: 1, height: 1)
        XCTAssertEqual(try Data(contentsOf: linked.file), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: copied.file), Data([1, 2, 3]))
    }

    func testOldOCRCannotRepopulateRedactedTextOrRemoveTheReplacementJob() throws {
        let (lib, record, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try lib.enqueueIngest(record.id, notBefore: Date())
        let old = try XCTUnwrap(lib.nextIngestJob())
        // OCR is in flight with the old pixels when the user saves a redaction.
        try lib.applyEdit(record.id, flattenedPNG: Data([9]), layersJSON: "[]", width: 1, height: 1)
        let replacement = try XCTUnwrap(lib.nextIngestJob())
        XCTAssertNotEqual(old.generation, replacement.generation)
        XCTAssertEqual(replacement.stage, "ocr")
        XCTAssertFalse(try lib.finishOCR(old, text: "password", naming: true))
        try lib.retryIngestJob(old, after: 100, error: "old failure")
        try lib.clearIngestJob(old)
        XCTAssertEqual(try lib.nextIngestJob()?.generation, replacement.generation)
        XCTAssertTrue(lib.search("password").isEmpty)
        XCTAssertTrue(try lib.finishOCR(replacement, text: "redacted", naming: false))
        XCTAssertEqual(lib.search("redacted").count, 1)
        XCTAssertNil(try lib.nextIngestJob())
    }

    func testEditDuringNamingRestartsOCRAndRejectsTheOldName() throws {
        let (lib, record, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try lib.enqueueIngest(record.id, notBefore: Date())
        let ocr = try XCTUnwrap(lib.nextIngestJob())
        XCTAssertTrue(try lib.finishOCR(ocr, text: "secret", naming: true))
        let naming = try XCTUnwrap(lib.nextIngestJob())
        XCTAssertEqual(naming.stage, "name")
        try lib.applyEdit(record.id, flattenedPNG: Data([9]), layersJSON: "[]", width: 1, height: 1)
        // This is the normal post-save enqueue; it must not resurrect the previous name stage.
        try lib.enqueueIngest(record.id, notBefore: Date())
        XCTAssertEqual(try lib.nextIngestJob()?.stage, "ocr")
        XCTAssertFalse(lib.applyName(record.id, baseName: "secret", tags: ["secret"], summary: "secret",
                                    aiState: .namedAPI, job: naming))
        try lib.clearIngestJob(naming)
        XCTAssertNotNil(try lib.nextIngestJob())
        XCTAssertTrue(lib.search("secret").isEmpty)
    }

    func testCanceledJobCannotOverwriteAReenqueueAtTheSameRevision() throws {
        let (lib, record, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try lib.enqueueIngest(record.id, notBefore: Date())
        let canceled = try XCTUnwrap(lib.nextIngestJob())
        try lib.clearIngestJob(canceled)
        try lib.enqueueIngest(record.id, notBefore: Date())
        let current = try XCTUnwrap(lib.nextIngestJob())
        XCTAssertEqual(current.revision, canceled.revision)
        XCTAssertNotEqual(current.generation, canceled.generation)
        XCTAssertFalse(try lib.finishOCR(canceled, text: "old", naming: false))
        XCTAssertTrue(try lib.finishOCR(current, text: "new", naming: false))
    }

    func testUploadSnapshotDoesNotChangeAndLateCompletionStaysStale() throws {
        let (lib, record, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = try lib.shareSnapshot(record.id)
        defer { try? FileManager.default.removeItem(at: snapshot.file) }
        try lib.applyEdit(record.id, flattenedPNG: Data([9]), layersJSON: "[]", width: 1, height: 1)
        XCTAssertEqual(try Data(contentsOf: snapshot.file), Data([1, 2, 3]))
        XCTAssertFalse(try lib.setShareLink(record.id, url: "https://kapture.sh/old", revision: snapshot.record.contentRevision))
        let stored = try XCTUnwrap(lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) })
        XCTAssertTrue(stored.shareStale)
        let fresh = try lib.shareSnapshot(record.id)
        defer { try? FileManager.default.removeItem(at: fresh.file) }
        XCTAssertEqual(try Data(contentsOf: fresh.file), Data([9]))
        XCTAssertTrue(try lib.setShareLink(record.id, url: "https://kapture.sh/new", revision: fresh.record.contentRevision))
        XCTAssertFalse(try XCTUnwrap(lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) }).shareStale)
    }

    func testTrimAlsoInvalidatesAnUploadRevision() throws {
        let (lib, record, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trimmed = dir.appendingPathComponent("trimmed.mp4")
        try Data([4, 5]).write(to: trimmed)
        try lib.applyTrim(record.id, trimmedURL: trimmed, duration: 3)
        XCTAssertFalse(try lib.setShareLink(record.id, url: "https://kapture.sh/old", revision: record.contentRevision))
        XCTAssertEqual(try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) }?.contentRevision, 1)
    }
}
