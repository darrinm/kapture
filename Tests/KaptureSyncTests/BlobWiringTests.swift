// The byte path, end to end (docs/SHARED-LIBRARY.md §8, F23, F32, F98, F129).
//
// A review found this half of sync inert: `row(for:in:)` never populated `blobs`, `enqueue` was
// never called with `requires`, and `BlobStore.upload` had no caller. Everything below passed
// before that was true, because each piece was tested in isolation and nothing tested the seam.

import XCTest
import GRDB
import KaptureCore
@testable import KaptureSync

final class BlobWiringTests: XCTestCase {
    var directory: URL!
    var root: URL!
    var database: KaptureCore.Database!
    var crypto: LibraryCrypto!
    var store: SyncStore!
    var blobs: BlobStore!
    let deviceID = "01JBAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-wiring-\(UUID().uuidString)")
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

    /// Apply a row as a pull would: the row plus the locators it names (F23, F129).
    static func receive(_ row: SyncedRow, into store: SyncStore,
                        db: KaptureCore.Database) throws {
        try db.queue.write { d in
            try store.upsert(row, in: d, acknowledged: true)
            for (purpose, locator) in row.blobs {
                try d.execute(sql: """
                    INSERT INTO blob_cache (captureId, purpose, revision, writer, owningCapture, bytes)
                    VALUES (?, ?, ?, ?, ?, 0)
                    """, arguments: [row.captureID, purpose.rawValue, locator.revision,
                                     locator.writer, locator.capture])
            }
        }
    }

    func insert(_ id: String) throws -> URL {
        let store = self.store!
        let deviceID = self.deviceID
        try database.queue.write { d in
            let row = SyncedRow(captureID: id, lamport: 1, deviceID: deviceID, kind: .screenshot,
                                status: .kept,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                width: 4, height: 4, bytes: 6, name: "\(id).png",
                                contentHash: "h")
            try store.upsert(row, in: d, acknowledged: false)
        }
        let url = root.appendingPathComponent("2023/11/\(id).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("pixels".utf8).write(to: url)
        return url
    }

    func testUploadingRecordsALocatorThatTheRowThenCarries() async throws {
        let server = FakeBlobs()
        let transport = BlobTransport(blobs: server)
        let file = try insert("CAP1")

        _ = try await blobs.upload("CAP1", from: file, revision: 1,
                                   writer: deviceID, using: transport)

        let row = try XCTUnwrap(try store.localRows()["CAP1"]?.row)
        XCTAssertEqual(row.blobs[.blob]?.revision, 1)
        XCTAssertEqual(row.blobs[.blob]?.writer, deviceID)
        XCTAssertEqual(row.blobs[.blob]?.capture, crypto.blind("CAP1"),
                       "the row alone must be enough to reach its own bytes (F129)")
    }

    func testAQueuedOpNamesTheBlobsItsRowCarries() async throws {
        let server = FakeBlobs()
        let transport = BlobTransport(blobs: server)
        let file = try insert("CAP2")
        _ = try await blobs.upload("CAP2", from: file, revision: 1,
                                   writer: deviceID, using: transport)

        try store.enqueueCurrentRow("CAP2", kind: .upsert, observed: 0, deviceID: deviceID)

        let entry = try XCTUnwrap(try store.pending().first)
        XCTAssertEqual(entry.requires.count, 1,
                       "without this the server's F32 dependency check has nothing to check")
        XCTAssertEqual(entry.requires.first?.purpose, .blob)
        XCTAssertEqual(entry.requires.first?.capture, crypto.blind("CAP2"))
    }

    func testACaptureThisMacMadeStaysLocalEvenThoughItHasBlobs() async throws {
        // The row carries locators the moment it is uploaded, and a naive reading of "has blobs"
        // would mark the capture remote on the very Mac holding the file.
        let server = FakeBlobs()
        let transport = BlobTransport(blobs: server)
        let file = try insert("CAP3")
        _ = try await blobs.upload("CAP3", from: file, revision: 1,
                                   writer: deviceID, using: transport)

        try store.enqueueCurrentRow("CAP3", kind: .upsert, observed: 0, deviceID: deviceID)

        XCTAssertEqual(try blobs.state(of: "CAP3"), .local)
    }

    func testARowArrivingWithBlobsThisMacLacksIsRemote() throws {
        let incoming = SyncedRow(
            captureID: "FROMAWAY", lamport: 5, deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB",
            kind: .screenshot, status: .kept,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            width: 4, height: 4, bytes: 6, name: "away.png", contentHash: "h",
            blobs: [.blob: BlobLocator(revision: 2, writer: "01JBBBBBBBBBBBBBBBBBBBBBBB",
                                       capture: "BLINDED")])
        let store = self.store!
        try database.queue.write { d in
            try store.upsert(incoming, in: d, acknowledged: true)
        }

        XCTAssertEqual(try blobs.state(of: "FROMAWAY"), .remote)
    }

    func testARowArrivingWithNoBlobsIsLocalRatherThanRemote() throws {
        // Metadata-only: there are no bytes anywhere, so "remote" would promise a fetch that
        // can never succeed and F50 would report it as missing.
        let incoming = SyncedRow(
            captureID: "NOBYTES", lamport: 5, deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB",
            kind: .screenshot, status: .kept,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            width: 4, height: 4, bytes: 0, name: "none.png")
        let store = self.store!
        try database.queue.write { d in
            try store.upsert(incoming, in: d, acknowledged: true)
        }

        XCTAssertEqual(try blobs.state(of: "NOBYTES"), .local)
    }

    func testAFetchedCaptureRoundTripsThroughTheWholePath() async throws {
        // Upload on one Mac, then read the row on another and fetch what it names.
        let server = FakeBlobs()
        let transport = BlobTransport(blobs: server)
        let file = try insert("SHARED")
        _ = try await blobs.upload("SHARED", from: file, revision: 1,
                                   writer: deviceID, using: transport)
        let row = try XCTUnwrap(try store.localRows()["SHARED"]?.row)

        let otherDir = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let otherRoot = otherDir.appendingPathComponent("library")
        let otherDB = try KaptureCore.Database(directory: otherDir)
        let otherStore = SyncStore(db: otherDB, crypto: crypto)
        _ = try otherStore.enable(deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")
        let otherBlobs = BlobStore(db: otherDB, root: otherRoot, crypto: crypto,
                                   thumbnailDirectory: otherDir.appendingPathComponent("t"))
        try Self.receive(row, into: otherStore, db: otherDB)
        XCTAssertEqual(try otherBlobs.state(of: "SHARED"), .remote)

        let fetched = try await otherBlobs.fetch("SHARED", using: transport)

        XCTAssertEqual(try Data(contentsOf: fetched), Data("pixels".utf8))
        XCTAssertEqual(try otherBlobs.state(of: "SHARED"), .local)
    }
}

final class ForkIdentityTests: XCTestCase {
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func row(_ id: String, lamport: Int64, device: String, hash: String) -> SyncedRow {
        SyncedRow(captureID: id, lamport: lamport, deviceID: device, kind: .screenshot,
                  status: .kept, createdAt: epoch, width: 1, height: 1, bytes: 1,
                  name: "x.png", contentRevision: 1, contentHash: hash)
    }

    func testBothMacsMintTheSameForkForTheSameConflict() {
        // F140: a generated id gives each Mac a different fork, so the losing content ends up in
        // the library twice under ids that will never reconcile.
        let a = row("A", lamport: 5, device: "device-a", hash: "aaa")
        let b = row("A", lamport: 5, device: "device-b", hash: "bbb")

        let onA = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: b)],
                                  to: ["A": LocalRow(row: a, acknowledged: true)],
                                  deviceID: "device-a")
        let onB = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: a)],
                                  to: ["A": LocalRow(row: b, acknowledged: true)],
                                  deviceID: "device-b")

        XCTAssertEqual(onA.forks, onB.forks, "both Macs must arrive at the same fork id")
        XCTAssertEqual(onA.forks.first?.count, 26, "and it must look like every other capture id")
    }

    func testBothMacsPushTheForkSoItReachesTheLog() throws {
        let a = row("A", lamport: 5, device: "device-a", hash: "aaa")
        let b = row("A", lamport: 9, device: "device-b", hash: "bbb")

        let onA = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: b)],
                                  to: ["A": LocalRow(row: a, acknowledged: true)],
                                  deviceID: "device-a")

        XCTAssertEqual(onA.outbox.map(\.captureID), onA.forks,
                       "the fork is only in the log if somebody sends it")
    }

    func testAForkIsNotAcknowledgedUntilItIsPushed() {
        // A fork written as acknowledged is read by F130 as "the log knew this and dropped it",
        // and the next snapshot deletes the edit the fork existed to rescue.
        let a = row("A", lamport: 5, device: "device-a", hash: "aaa")
        let b = row("A", lamport: 9, device: "device-b", hash: "bbb")

        let result = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: b)],
                                     to: ["A": LocalRow(row: a, acknowledged: true)],
                                     deviceID: "device-a")

        XCTAssertFalse(result.outbox.isEmpty)
        XCTAssertEqual(result.outbox.first?.forkedFrom, "A")
    }
}
