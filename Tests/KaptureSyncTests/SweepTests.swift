// The sweep under sync, and snapshots (docs/SHARED-LIBRARY.md §7.4, §6.4).

import XCTest
import GRDB
import KaptureCore
@testable import KaptureSync

/// A transport whose lease and eligibility list the test controls.
actor LeaseServer {
    var granted: Bool
    var eligible: [String] = []
    private(set) var snapshots: [Int64: Data] = [:]

    init(granted: Bool) { self.granted = granted }

    func setEligible(_ ids: [String]) { eligible = ids }
    func setGranted(_ value: Bool) { granted = value }
    func lease() -> SweepLease { SweepLease(granted: granted, until: 0, eligible: eligible) }
    func store(_ data: Data, seq: Int64) { snapshots[seq] = data }
    func snapshot(_ seq: Int64) -> Data? { snapshots[seq] }
}

struct LeaseTransport: LibraryTransport {
    let server: LeaseServer
    var allowSnapshot = true

    func changes(since: Int64, limit: Int) async throws -> ChangesPage {
        ChangesPage(ops: [], head: 0, oldestRetained: 0)
    }
    func push(_ ops: [OutgoingOp]) async throws -> PushOutcome {
        PushOutcome(assigned: [], rejected: [], head: 0)
    }
    func snapshotClaim(supportsV: Int, seq: Int64) async throws -> Bool { allowSnapshot }
    func putBlob(_ data: Data, at locator: BlobLocatorRef) async throws {}
    func getBlob(_ locator: BlobLocatorRef) async throws -> Data { Data() }
    func putSnapshot(_ data: Data, seq: Int64) async throws { await server.store(data, seq: seq) }
    func getSnapshot(seq: Int64, writer: String) async throws -> Data {
        guard let data = await server.snapshot(seq) else { throw SyncFailure("no snapshot") }
        return data
    }
    func acquireSweepLease(windowMs: Int64) async throws -> SweepLease { await server.lease() }
}

