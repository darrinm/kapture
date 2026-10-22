// Two Macs edit one capture before either has seen the other's edit (docs/SHARED-LIBRARY.md F35,
// F37, F81, F140), through the same Library.applyEdit the editor calls.
//
// The merge tests cover forking with rows built by hand, hashes included. Nothing on the real
// path set contentHash or parentHash, so in rollout stage 5 a concurrent edit resolved by order
// and the Mac Studio's annotation was lost. This drives the real path end to end.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import GRDB
import KaptureCore
@testable import KaptureSync

final class ConcurrentEditTests: XCTestCase {
    struct Mac {
        let library: Library
        let store: SyncStore
        let engine: SyncEngine
        let deviceID: String
    }

    var directory: URL!
    let crypto = LibraryCrypto(key: LibraryCrypto.generateKey())
    let log = FakeLog()

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-concurrent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func mac(_ name: String, deviceID: String) throws -> Mac {
        let base = directory.appendingPathComponent(name)
        let root = base.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try KaptureCore.Database(directory: base)
        let store = SyncStore(db: db, crypto: crypto, root: root)
        _ = try store.enable(deviceID: deviceID)
        return Mac(library: try Library(db: db, root: root), store: store,
                   engine: SyncEngine(store: store, transport: FakeTransport(log: log, writer: deviceID),
                                      deviceID: deviceID),
                   deviceID: deviceID)
    }

    /// A PNG of one solid colour, so each Mac's edit has different bytes.
    func png(red: CGFloat) throws -> Data {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Queue the capture's current row and sync, as `publishStatus` does after an edit.
    func publish(_ id: String, from mac: Mac) async throws {
        let cursor = try mac.store.identity()?.cursor ?? 0
        try mac.store.enqueueCurrentRow(id, kind: .upsert, observed: cursor, deviceID: mac.deviceID)
        _ = try await mac.engine.syncOnce()
    }

    /// The pulled capture's file arrives on this Mac, as opening it would fetch it (F48).
    /// Synchronous, so GRDB's blocking overloads are used rather than its async ones.
    func fetched(_ id: String, bytes: Data, on mac: Mac) throws {
        let pulled = try XCTUnwrap(try mac.library.db.queue.read {
            try CaptureRecord.fetchOne($0, key: id) })
        let file = mac.library.url(for: pulled)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: file)
        try mac.library.db.queue.write {
            try $0.execute(sql: "UPDATE captures SET blobState = 'local' WHERE id = ?",
                           arguments: [id])
        }
    }

    func forks(of id: String, on mac: Mac) throws -> [SyncedRow] {
        try mac.store.localRows().values.map(\.row).filter { $0.forkedFrom == id }
    }

