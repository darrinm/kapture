// The engine and the store, against a real database and a fake log.
//
// The merge is tested purely in SyncMergeTests; this covers what happens around it — durable
// queueing (F29), acknowledgement (F30), idempotent retry (F31), skipping an op this build
// cannot read (F78), and the round trip through encryption.

import XCTest
import GRDB
import KaptureCore
@testable import KaptureSync

/// A log that behaves like the Durable Object: assigns seq in order, dedupes by opID, and can be
/// told to reject. No network, so the engine's own logic is what is under test.
///
/// The writer is stamped from the pushing device rather than supplied by the caller, exactly as
/// `parseEnvelope` does in the Worker. That is not cosmetic: `writer` is a key-derivation input
/// (F12), so a log that recorded the wrong one would hand every reader a key that decrypts
/// nothing — which is precisely what this fake did in its first draft.
actor FakeLog {
    struct Stored { var seq: Int64; var op: OutgoingOp; var writer: String }
    private(set) var stored: [Stored] = []
    private var seqByOpID: [String: Int64] = [:]
    var rejectReason: String?

    func setRejection(_ reason: String?) { rejectReason = reason }

    func changes(since: Int64, limit: Int) -> ChangesPage {
        let ops = stored.filter { $0.seq > since }.prefix(limit).map { entry in
            WireOp(seq: entry.seq, opID: entry.op.opID, deviceID: entry.writer,
                   blindedID: entry.op.blindedID, v: entry.op.v, kind: entry.op.kind,
                   observed: entry.op.observed, ciphertext: entry.op.ciphertext)
        }
        return ChangesPage(ops: Array(ops), head: stored.last?.seq ?? 0,
                           oldestRetained: stored.first?.seq ?? 0)
    }

    func append(_ ops: [OutgoingOp], writer: String) -> PushOutcome {
        var assigned: [PushOutcome.Assigned] = []
        var rejected: [PushOutcome.Rejected] = []
        for op in ops {
            if let reason = rejectReason {
                rejected.append(.init(opID: op.opID, reason: reason))
                continue
            }
            if let existing = seqByOpID[op.opID] {
                assigned.append(.init(opID: op.opID, seq: existing))   // F31
                continue
            }
            let seq = Int64(stored.count + 1)
            stored.append(Stored(seq: seq, op: op, writer: writer))
            seqByOpID[op.opID] = seq
            assigned.append(.init(opID: op.opID, seq: seq))
        }
        return PushOutcome(assigned: assigned, rejected: rejected, head: stored.last?.seq ?? 0)
    }

    /// Inject an op from a newer build than the client understands (F78).
    func injectFuture(v: Int, kind: String, writer: String) {
        let seq = Int64(stored.count + 1)
        stored.append(Stored(
            seq: seq,
            op: OutgoingOp(opID: ULID.generate(), blindedID: "X", v: v, kind: kind,
                           requires: [], observed: 0, ciphertext: Data("x".utf8).base64EncodedString()),
            writer: writer))
    }
}

/// One device's view of the log, carrying the credential the server would authenticate.
struct FakeTransport: LibraryTransport {
    let log: FakeLog
    let writer: String

    func changes(since: Int64, limit: Int) async throws -> ChangesPage {
        await log.changes(since: since, limit: limit)
    }

    func push(_ ops: [OutgoingOp]) async throws -> PushOutcome {
        await log.append(ops, writer: writer)
    }

    func snapshotClaim(supportsV: Int, seq: Int64) async throws -> Bool { true }

    // Blob and sweep traffic is exercised by BlobStoreTests and SweepTests; this fake carries
    // rows only, so these are inert rather than absent.
    func putBlob(_ data: Data, at locator: BlobLocatorRef) async throws {}
    func getBlob(_ locator: BlobLocatorRef) async throws -> Data { Data() }
    func putSnapshot(_ data: Data, seq: Int64) async throws {}
    func getSnapshot(seq: Int64, writer: String) async throws -> Data { Data() }
    func acquireSweepLease(windowMs: Int64) async throws -> SweepLease { SweepLease(granted: false) }
}

final class SyncEngineTests: XCTestCase {
    var directory: URL!
    var database: KaptureCore.Database!
    var crypto: LibraryCrypto!
    var store: SyncStore!
    let deviceID = "01JBAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try KaptureCore.Database(directory: directory)
        crypto = LibraryCrypto(key: LibraryCrypto.generateKey())
        store = SyncStore(db: database, crypto: crypto)
        _ = try store.enable(deviceID: deviceID)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeRow(_ id: String = ULID.generate(), lamport: Int64 = 1,
                 name: String = "shot.png", status: CaptureStatus = .kept) -> SyncedRow {
        SyncedRow(captureID: id, lamport: lamport, deviceID: deviceID, kind: .screenshot,
                  status: status, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                  width: 10, height: 10, bytes: 5, name: name, contentHash: "h1")
    }

