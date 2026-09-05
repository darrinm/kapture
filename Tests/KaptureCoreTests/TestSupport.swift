import XCTest
@testable import KaptureCore

/// One temporary library per test: `<dir>/db` for the index and `<dir>/files` for the root,
/// laid out so `reopen` can find the database again from the root alone.
extension XCTestCase {
    func makeLibrary() throws -> (Library, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try Database(directory: dir.appendingPathComponent("db"))
        return (try Library(db: db, root: dir.appendingPathComponent("files")), dir)
    }

    /// A second instance on the same root and database, as a relaunch would make. The first is
    /// usually still alive, so the root lock stays off unless a test is about the lock.
    func reopen(_ lib: Library, exclusive: Bool = false) throws -> Library {
        try Library(db: Database(directory: lib.root.deletingLastPathComponent().appendingPathComponent("db")),
                    root: lib.root, exclusive: exclusive)
    }

    func shot(_ lib: Library) throws -> CaptureRecord {
        try lib.storePNG(Data([1, 2, 3]), width: 10, height: 20,
                         sourceApp: "test", windowTitle: nil, screenID: nil).0
    }

    func record(_ lib: Library, _ id: String) throws -> CaptureRecord {
        try XCTUnwrap(lib.db.queue.read { try CaptureRecord.fetchOne($0, key: id) })
    }

    func journalCount(_ lib: Library, where clause: String = "1") throws -> Int {
        try lib.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM op_journal WHERE \(clause)") ?? 0 }
    }
}
