// An open library window has to answer to writes it did not make. The window is AppKit and not
// testable here, but the thing it depends on — "any write to captures calls me back" — is.
import XCTest
@testable import KaptureCore

final class LibraryObservationTests: XCTestCase {
    private func makeTempLibrary() throws -> (Library, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(directory: dir.appendingPathComponent("appsupport"))
        return (try Library(db: db, root: dir.appendingPathComponent("root")), dir)
    }

    @discardableResult
    private func store(_ lib: Library) throws -> CaptureRecord {
        try lib.storePNG(Data([1, 2, 3]), width: 1, height: 1,
                         sourceApp: nil, windowTitle: nil, screenID: nil).0
    }

    /// A capture taken while the window is open is the case that was broken: nothing told the
    /// library, because only the share path ever remembered to.
    func testAStoredCaptureNotifiesTheObserver() throws {
        let (lib, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let heard = expectation(description: "the observer hears the write")
        heard.assertForOverFulfill = false
        let observation = lib.observeCaptures { heard.fulfill() }
        defer { observation.cancel() }

        try store(lib)
        wait(for: [heard], timeout: 5)
    }

    /// Not just inserts: a discard only changes a column, and the grid has to notice that too.
    func testAStatusChangeNotifiesTheObserver() throws {
        let (lib, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try store(lib)

        let heard = expectation(description: "the observer hears the discard")
        heard.assertForOverFulfill = false
        let observation = lib.observeCaptures { heard.fulfill() }
        defer { observation.cancel() }

        try lib.discard(record)
        wait(for: [heard], timeout: 5)
    }

    /// The window cancels when it closes, and a cancelled observation has to stay quiet — a live
    /// one behind a closed window would reload a grid nobody is looking at on every capture.
    func testACancelledObservationStopsHearing() throws {
        let (lib, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let silent = expectation(description: "nothing is heard after cancelling")
        silent.isInverted = true
        let observation = lib.observeCaptures { silent.fulfill() }
        observation.cancel()

        try store(lib)
        wait(for: [silent], timeout: 1)
    }
}