    /// Write the row and its op in one transaction, which is what F29 requires of every caller.
    func queue(_ row: SyncedRow, kind: OpKind = .upsert, observed: Int64 = 0,
               into target: SyncStore? = nil, as writer: String? = nil) throws {
        let store = target ?? self.store!
        let writer = writer ?? deviceID
        try store.db.queue.write { d in
            try store.upsert(row, in: d, acknowledged: false)
            try store.enqueue(row, kind: kind, observed: observed, deviceID: writer, in: d)
        }
    }

    // MARK: - migration and identity

    func testTheMigrationAddsSyncStateWithoutDisturbingCaptures() throws {
        let identity = try store.identity()
        XCTAssertEqual(identity?.deviceID, deviceID)
        XCTAssertEqual(identity?.cursor, 0)
        XCTAssertEqual(identity?.keyID, crypto.keyID)
    }

    // MARK: - F29: the outbox is the durability boundary

    func testAQueuedOpSurvivesReopeningTheDatabase() throws {
        let row = makeRow()
        try queue(row)

        // A new handle on the same file, as a relaunch would open.
        let reopened = SyncStore(db: try KaptureCore.Database(directory: directory), crypto: crypto)
        XCTAssertEqual(try reopened.pending().count, 1)
        XCTAssertEqual(try reopened.pending().first?.captureID, row.captureID)
    }

