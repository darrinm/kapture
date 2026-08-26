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

    func testULIDSortsByTime() {
        let a = ULID.generate(now: Date(timeIntervalSince1970: 1000))
        let b = ULID.generate(now: Date(timeIntervalSince1970: 2000))
        XCTAssertLessThan(a.prefix(10), b.prefix(10))
        XCTAssertEqual(a.count, 26)
    }
}
