// The review of the merged branch (2026-10-17), one test per fix.
//
// Two of those findings passed every existing test because a helper did what production skipped,
// so each test here goes through the same entry point the app uses — `SyncStore.apply` for a
// pull, `Library`'s own mutations for a change, `LibraryService` for publishing — rather than
// setting up the end state by hand.

import XCTest
import GRDB
import KaptureCore
@testable import KaptureSync

final class ReviewFixTests: XCTestCase {
    var directory: URL!
    var root: URL!
    var database: KaptureCore.Database!
    var crypto: LibraryCrypto!
    var store: SyncStore!
    let deviceID = "01JBAAAAAAAAAAAAAAAAAAAAAA"
    let otherDevice = "01JBBBBBBBBBBBBBBBBBBBBBBB"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-review-\(UUID().uuidString)")
        root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try KaptureCore.Database(directory: directory)
        crypto = LibraryCrypto(key: LibraryCrypto.generateKey())
        store = SyncStore(db: database, crypto: crypto, root: root)
        _ = try store.enable(deviceID: deviceID)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func row(_ id: String, name: String = "2026-10-17 at 10.31.22.png",
             blobs: [BlobPurpose: BlobLocator] = [:], forkedFrom: String? = nil) -> SyncedRow {
        SyncedRow(captureID: id, lamport: 5, deviceID: otherDevice, kind: .screenshot,
                  status: .kept, createdAt: Date(timeIntervalSince1970: 1_760_000_000),
                  width: 4, height: 4, bytes: 6, name: name, contentHash: "h",
                  blobs: blobs, forkedFrom: forkedFrom)
    }

    func pull(_ rows: [SyncedRow]) throws {
        var result = MergeResult()
        result.upserts = rows
        try store.apply(result, cursor: nil, deviceID: deviceID)
    }