    func testTheOutboxHoldsCiphertextRatherThanReadableRows() throws {
        let row = makeRow(name: "secret-project.png")
        try queue(row)
        let payload = try XCTUnwrap(try store.pending().first?.payload)
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("secret-project"),
                       "a queued op must be no more readable on disk than on the server")
    }

    // MARK: - push and pull through the engine

    func testPushThenPullRoundTripsARowThroughEncryption() async throws {
        let log = FakeLog()
        let engine = SyncEngine(store: store, transport: FakeTransport(log: log, writer: deviceID), deviceID: deviceID)
        let row = makeRow(name: "budget.png")
        try queue(row)

        let pushed = try await engine.syncOnce()
        XCTAssertEqual(pushed.pushed, 1)
        XCTAssertTrue(try store.pending().isEmpty, "an acknowledged op leaves the outbox (F30)")

        // A second Mac, same library key, empty database.
        let otherDir = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let otherStore = SyncStore(db: try KaptureCore.Database(directory: otherDir),
                                   crypto: crypto)
        _ = try otherStore.enable(deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")
        let otherEngine = SyncEngine(store: otherStore,
                                     transport: FakeTransport(log: log, writer: "01JBBBBBBBBBBBBBBBBBBBBBBB"),
                                     deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")

        let summary = try await otherEngine.syncOnce()
        XCTAssertEqual(summary.applied, 1)

        let landed = try otherStore.localRows()
        XCTAssertEqual(landed[row.captureID]?.row.name, "budget.png")
        XCTAssertEqual(landed[row.captureID]?.acknowledged, true)
    }

    func testTheSecondMacDerivesItsOwnPathRatherThanTakingTheSenders() async throws {
        // F83: relPath never travels. The receiving Mac builds its own from the date and name.
        let log = FakeLog()
        let engine = SyncEngine(store: store, transport: FakeTransport(log: log, writer: deviceID), deviceID: deviceID)
        let row = makeRow(name: "report.png")
        try queue(row)
        _ = try await engine.syncOnce()

        let otherDir = directory.appendingPathComponent("third")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let otherDB = try KaptureCore.Database(directory: otherDir)
        let otherStore = SyncStore(db: otherDB, crypto: crypto)
        _ = try otherStore.enable(deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")
        _ = try await SyncEngine(store: otherStore,
                                 transport: FakeTransport(log: log, writer: "01JBBBBBBBBBBBBBBBBBBBBBBB"),
                                 deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB").syncOnce()

        let relPath = try await otherDB.queue.read { d in
            try String.fetchOne(d, sql: "SELECT relPath FROM captures WHERE id = ?",
                                arguments: [row.captureID])
        }
        XCTAssertEqual(relPath, "2023/11/report.png")
    }

    func testANameCarryingASeparatorCannotEscapeTheShard() throws {
        // §13: an op is attacker-controlled if a device credential leaks.
        let row = makeRow(name: "../../etc/passwd")
        let derived = SyncStore.derivedRelPath(for: row)
        XCTAssertFalse(derived.contains(".."))
        XCTAssertEqual(derived.split(separator: "/").count, 3)
    }

    // MARK: - F31: retry

    func testARetriedPushDoesNotDuplicateTheOp() async throws {
        let log = FakeLog()
        let row = makeRow()
        try queue(row)
        let entry = try XCTUnwrap(try store.pending().first)
        let outgoing = OutgoingOp(opID: entry.opID, blindedID: crypto.blind(entry.captureID),
                                  v: 1, kind: "upsert", requires: [], observed: 0,
                                  ciphertext: entry.payload.base64EncodedString())

        let first = await log.append([outgoing], writer: deviceID)
        let second = await log.append([outgoing], writer: deviceID)
        XCTAssertEqual(first.assigned[0].seq, second.assigned[0].seq)
        let storedCount = await log.stored.count
        XCTAssertEqual(storedCount, 1)
    }

    // MARK: - F78, F135: an op this build cannot read

    func testAnOpFromANewerBuildIsSkippedWithoutStallingTheCursor() async throws {
        let log = FakeLog()
        await log.injectFuture(v: 99, kind: "upsert", writer: deviceID)
        let engine = SyncEngine(store: store, transport: FakeTransport(log: log, writer: deviceID), deviceID: deviceID)

        let summary = try await engine.syncOnce()

        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(try store.skippedSeqs(), [1], "it is recorded for replay (F104)")
        XCTAssertEqual(try store.identity()?.cursor, 1,
                       "the cursor advances: stalling behind a newer Mac is worse than a stale row")
    }

    func testAnUnknownKindIsSkippedToo() async throws {
        let log = FakeLog()
        await log.injectFuture(v: 1, kind: "reticulate", writer: deviceID)
        let engine = SyncEngine(store: store, transport: FakeTransport(log: log, writer: deviceID), deviceID: deviceID)

        let summary = try await engine.syncOnce()
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(try store.skippedSeqs(), [1])
    }

    func testReplayIsTriggeredByAWiderCapabilityNotOnlyAHigherVersion() throws {
        // F135: a release that adds a kind without bumping v must still go back for what it
        // skipped. Keying on the capability string is what makes that true.
        try database.queue.write { d in
            try d.execute(sql: "UPDATE sync_state SET capabilities = ? WHERE id = 1",
                          arguments: ["v1;upsert,trash"])
        }
        XCTAssertTrue(try store.capabilitiesWidened())
        try store.recordCapabilities()
        XCTAssertFalse(try store.capabilitiesWidened())
    }

    // MARK: - rejection handling

    func testAStaleDeleteIsDroppedRatherThanRetriedForever() async throws {
        let log = FakeLog()
        await log.setRejection("stale delete: capture changed at 12")
        let row = makeRow()
        try queue(row, kind: .delete, observed: 1)

        _ = try await SyncEngine(store: store, transport: FakeTransport(log: log, writer: deviceID), deviceID: deviceID).syncOnce()

        XCTAssertTrue(try store.pending().isEmpty,
                      "a delete the log has already superseded will never succeed on retry")
    }

    func testATransientRejectionBacksOffInsteadOfDropping() async throws {
        let log = FakeLog()
        await log.setRejection("missing blob blob/3")
        let row = makeRow()
        try queue(row)

        _ = try await SyncEngine(store: store, transport: FakeTransport(log: log, writer: deviceID), deviceID: deviceID).syncOnce()

        // Still queued, but not due yet.
        XCTAssertTrue(try store.pending().isEmpty, "it is deferred")
        let total = try await database.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM sync_outbox") ?? 0
        }
        XCTAssertEqual(total, 1, "the op is kept for a later attempt, not discarded")
    }

    // MARK: - two devices converging

    func testTwoDevicesConvergeOnOneRowSet() async throws {
        let log = FakeLog()
        let engineA = SyncEngine(store: store, transport: FakeTransport(log: log, writer: deviceID), deviceID: deviceID)

        let otherDir = directory.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let storeB = SyncStore(db: try KaptureCore.Database(directory: otherDir), crypto: crypto)
        _ = try storeB.enable(deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")
        let engineB = SyncEngine(store: storeB,
                                 transport: FakeTransport(log: log, writer: "01JBBBBBBBBBBBBBBBBBBBBBBB"),
                                 deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")

        let fromA = makeRow(name: "a.png")
        try queue(fromA)
        _ = try await engineA.syncOnce()
        _ = try await engineB.syncOnce()

        var fromB = makeRow(name: "b.png")
        fromB.deviceID = "01JBBBBBBBBBBBBBBBBBBBBBBB"
        try queue(fromB, into: storeB, as: "01JBBBBBBBBBBBBBBBBBBBBBBB")
        _ = try await engineB.syncOnce()
        _ = try await engineA.syncOnce()

        let namesOnA = Set(try store.localRows().values.map(\.row.name))
        let namesOnB = Set(try storeB.localRows().values.map(\.row.name))
        XCTAssertEqual(namesOnA, ["a.png", "b.png"])
        XCTAssertEqual(namesOnA, namesOnB)
    }
}
