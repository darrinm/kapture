// Bytes on demand, and the cache (docs/SHARED-LIBRARY.md §8).

import XCTest
import GRDB
import KaptureCore
@testable import KaptureSync

/// A blob server that keeps sealed bytes in memory and can be made to fail.
actor FakeBlobs {
    private(set) var objects: [String: Data] = [:]
    var failNext = false

    func key(_ locator: BlobLocatorRef) -> String {
        "\(locator.purpose.rawValue)/\(locator.capture)/\(locator.revision)/\(locator.writer)"
    }

    func put(_ data: Data, at locator: BlobLocatorRef) { objects[key(locator)] = data }

    func get(_ locator: BlobLocatorRef) throws -> Data {
        if failNext { failNext = false; throw SyncFailure("network went away") }
        guard let data = objects[key(locator)] else { throw SyncFailure("not found") }
        return data
    }

    func setFailNext(_ value: Bool) { failNext = value }
    var count: Int { objects.count }
}

struct BlobTransport: LibraryTransport {
    let blobs: FakeBlobs

    func changes(since: Int64, limit: Int) async throws -> ChangesPage {
        ChangesPage(ops: [], head: 0, oldestRetained: 0)
    }
    func push(_ ops: [OutgoingOp]) async throws -> PushOutcome {
        PushOutcome(assigned: [], rejected: [], head: 0)
    }
    func snapshotClaim(supportsV: Int, seq: Int64) async throws -> Bool { true }
    func putBlob(_ data: Data, at locator: BlobLocatorRef) async throws {
        await blobs.put(data, at: locator)
    }
    func getBlob(_ locator: BlobLocatorRef) async throws -> Data {
        try await blobs.get(locator)
    }
    func putSnapshot(_ data: Data, seq: Int64) async throws {}
    func getSnapshot(seq: Int64, writer: String) async throws -> Data { Data() }
    func acquireSweepLease(windowMs: Int64) async throws -> SweepLease { SweepLease(granted: false) }
}

