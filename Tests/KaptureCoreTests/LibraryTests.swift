import XCTest
@testable import KaptureCore

final class LibraryTests: XCTestCase {
    func makeTempLibrary() throws -> (Library, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(directory: dir.appendingPathComponent("appsupport"))
        let lib = try Library(db: db, root: dir.appendingPathComponent("root"))
        return (lib, dir)
    }

    func testStoreWritesFileSidecarAndRow() throws {
        let (lib, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3])
        let (record, url) = try lib.storePNG(png, width: 10, height: 5, sourceApp: "test.app", windowTitle: nil, screenID: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Sidecar.url(for: url).path))
        XCTAssertEqual(record.status, .staged)
        let count = try lib.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM captures") }
        XCTAssertEqual(count, 1)
        // journal cleared after successful op
        let journal = try lib.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM op_journal") }
        XCTAssertEqual(journal, 0)
    }

    func testStatusTransition() throws {
        let (lib, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (record, _) = try lib.storePNG(Data([1, 2, 3]), width: 1, height: 1, sourceApp: nil, windowTitle: nil, screenID: nil)
        try lib.setStatus(record.id, .kept)
        let status = try lib.db.queue.read {
            try String.fetchOne($0, sql: "SELECT status FROM captures WHERE id = ?", arguments: [record.id])
        }
        XCTAssertEqual(status, "kept")
    }

    func testDiscardRestoreRoundTrip() throws {
        let (lib, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (record, url) = try lib.storePNG(Data([1, 2, 3]), width: 1, height: 1, sourceApp: nil, windowTitle: nil, screenID: nil)

        try lib.discard(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let trashed = try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) }
        XCTAssertEqual(trashed?.status, .trashed)
        XCTAssertTrue(trashed!.relPath.hasPrefix(".trash/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.root.appendingPathComponent(trashed!.relPath).path))

        let restored = try lib.restoreLastDiscarded()
        XCTAssertEqual(restored?.id, record.id)
        XCTAssertEqual(restored?.status, .kept)
        XCTAssertEqual(restored?.relPath, record.relPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // journal fully cleared
        let journal = try lib.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM op_journal") }
        XCTAssertEqual(journal, 0)
    }

    func testSweepDeletesOnlyExpired() throws {
        let (lib, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, _) = try lib.storePNG(Data([1]), width: 1, height: 1, sourceApp: nil, windowTitle: nil, screenID: nil)
        let (b, _) = try lib.storePNG(Data([2]), width: 1, height: 1, sourceApp: nil, windowTitle: nil, screenID: nil)
        try lib.discard(a)
        try lib.discard(b)
        // age a's trash timestamp past the cutoff
        try lib.db.queue.write { d in
            try d.execute(sql: "UPDATE captures SET trashedAt = ? WHERE id = ?",
                          arguments: [Date().addingTimeInterval(-8 * 86400), a.id])
        }
        lib.sweepTrash(olderThanDays: 7)
        let remaining = try lib.db.queue.read { try CaptureRecord.fetchAll($0, sql: "SELECT * FROM captures") }
        XCTAssertEqual(remaining.map(\.id), [b.id])
    }

    func testSearchFindsByNameAndScope() throws {
        let (lib, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (shot, url) = try lib.storePNG(Data([1, 2, 3]), width: 4, height: 3,
                                           sourceApp: nil, windowTitle: nil, screenID: nil)
        // the stored name is a timestamp; give it searchable text the way ingest will
        try lib.updateSearchText(shot.id, name: "stripe-payout-error.png", ocr: "account restricted")

        XCTAssertEqual(lib.search("stripe").map(\.id), [shot.id])       // name match
        XCTAssertEqual(lib.search("restrict").map(\.id), [shot.id])     // prefix match into OCR
        XCTAssertTrue(lib.search("nonexistentterm").isEmpty)
        XCTAssertEqual(lib.search("", scope: .screenshots).map(\.id), [shot.id])
        XCTAssertTrue(lib.search("", scope: .recordings).isEmpty)

        // trashed captures leave the default scope and appear under .trash
        var fresh = try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: shot.id) }!
        try lib.discard(fresh)
        XCTAssertTrue(lib.search("stripe").isEmpty)
        XCTAssertEqual(lib.search("stripe", scope: .trash).map(\.id), [shot.id])
        fresh = try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: shot.id) }!
        XCTAssertEqual(fresh.status, .trashed)
        _ = url
    }

    func testULIDSortsByTime() {
        let a = ULID.generate(now: Date(timeIntervalSince1970: 1000))
        let b = ULID.generate(now: Date(timeIntervalSince1970: 2000))
        XCTAssertLessThan(a.prefix(10), b.prefix(10))
        XCTAssertEqual(a.count, 26)
    }
}