    func relPath(_ id: String) throws -> String? {
        try database.queue.read { d in
            try String.fetchOne(d, sql: "SELECT relPath FROM captures WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Finding 1: a pulled capture carries its locator

    func testAPulledCaptureKnowsWhereItsBytesAre() throws {
        let locator = BlobLocator(revision: 3, writer: otherDevice, capture: "BLINDED")
        try pull([row("FROMAWAY", blobs: [.blob: locator])])

        let blobs = BlobStore(db: database, root: root, crypto: crypto,
                              thumbnailDirectory: directory.appendingPathComponent("t"))
        let found = try XCTUnwrap(try blobs.locator(for: "FROMAWAY", purpose: .blob),
                                  "without it fetch marks the capture missing")
        XCTAssertEqual(found.revision, 3)
        XCTAssertEqual(found.capture, "BLINDED")
        XCTAssertEqual(try blobs.state(of: "FROMAWAY"), .remote)
    }

    func testThisMacsRePushOfAPulledCaptureKeepsItsLocators() throws {
        // F129: before the fix, `localRows` built a pulled row with no blobs, so any later push
        // or snapshot from this Mac dropped the locators for every other Mac too.
        let locator = BlobLocator(revision: 3, writer: otherDevice, capture: "BLINDED")
        try pull([row("FROMAWAY", blobs: [.blob: locator])])

        let rows = try store.localRows()
        XCTAssertEqual(rows["FROMAWAY"]?.row.blobs[.blob], locator)
    }

    func testANewerRevisionFromAnotherMacMakesTheLocalFileStale() throws {
        let first = BlobLocator(revision: 1, writer: otherDevice, capture: "BLINDED")
        try pull([row("EDITED", blobs: [.blob: first])])
        try database.queue.write { d in
            try d.execute(sql: "UPDATE captures SET blobState = 'local' WHERE id = 'EDITED'")
        }

        let second = BlobLocator(revision: 2, writer: otherDevice, capture: "BLINDED")
        try pull([row("EDITED", blobs: [.blob: second])])

        let state = try database.queue.read { d in
            try String.fetchOne(d, sql: "SELECT blobState FROM captures WHERE id = 'EDITED'")
        }
        XCTAssertEqual(state, "remote", "the file here is the old revision; opening must fetch")
    }

    // MARK: - Finding 3: a same-second name does not stop sync

    func testTwoMacsCapturingInTheSameSecondDoNotWedgeThePull() throws {
        // Same name, same month: before the fix the second row failed `relPath`'s UNIQUE
        // constraint, the transaction rolled back, and every later pull failed on that page.
        try pull([row("FIRST")])
        XCTAssertNoThrow(try pull([row("SECOND")]))

        let a = try XCTUnwrap(try relPath("FIRST"))
        let b = try XCTUnwrap(try relPath("SECOND"))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(b.hasSuffix(" 2.png"), "suffixed the way Library.uniqueURL suffixes: \(b)")
    }

    func testAPathTakenOnDiskButNotInTheIndexIsAlsoAvoided() throws {
        let taken = root.appendingPathComponent(SyncStore.derivedRelPath(for: row("X")))
        try FileManager.default.createDirectory(at: taken.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("someone else's".utf8).write(to: taken)

        try pull([row("NEW")])

        XCTAssertNotEqual(try relPath("NEW"), SyncStore.derivedRelPath(for: row("X")),
                          "a fetch would otherwise overwrite an unrelated file")
    }

    // MARK: - Finding 7: a pulled deletion takes its bytes with it

    func testAPulledDeletionRemovesTheFileSidecarAndLocators() throws {
        let locator = BlobLocator(revision: 1, writer: otherDevice, capture: "BLINDED")
        try pull([row("GOING", blobs: [.blob: locator])])
        let rel = try XCTUnwrap(try relPath("GOING"))
        let file = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("pixels".utf8).write(to: file)
        try Data("{}".utf8).write(to: Sidecar.url(for: file))

        var result = MergeResult()
        result.deletions = ["GOING"]
        try store.apply(result, cursor: nil, deviceID: deviceID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.url(for: file).path))
        let locators = try database.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM blob_cache WHERE captureId = 'GOING'")
        }
        XCTAssertEqual(locators, 0)
    }

    // MARK: - Finding 9: a fork stays a fork

    func testForkedFromSurvivesARePush() throws {
        try pull([row("FORK", forkedFrom: "ORIGINAL")])

        try store.enqueueCurrentRow("FORK", kind: .upsert, observed: 0, deviceID: deviceID)
        let entry = try XCTUnwrap(try store.pending().first)
        let pushed = try crypto.open(SyncedRow.self, from: entry.payload,
                                     scope: .row(opID: entry.opID), writer: deviceID)

        XCTAssertEqual(pushed.forkedFrom, "ORIGINAL", "or every other Mac loses the F36 badge")
    }

    // MARK: - Finding 11: a snapshot keeps the field rules

    func testASnapshotDoesNotUnpinAManualRename() {
        var pinned = row("A", name: "Budget.png")
        pinned.aiState = .namedAPI
        pinned.lamport = 3
        var autoNamed = row("A", name: "Screenshot.png")
        autoNamed.aiState = .none
        autoNamed.lamport = 9

        let result = SyncMerge.applySnapshot([autoNamed],
                                             to: ["A": LocalRow(row: pinned, acknowledged: true)],
                                             deviceID: deviceID)

        XCTAssertEqual(result.upserts.first?.name, "Budget.png",
                       "F41 holds on the bootstrap path as well as the op path")
    }

    func testASnapshotKeepsAConcurrentTrash() {
        var trashed = row("A")
        trashed.status = .trashed
        trashed.lamport = 7
        var kept = row("A")
        kept.status = .kept
        kept.lamport = 7
        kept.deviceID = "01JBZZZZZZZZZZZZZZZZZZZZZZ"

        let result = SyncMerge.applySnapshot([kept],
                                             to: ["A": LocalRow(row: trashed, acknowledged: true)],
                                             deviceID: deviceID)

        XCTAssertEqual(result.upserts.first?.status, .trashed, "F38 on the bootstrap path too")
    }

    // MARK: - Finding 4: the cache ceiling the pane shows is the one the sweep uses

    func testTheCacheCeilingDefaultsToKeepingEverything() {
        let previous = UserDefaults.standard.object(forKey: "libraryCacheGB")
        UserDefaults.standard.removeObject(forKey: "libraryCacheGB")
        defer { UserDefaults.standard.set(previous, forKey: "libraryCacheGB") }

        XCTAssertEqual(Settings.libraryCacheGBDefault, 0, "the pane shows 0 as \"Everything\"")
        XCTAssertEqual(Settings.shared.libraryCacheBytes, .max,
                       "a user who never touched the picker must not get eviction")
    }
}

// MARK: - Finding 6: every change reaches the log

final class ChangePublishingTests: XCTestCase {
    var directory: URL!
    var library: Library!
    var previousRoot: String?

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = try Library(db: try KaptureCore.Database(directory: directory),
                              root: directory.appendingPathComponent("library"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Collect the kinds `library` posts while `body` runs.
    func changes(during body: () throws -> Void) rethrows -> [CaptureChange.Kind] {
        var seen: [CaptureChange.Kind] = []
        let token = NotificationCenter.default.addObserver(
            forName: Library.captureDidChange, object: library, queue: nil) { note in
            if let change = note.userInfo?[Library.captureChangeKey] as? CaptureChange {
                seen.append(change.kind)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try body()
        return seen
    }

    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    func testStoringACapturePostsCreated() throws {
        let seen = try changes {
            _ = try library.storePNG(png, width: 1, height: 1, sourceApp: nil,
                                     windowTitle: nil, screenID: nil)
        }
        XCTAssertTrue(seen.contains(.created))
    }

    func testDiscardAndRestorePostTrashedAndRestored() throws {
        let (record, _) = try library.storePNG(png, width: 1, height: 1, sourceApp: nil,
                                               windowTitle: nil, screenID: nil)
        let discarded = try changes { try library.discard(record) }
        XCTAssertTrue(discarded.contains(.trashed), "a discard never reached the log before")

        let restored = try changes { _ = try library.restore(id: record.id) }
        XCTAssertTrue(restored.contains(.restored))
    }

    func testAStatusChangePostsMetadata() throws {
        let (record, _) = try library.storePNG(png, width: 1, height: 1, sourceApp: nil,
                                               windowTitle: nil, screenID: nil)
        let seen = try changes { try library.setStatus(record.id, .kept) }
        XCTAssertEqual(seen, [.metadata])
    }

    func testARecordingPostsCreatedToo() throws {
        // Only CaptureCoordinator called `publish`, so recordings and GIF exports never synced.
        // Publishing now hangs off `finish`, which every write passes through.
        let movie = directory.appendingPathComponent("take.mp4")
        try Data(repeating: 0, count: 32).write(to: movie)
        let seen = try changes {
            _ = try library.storeMovie(from: movie, width: 2, height: 2, duration: 1,
                                       sourceApp: nil)
        }
        XCTAssertTrue(seen.contains(.created))
    }
}

// MARK: - Finding 6 end to end, and finding 10: publishing is durable

/// A blob server whose first upload fails, as a dropped connection would.
actor FlakyBlobs {
    private(set) var stored: [String: Data] = [:]
    private var failuresLeft: Int

    init(failures: Int) { failuresLeft = failures }

    func key(_ l: BlobLocatorRef) -> String { "\(l.purpose.rawValue)/\(l.capture)/\(l.revision)/\(l.writer)" }

    func put(_ data: Data, at locator: BlobLocatorRef) throws {
        if failuresLeft > 0 { failuresLeft -= 1; throw SyncFailure("connection lost") }
        stored[key(locator)] = data
    }
    func get(_ locator: BlobLocatorRef) throws -> Data {
        guard let data = stored[key(locator)] else { throw SyncFailure("not found") }
        return data
    }
}

struct FlakyTransport: LibraryTransport {
    let blobs: FlakyBlobs
    let log: FakeLog
    let writer: String

    func changes(since: Int64, limit: Int) async throws -> ChangesPage {
        await log.changes(since: since, limit: limit)
    }
    func push(_ ops: [OutgoingOp]) async throws -> PushOutcome { await log.append(ops, writer: writer) }
    func snapshotClaim(supportsV: Int, seq: Int64) async throws -> Bool { false }
    func putBlob(_ data: Data, at locator: BlobLocatorRef) async throws {
        try await blobs.put(data, at: locator)
    }
    func getBlob(_ locator: BlobLocatorRef) async throws -> Data { try await blobs.get(locator) }
    func putSnapshot(_ data: Data, seq: Int64) async throws {}
    func getSnapshot(seq: Int64, writer: String) async throws -> Data { Data() }
    func acquireSweepLease(windowMs: Int64) async throws -> SweepLease { SweepLease(granted: false) }
}

final class DurablePublishingTests: XCTestCase {
    var directory: URL!
    var library: Library!
    var saved: (key: String?, token: String?, approved: Bool, enabled: Bool, root: URL)!
    let deviceID = "01JBAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-durable-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        saved = (Keychain.libraryKey, Keychain.libraryDeviceToken, LibraryApproval.isApproved,
                 Settings.shared.libraryEnabled, Settings.shared.libraryRoot)
        Settings.shared.libraryRoot = root
        Settings.shared.libraryEnabled = true
        LibraryService.createKey()
        Keychain.libraryDeviceToken = "approved-credential"
        LibraryApproval.isApproved = true
        library = try Library(db: try KaptureCore.Database(directory: directory), root: root)
    }

    override func tearDownWithError() throws {
        Keychain.libraryKey = saved.key
        Keychain.libraryDeviceToken = saved.token
        LibraryApproval.isApproved = saved.approved
        Settings.shared.libraryEnabled = saved.enabled
        Settings.shared.libraryRoot = saved.root
        try? FileManager.default.removeItem(at: directory)
    }

    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    func attempts(_ captureID: String) throws -> Int {
        try library.db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT attempts FROM upload_queue WHERE captureId = ?",
                             arguments: [captureID]) ?? 0
        }
    }

    func makeUploadsDue() throws {
        try library.db.queue.write { d in
            try d.execute(sql: "UPDATE upload_queue SET nextAttemptAt = NULL")
        }
    }

    /// Wait for the notification hop onto the service to land.
    func eventually(_ timeout: TimeInterval = 3, _ condition: () throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func testADiscardReachesTheOutboxAsATrashOp() async throws {
        let service = LibraryService()
        let store = SyncStore(db: library.db, crypto: LibraryCrypto(key: LibraryService.existingKey()!))
        let transport = FlakyTransport(blobs: FlakyBlobs(failures: 0), log: FakeLog(), writer: deviceID)
        _ = await service.start(db: library.db, deviceID: deviceID, transport: transport)
        let (record, _) = try library.storePNG(png, width: 1, height: 1, sourceApp: nil,
                                               windowTitle: nil, screenID: nil)
        await service.syncNow()

        try library.discard(record)

        try await eventually { try store.pending().contains { $0.kind == .trash } }
        XCTAssertTrue(try store.pending().contains { $0.kind == .trash },
                      "without a trash op the server never marks it, and nothing ever sweeps it")
        await service.stop()
    }

    func testAFailedUploadIsRetriedRatherThanDropped() async throws {
        let service = LibraryService()
        let store = SyncStore(db: library.db, crypto: LibraryCrypto(key: LibraryService.existingKey()!))
        let blobs = FlakyBlobs(failures: 1)
        let transport = FlakyTransport(blobs: blobs, log: FakeLog(), writer: deviceID)
        _ = await service.start(db: library.db, deviceID: deviceID, transport: transport)

        let (record, _) = try library.storePNG(png, width: 1, height: 1, sourceApp: nil,
                                               windowTitle: nil, screenID: nil)
        // Wait for the first attempt to have *failed*, not merely been queued. The actor is
        // reentrant at the upload's await, so a drain started any earlier can interleave with the
        // first attempt and have its backoff land after the reset below.
        try await eventually { try attempts(record.id) >= 1 }

        // The first attempt failed: still queued, nothing in the outbox naming absent bytes.
        XCTAssertEqual(try store.queuedUploads(), [record.id])
        XCTAssertFalse(try store.pending().contains { $0.captureID == record.id && !$0.requires.isEmpty })

        // Make the backoff due and sync again, as the timer would.
        try makeUploadsDue()
        await service.drainUploads()

        XCTAssertTrue(try store.queuedUploads().isEmpty, "the retry succeeded and left the queue")
        let stored = await blobs.stored
        XCTAssertEqual(stored.count, 1)
        await service.stop()
    }
}