final class BlobStoreTests: XCTestCase {
    var directory: URL!
    var root: URL!
    var database: KaptureCore.Database!
    var crypto: LibraryCrypto!
    var store: SyncStore!
    var blobs: BlobStore!
    let deviceID = "01JBAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-blobs-\(UUID().uuidString)")
        root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try KaptureCore.Database(directory: directory)
        crypto = LibraryCrypto(key: LibraryCrypto.generateKey())
        store = SyncStore(db: database, crypto: crypto)
        blobs = BlobStore(db: database, root: root, crypto: crypto,
                          thumbnailDirectory: directory.appendingPathComponent("thumbs"))
        _ = try store.enable(deviceID: deviceID)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func insert(_ id: String, bytes: Int = 100, state: BlobState = .local,
                acknowledged: Bool = true, opened: Date? = nil) throws -> URL {
        let row = SyncedRow(captureID: id, lamport: 1, deviceID: deviceID, kind: .screenshot,
                            status: .kept, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                            width: 10, height: 10, bytes: bytes, name: "\(id).png",
                            contentHash: "h")
        try database.queue.write { d in
            try store.upsert(row, in: d, acknowledged: acknowledged)
            try d.execute(sql: "UPDATE captures SET blobState = ? WHERE id = ?",
                          arguments: [state.rawValue, id])
            try d.execute(sql: """
                INSERT INTO blob_cache (captureId, purpose, revision, writer, owningCapture, bytes, lastOpenedAt)
                VALUES (?, 'blob', 1, ?, ?, ?, ?)
                """, arguments: [id, deviceID, crypto.blind(id), bytes, opened])
        }
        let url = root.appendingPathComponent("2023/11/\(id).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// A row the log knows about with no `blob_cache` entry: the server has no bytes for it.
    func insertRowOnly(_ captureID: String) throws {
        let store = self.store!
        let deviceID = self.deviceID
        try database.queue.write { d in
            let row = SyncedRow(captureID: captureID, lamport: 1, deviceID: deviceID,
                                kind: .screenshot, status: .kept,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                width: 1, height: 1, bytes: 0, name: "\(captureID).png")
            try store.upsert(row, in: d, acknowledged: true)
        }
    }

    func queueAnOp(for captureID: String) throws {
        let store = self.store!
        let deviceID = self.deviceID
        try database.queue.write { d in
            guard let record = try CaptureRecord.fetchOne(d, key: captureID) else { return }
            let row = try store.row(for: record, in: d)
            try store.enqueue(row, kind: .upsert, observed: 0, deviceID: deviceID, in: d)
        }
    }

    // MARK: - fetch (F48, F49, F50)

    func testFetchingBringsBytesDownAndDecryptsThem() async throws {
        let server = FakeBlobs()
        let transport = BlobTransport(blobs: server)
        let file = try insert("CAP1", bytes: 12)
        let original = try Data(contentsOf: file)

        let locator = try await blobs.upload("CAP1", from: file, revision: 1,
                                             writer: deviceID, using: transport)
        // The second Mac has the row but not the bytes.
        try FileManager.default.removeItem(at: file)
        try blobs.setState(.remote, for: "CAP1")

        let fetched = try await blobs.fetch("CAP1", using: transport)

        XCTAssertEqual(try Data(contentsOf: fetched), original)
        XCTAssertEqual(try blobs.state(of: "CAP1"), .local)
        XCTAssertEqual(locator.capture, crypto.blind("CAP1"))
    }

    func testWhatIsStoredOnTheServerIsCiphertext() async throws {
        let server = FakeBlobs()
        let transport = BlobTransport(blobs: server)
        let file = try insert("CAP2", bytes: 32)
        try Data("the secret pixels".utf8).write(to: file)

        let locator = try await blobs.upload("CAP2", from: file, revision: 1,
                                             writer: deviceID, using: transport)
        let stored = try await server.get(locator)

        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("secret pixels"))
    }

    func testAFailedFetchLeavesTheCaptureRemoteRatherThanEmpty() async throws {
        // F49: a silently empty editor is worse than a visible retry.
        let server = FakeBlobs()
        let transport = BlobTransport(blobs: server)
        let file = try insert("CAP3", bytes: 8)
        _ = try await blobs.upload("CAP3", from: file, revision: 1,
                                   writer: deviceID, using: transport)
        try FileManager.default.removeItem(at: file)
        try blobs.setState(.remote, for: "CAP3")
        await server.setFailNext(true)

        do {
            _ = try await blobs.fetch("CAP3", using: transport)
            XCTFail("the fetch should have failed")
        } catch {
            XCTAssertEqual(try blobs.state(of: "CAP3"), .remote)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                           "no empty file is left behind")
        }
    }

    func testACaptureWithNoServerBytesIsMissingRatherThanRemote() async throws {
        // F50: reachable only through data loss or a partial delete, and shown as such.
        let transport = BlobTransport(blobs: FakeBlobs())
        try insertRowOnly("GHOST")

        do {
            _ = try await blobs.fetch("GHOST", using: transport)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(try blobs.state(of: "GHOST"), .missing)
        }
    }

    // MARK: - eviction (F51, F52, F53)

    func testEvictionTakesTheLeastRecentlyOpenedDownToTheCeiling() throws {
        try insert("OLD", bytes: 100, opened: Date(timeIntervalSince1970: 1))
        try insert("MID", bytes: 100, opened: Date(timeIntervalSince1970: 2))
        try insert("NEW", bytes: 100, opened: Date(timeIntervalSince1970: 3))

        let plan = try blobs.planEviction(ceilingBytes: 150)

        XCTAssertEqual(plan.evicted, ["OLD", "MID"])
        XCTAssertEqual(plan.freed, 200)
    }

    func testEvictionNeverTouchesBytesTheServerHasNotAcknowledged() throws {
        // F52: the local copy is the only copy until the log says otherwise.
        try insert("UNSYNCED", bytes: 500, acknowledged: false,
                   opened: Date(timeIntervalSince1970: 1))

        let plan = try blobs.planEviction(ceilingBytes: 0)

        XCTAssertTrue(plan.evicted.isEmpty)
    }

    func testEvictionSkipsACaptureWithAQueuedOp() throws {
        let file = try insert("QUEUED", bytes: 500, opened: Date(timeIntervalSince1970: 1))
        try queueAnOp(for: "QUEUED")

        let plan = try blobs.planEviction(ceilingBytes: 0)

        XCTAssertTrue(plan.evicted.isEmpty, "an unsent op still needs its bytes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCarryingOutAPlanRemovesTheFileAndMarksTheRowRemote() throws {
        let file = try insert("GOING", bytes: 100, opened: Date(timeIntervalSince1970: 1))

        try blobs.evict(try blobs.planEviction(ceilingBytes: 0))

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try blobs.state(of: "GOING"), .remote, "the row stays; only bytes go")
    }

    // MARK: - thumbnails (F47)

    func testThumbnailsAreStoredOutsideTheLibraryRoot() throws {
        try blobs.writeThumbnail(Data("jpeg".utf8), for: "CAP9")

        XCTAssertTrue(blobs.hasThumbnail("CAP9"))
        XCTAssertFalse(blobs.thumbnailURL(for: "CAP9").path.hasPrefix(root.path),
                       "derived data does not belong in the user's folder of real files")
    }
}
