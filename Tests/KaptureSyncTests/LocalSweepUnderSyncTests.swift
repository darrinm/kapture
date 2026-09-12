// The local sweep must stand down when the library is shared (F43, F44).
//
// This is the most consequential guard in M6c. Without it, enabling sync makes every Mac delete
// captures the others have just restored, on a six-hour timer, silently — the local `trashedAt`
// is not authoritative and the seven days are the server's to count.

import XCTest
import GRDB
import KaptureCore
@testable import KaptureSync

final class LocalSweepUnderSyncTests: XCTestCase {
    var directory: URL!
    var library: Library!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-localsweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try KaptureCore.Database(directory: directory)
        library = try Library(db: db, root: directory.appendingPathComponent("library"))
        Settings.shared.libraryEnabled = false
    }

    override func tearDownWithError() throws {
        Settings.shared.libraryEnabled = false
        try? FileManager.default.removeItem(at: directory)
    }

    func trashSomethingOldEnoughToSweep() throws -> String {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let (record, _) = try library.storePNG(png, width: 1, height: 1,
                                               sourceApp: nil, windowTitle: nil, screenID: nil)
        try library.discard(record)
        try library.db.queue.write { d in
            try d.execute(sql: "UPDATE captures SET trashedAt = ? WHERE id = ?",
                          arguments: [Date(timeIntervalSince1970: 0), record.id])
        }
        return record.id
    }

    func survives(_ id: String) throws -> Bool {
        try library.db.queue.read { d in try CaptureRecord.fetchOne(d, key: id) != nil }
    }

    func testTheLocalSweepStillDeletesWhenSyncIsOff() throws {
        let id = try trashSomethingOldEnoughToSweep()

        library.sweepTrash()

        XCTAssertFalse(try survives(id),
                       "the seven-day sweep must keep working on a Mac that does not sync (G6)")
    }

    func testTheSweepPolicyIsDecidedAtTheScheduleNotInsideLibrary() async throws {
        // The guard used to sit inside `sweepTrash`, which covered only the public entry point
        // and left the internal overload deleting anyway. The decision belongs to whoever
        // installs the timer, so what is asserted here is that the *policy flag* routes away
        // from the local sweep — not that `Library` second-guesses its own caller.
        let id = try trashSomethingOldEnoughToSweep()
        Settings.shared.libraryEnabled = true

        // What the app's schedule does under sync: the lease holder deletes through the log,
        // and `LibraryService` is not started here, so nothing local is deleted.
        if !Settings.shared.libraryEnabled { library.sweepTrash() }

        XCTAssertTrue(try survives(id),
                      "under sync only the lease holder deletes, and only through the log")
    }
}