final class SweepTests: XCTestCase {
    var directory: URL!
    var root: URL!
    var database: KaptureCore.Database!
    var crypto: LibraryCrypto!
    var store: SyncStore!
    var blobs: BlobStore!
    var sweeper: SweepCoordinator!
    let deviceID = "01JBAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-sweep-\(UUID().uuidString)")
        root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try KaptureCore.Database(directory: directory)
        crypto = LibraryCrypto(key: LibraryCrypto.generateKey())
        store = SyncStore(db: database, crypto: crypto)
        blobs = BlobStore(db: database, root: root, crypto: crypto,
                          thumbnailDirectory: directory.appendingPathComponent("thumbs"))
        sweeper = SweepCoordinator(store: store, blobs: blobs, deviceID: deviceID)
        _ = try store.enable(deviceID: deviceID)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func insert(_ id: String, status: CaptureStatus, bytes: Int = 10,
                acknowledged: Bool = true) throws {
        let store = self.store!
        let deviceID = self.deviceID
        let crypto = self.crypto!
        try database.queue.write { d in
            let row = SyncedRow(captureID: id, lamport: 1, deviceID: deviceID, kind: .screenshot,
                                status: status,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                width: 1, height: 1, bytes: bytes, name: "\(id).png",
                                contentHash: "h")
            try store.upsert(row, in: d, acknowledged: acknowledged)
            try d.execute(sql: """
                INSERT INTO blob_cache (captureId, purpose, revision, writer, owningCapture, bytes, lastOpenedAt)
                VALUES (?, 'blob', 1, ?, ?, ?, ?)
                """, arguments: [id, deviceID, crypto.blind(id), bytes,
                                 Date(timeIntervalSince1970: 1)])
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

    // MARK: - F43, F44: only the lease holder deletes

    func testWithoutTheLeaseNothingIsDeleted() async throws {
        let server = LeaseServer(granted: false)
        try insert("OLD", status: .trashed)
        await server.setEligible([crypto.blind("OLD")])

        let outcome = try await sweeper.sweep(using: LeaseTransport(server: server),
                                              cacheCeiling: .max)

        XCTAssertFalse(outcome.heldLease)
        XCTAssertTrue(outcome.deleted.isEmpty,
                      "a device without the lease never deletes a row or a remote blob")
    }

    func testWithoutTheLeaseTheLocalCacheIsStillSwept() async throws {
        // F44: eviction is what a device may always do, because the bytes can be fetched again.
        let server = LeaseServer(granted: false)
        try insert("BIG", status: .kept, bytes: 500)

        let outcome = try await sweeper.sweep(using: LeaseTransport(server: server),
                                              cacheCeiling: 0)

        XCTAssertEqual(outcome.evicted, 1)
        XCTAssertEqual(try blobs.state(of: "BIG"), .remote)
    }

    func testTheLeaseHolderQueuesADeleteForAnEligibleCapture() async throws {
        let server = LeaseServer(granted: true)
        try insert("OLD", status: .trashed)
        await server.setEligible([crypto.blind("OLD")])

        let outcome = try await sweeper.sweep(using: LeaseTransport(server: server),
                                              cacheCeiling: .max)

        XCTAssertTrue(outcome.heldLease)
        XCTAssertEqual(outcome.deleted, ["OLD"])
        XCTAssertEqual(try store.pending().first?.kind, .delete)
    }

    func testEligibilityComesFromTheServerNotTheLocalClock() async throws {
        // F45, F108: a local trashedAt is not authoritative, and a Mac with a skewed clock
        // would otherwise sweep early.
        let server = LeaseServer(granted: true)
        try insert("TRASHED_LOCALLY", status: .trashed)
        await server.setEligible([])            // the server says nothing is eligible yet

        let outcome = try await sweeper.sweep(using: LeaseTransport(server: server),
                                              cacheCeiling: .max)

        XCTAssertTrue(outcome.deleted.isEmpty)
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testAKeptCaptureIsNeverDeletedEvenIfTheServerListsIt() async throws {
        let server = LeaseServer(granted: true)
        try insert("ALIVE", status: .kept)
        await server.setEligible([crypto.blind("ALIVE")])

        let outcome = try await sweeper.sweep(using: LeaseTransport(server: server),
                                              cacheCeiling: .max)

        XCTAssertTrue(outcome.deleted.isEmpty, "status is checked locally as well")
    }

    // MARK: - F33, F102, F111: only a complete client snapshots

    func testASnapshotIsRefusedWhileAnythingIsSkipped() async throws {
        try store.noteSkipped(seq: 7, v: 99, kind: "upsert")

        let written = try await sweeper.snapshotIfNeeded(
            using: LeaseTransport(server: LeaseServer(granted: false)), opsSinceSnapshot: 20_000)

        XCTAssertFalse(written, "an incomplete snapshot plus compaction is unrecoverable loss")
    }

    func testASnapshotIsRefusedWhileTheOutboxIsNotEmpty() async throws {
        // F111: a snapshot claims to be the library at seq N, so it may not contain local state
        // the log has never seen.
        try insert("LOCAL", status: .kept, acknowledged: false)
        try queueAnOp(for: "LOCAL")

        let written = try await sweeper.snapshotIfNeeded(
            using: LeaseTransport(server: LeaseServer(granted: false)), opsSinceSnapshot: 20_000)

        XCTAssertFalse(written)
    }

    func testACompleteClientWritesASnapshotThatRoundTrips() async throws {
        let server = LeaseServer(granted: false)
        let transport = LeaseTransport(server: server)
        try insert("ONE", status: .kept)
        try insert("TWO", status: .kept)
        try store.advanceCursor(to: 42)

        let written = try await sweeper.snapshotIfNeeded(using: transport,
                                                         opsSinceSnapshot: 20_000)
        XCTAssertTrue(written)

        let saved = await server.snapshot(42)
        let data = try XCTUnwrap(saved)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("ONE"),
                       "a snapshot is ciphertext like everything else")

        let rows = try crypto.open([SyncedRow].self, from: data,
                                   scope: .snapshot(seq: 42), writer: deviceID)
        XCTAssertEqual(Set(rows.map(\.captureID)), ["ONE", "TWO"])
    }

    func testApplyingASnapshotRemovesARowDeletedWhileOffline() throws {
        // The end-to-end version of F130/F131, through the coordinator.
        try insert("GONE", status: .kept)
        try insert("STAYS", status: .kept)
        let survivor = try store.localRows()["STAYS"]!.row
        let sealed = try crypto.seal([survivor], scope: .snapshot(seq: 9), writer: deviceID)

        let result = try sweeper.applySnapshot(sealed, seq: 9, writer: deviceID)

        XCTAssertEqual(result.deletions, ["GONE"])
        XCTAssertNil(try store.localRows()["GONE"])
        XCTAssertNotNil(try store.localRows()["STAYS"])
    }

    func testApplyingASnapshotKeepsAndSeedsWorkTheLogNeverSaw() throws {
        try insert("MINE", status: .kept, acknowledged: false)
        let sealed = try crypto.seal([SyncedRow](), scope: .snapshot(seq: 9), writer: deviceID)

        let result = try sweeper.applySnapshot(sealed, seq: 9, writer: deviceID)

        XCTAssertTrue(result.deletions.isEmpty)
        XCTAssertEqual(result.outbox.map(\.captureID), ["MINE"])
    }
}