    func testEditsMadeOnTwoMacsAtOnceBothSurviveAsTheSameFork() async throws {
        let studio = try mac("studio", deviceID: "01JBAAAAAAAAAAAAAAAAAAAAAA")
        let macbook = try mac("macbook", deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")

        // A capture made on the Studio reaches the MacBook, and the MacBook has its file.
        let original = try png(red: 0.1)
        let (record, _) = try studio.library.storePNG(original, width: 8, height: 8, sourceApp: nil,
                                                      windowTitle: nil, screenID: nil)
        try await publish(record.id, from: studio)
        _ = try await macbook.engine.syncOnce()
        try fetched(record.id, bytes: original, on: macbook)

        // Each annotates it before seeing the other's edit.
        try studio.library.applyEdit(record.id, flattenedPNG: try png(red: 0.9), layersJSON: "[]",
                                     width: 8, height: 8)
        try macbook.library.applyEdit(record.id, flattenedPNG: try png(red: 0.5), layersJSON: "[]",
                                      width: 8, height: 8)
        try await publish(record.id, from: studio)
        try await publish(record.id, from: macbook)   // pushes, then pulls the Studio's edit
        _ = try await studio.engine.syncOnce()        // pulls the MacBook's edit and its fork

        let onMacBook = try forks(of: record.id, on: macbook)
        let onStudio = try forks(of: record.id, on: studio)
        XCTAssertEqual(onMacBook.count, 1, "the losing edit is kept as a fork, not discarded")
        XCTAssertEqual(onStudio.map(\.captureID), onMacBook.map(\.captureID),
                       "both Macs derive the same fork (F140)")
        let kept = try XCTUnwrap(try studio.store.localRows()[record.id]?.row)
        XCTAssertNotEqual(kept.contentHash, onStudio.first?.contentHash,
                          "the original and the fork hold the two different edits")
    }

    func testAnEditNotYetUploadedBecomesTheForkWithItsOwnBytes() async throws {
        // The app's path: an edit queues its upload, and a sync pulls the other Mac's edit
        // before the drain sends it. The fork inherited the pre-edit locators, and the queued
        // upload would have sent this Mac's edit as the original's next revision, over the
        // other Mac's.
        let studio = try mac("studio", deviceID: "01JBAAAAAAAAAAAAAAAAAAAAAA")
        let macbook = try mac("macbook", deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")
        let original = try png(red: 0.1)
        let (record, _) = try studio.library.storePNG(original, width: 8, height: 8, sourceApp: nil,
                                                      windowTitle: nil, screenID: nil)
        try await publish(record.id, from: studio)
        _ = try await macbook.engine.syncOnce()
        try fetched(record.id, bytes: original, on: macbook)

        try macbook.library.applyEdit(record.id, flattenedPNG: try png(red: 0.5), layersJSON: "[]",
                                      width: 8, height: 8)
        try await publish(record.id, from: macbook)
        let studioEdit = try png(red: 0.9)
        try studio.library.applyEdit(record.id, flattenedPNG: studioEdit, layersJSON: "[]",
                                     width: 8, height: 8)
        try studio.store.queueUpload(record.id)          // what publish does on an edit
        _ = try await studio.engine.syncOnce()           // pulls the MacBook's edit first

        let fork = try XCTUnwrap(try forks(of: record.id, on: studio).first)
        let state = try uploadState(on: studio, fork: fork.captureID, original: record.id)
        XCTAssertEqual(state.forkBlobState, "local")
        XCTAssertEqual(state.forkQueued, true, "the fork uploads the edit under its own key")
        XCTAssertEqual(state.forkLocators, 0, "not the pre-edit bytes it inherited")
        XCTAssertEqual(state.originalQueued, false, "the edit no longer goes up as the original")
        XCTAssertEqual(state.originalBlobState, "remote", "the original is fetched again")
        let forkFile = studio.library.root.appendingPathComponent(state.forkRelPath)
        XCTAssertEqual(try Data(contentsOf: forkFile), studioEdit, "the edit is on disk as the fork")
    }

    // MARK: - Renames (G2)

    func relPath(of id: String, on mac: Mac) throws -> String? {
        try mac.library.db.queue.read {
            try String.fetchOne($0, sql: "SELECT relPath FROM captures WHERE id = ?", arguments: [id])
        }
    }

    func testARenameReachesTheOtherMacAndMovesItsFile() async throws {
        // Renames stayed on the Mac that made them, and the other Mac's next push of the capture
        // sent the old name back to the log with a newer lamport.
        let studio = try mac("studio", deviceID: "01JBAAAAAAAAAAAAAAAAAAAAAA")
        let macbook = try mac("macbook", deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")
        let bytes = try png(red: 0.1)
        let (record, _) = try studio.library.storePNG(bytes, width: 8, height: 8, sourceApp: nil,
                                                      windowTitle: nil, screenID: nil)
        try await publish(record.id, from: studio)
        _ = try await macbook.engine.syncOnce()
        try fetched(record.id, bytes: bytes, on: macbook)

        XCTAssertTrue(studio.library.applyName(record.id, baseName: "invoice march", tags: [],
                                               summary: "an invoice", aiState: .namedLocal))
        try await publish(record.id, from: studio)
        _ = try await macbook.engine.syncOnce()

        let path = try XCTUnwrap(try relPath(of: record.id, on: macbook))
        XCTAssertEqual((path as NSString).lastPathComponent, "invoice march.png")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: macbook.library.root.appendingPathComponent(path).path), "the file moved with it")

        // The MacBook's next push carries the new name, not the old one.
        try await publish(record.id, from: macbook)
        _ = try await studio.engine.syncOnce()
        XCTAssertEqual(try relPath(of: record.id, on: studio).map { ($0 as NSString).lastPathComponent },
                       "invoice march.png")
    }

    func testANameThatHadToBeSuffixedHereIsNotRenamedOnEveryPull() async throws {
        let studio = try mac("studio", deviceID: "01JBAAAAAAAAAAAAAAAAAAAAAA")
        let macbook = try mac("macbook", deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")
        let (record, _) = try studio.library.storePNG(try png(red: 0.1), width: 8, height: 8,
                                                      sourceApp: nil, windowTitle: nil, screenID: nil)
        try await publish(record.id, from: studio)
        _ = try await macbook.engine.syncOnce()
        let first = try XCTUnwrap(try relPath(of: record.id, on: macbook))

        // A capture of the MacBook's own takes the name the Studio's capture is about to get.
        XCTAssertTrue(studio.library.applyName(record.id, baseName: "taken", tags: [],
                                               summary: "", aiState: .namedLocal))
        let blocker = macbook.library.root
            .appendingPathComponent((first as NSString).deletingLastPathComponent)
            .appendingPathComponent("taken.png")
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: blocker)
        try await publish(record.id, from: studio)
        _ = try await macbook.engine.syncOnce()
        let suffixed = try XCTUnwrap(try relPath(of: record.id, on: macbook))
        XCTAssertEqual((suffixed as NSString).lastPathComponent, "taken 2.png")

        // The same name pulled again leaves it where it is.
        try await publish(record.id, from: studio)
        _ = try await macbook.engine.syncOnce()
        XCTAssertEqual(try relPath(of: record.id, on: macbook), suffixed)
    }

    struct UploadState {
        var forkBlobState = "", forkRelPath = "", originalBlobState = ""
        var forkQueued = false, originalQueued = false, forkLocators = 0
    }

    func uploadState(on mac: Mac, fork: String, original: String) throws -> UploadState {
        try mac.library.db.queue.read { d in
            var state = UploadState()
            let forkRow = try Row.fetchOne(d, sql: "SELECT blobState, relPath FROM captures WHERE id = ?",
                                           arguments: [fork])
            state.forkBlobState = forkRow?["blobState"] ?? ""
            state.forkRelPath = forkRow?["relPath"] ?? ""
            state.originalBlobState = try String.fetchOne(
                d, sql: "SELECT blobState FROM captures WHERE id = ?", arguments: [original]) ?? ""
            let queued = try String.fetchAll(d, sql: "SELECT captureId FROM upload_queue")
            state.forkQueued = queued.contains(fork)
            state.originalQueued = queued.contains(original)
            state.forkLocators = try Int.fetchOne(
                d, sql: "SELECT count(*) FROM blob_cache WHERE captureId = ?", arguments: [fork]) ?? 0
            return state
        }
    }

    func testASecondEditOnOneSideStillForksAgainstTheOther() async throws {
        // Stage 5 exactly: the MacBook saved twice, so it reached revision 2 while the Studio
        // was at 1. Different revisions, so only the parent hash shows they diverged (F112).
        let studio = try mac("studio", deviceID: "01JBAAAAAAAAAAAAAAAAAAAAAA")
        let macbook = try mac("macbook", deviceID: "01JBBBBBBBBBBBBBBBBBBBBBBB")
        let original = try png(red: 0.1)
        let (record, _) = try studio.library.storePNG(original, width: 8, height: 8, sourceApp: nil,
                                                      windowTitle: nil, screenID: nil)
        try await publish(record.id, from: studio)
        _ = try await macbook.engine.syncOnce()
        try fetched(record.id, bytes: original, on: macbook)

        try studio.library.applyEdit(record.id, flattenedPNG: try png(red: 0.9), layersJSON: "[]",
                                     width: 8, height: 8)
        try macbook.library.applyEdit(record.id, flattenedPNG: try png(red: 0.5), layersJSON: "[]",
                                      width: 8, height: 8)
        try macbook.library.applyEdit(record.id, flattenedPNG: try png(red: 0.6), layersJSON: "[]",
                                      width: 8, height: 8)
        try await publish(record.id, from: studio)
        try await publish(record.id, from: macbook)
        _ = try await studio.engine.syncOnce()

        XCTAssertEqual(try forks(of: record.id, on: macbook).count, 1)
        XCTAssertEqual(try forks(of: record.id, on: studio).map(\.captureID),
                       try forks(of: record.id, on: macbook).map(\.captureID))
    }
}
