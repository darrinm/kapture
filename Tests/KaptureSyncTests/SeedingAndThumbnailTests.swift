// Rollout stage 2: seeding an existing library, and thumbnails (docs/SHARED-LIBRARY.md §11.1, §8.1).

import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import GRDB
import KaptureCore
@testable import KaptureSync

// MARK: - Fixtures

enum Media {
    /// A PNG of the given size, written to `url`.
    static func png(_ url: URL, width: Int, height: Int) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A movie of `seconds` at 10 frames a second, so the poster-frame path runs against a real
    /// file. Motion JPEG rather than H.264: the hardware H.264 and HEVC encoders fail after a
    /// few frames (-17691) in a command-line test process, and the generator decodes either.
    static func movie(_ url: URL, width: Int, height: Int, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let time = CMTime(value: CMTimeValue(frame), timescale: 10)
            guard adaptor.append(buffer!, withPresentationTime: time) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func size(of jpeg: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }
}

// MARK: - F47: the thumbnail itself

final class ThumbnailerTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testAScreenshotBecomesA512PixelJPEG() async throws {
        let file = directory.appendingPathComponent("wide.png")
        try Media.png(file, width: 3000, height: 1500)

        let made = await Thumbnailer.jpeg(for: file, kind: .screenshot)
        let jpeg = try XCTUnwrap(made)

        let (w, h) = try XCTUnwrap(Media.size(of: jpeg))
        XCTAssertEqual(max(w, h), 512, "long edge 512 (F47)")
        XCTAssertEqual(w, 2 * h, "aspect ratio kept")
        XCTAssertLessThan(jpeg.count, 60_000, "about 60 KB at most")
    }

    func testARecordingGetsAPosterFrame() async throws {
        let file = directory.appendingPathComponent("take.mov")
        try await Media.movie(file, width: 640, height: 360, seconds: 2)

        let made = await Thumbnailer.jpeg(for: file, kind: .recording)
        let jpeg = try XCTUnwrap(made)

        let (w, h) = try XCTUnwrap(Media.size(of: jpeg))
        XCTAssertLessThanOrEqual(max(w, h), 512)
        XCTAssertGreaterThan(w, h)
    }

    func testAnUnreadableFileHasNoThumbnailRatherThanAnError() async {
        let file = directory.appendingPathComponent("broken.png")
        try? Data("not an image".utf8).write(to: file)
        let jpeg = await Thumbnailer.jpeg(for: file, kind: .screenshot)
        XCTAssertNil(jpeg, "a capture that will not render syncs without a thumbnail")
    }
}

// MARK: - F62-F66: seeding in the store

final class SeedingStoreTests: XCTestCase {
    var directory: URL!
    var database: KaptureCore.Database!
    var store: SyncStore!
    let deviceID = "01JBAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try KaptureCore.Database(directory: directory)
        store = SyncStore(db: database, crypto: LibraryCrypto(key: LibraryCrypto.generateKey()))
        _ = try store.enable(deviceID: deviceID)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func insert(_ id: String, status: CaptureStatus = .kept, acknowledged: Bool = false,
                createdAt: TimeInterval = 1_760_000_000) throws {
        let store = self.store!
        try database.queue.write { d in
            let row = SyncedRow(captureID: id, lamport: 1, deviceID: "", kind: .screenshot,
                                status: status, createdAt: Date(timeIntervalSince1970: createdAt),
                                width: 1, height: 1, bytes: 1, name: "\(id).png")
            try store.upsert(row, in: d, acknowledged: acknowledged)
        }
    }

    func testCandidatesAreTheLocalCapturesTheLogHasNeverSeen() throws {
        try insert("MINE")
        try insert("TRASHED", status: .trashed)
        try insert("FROMLOG", acknowledged: true)       // pulled, already in the log
        try insert("SWEEPING", status: .sweeping)       // F40: local state, never seeded

        XCTAssertEqual(try store.seedCandidateCount(), 2)
    }

    func testSeedingQueuesEveryRowAndItsBytes() throws {
        try insert("KEPT")
        try insert("TRASHED", status: .trashed)

        XCTAssertEqual(try store.seed(deviceID: deviceID, observed: 0), 2)

        let kinds = Dictionary(uniqueKeysWithValues: try store.pending().map { ($0.captureID, $0.kind) })
        XCTAssertEqual(kinds["KEPT"], .upsert)
        XCTAssertEqual(kinds["TRASHED"], .trash, "so the server's sweep sees it (F64)")
        XCTAssertEqual(Set(try store.queuedUploads()), ["KEPT", "TRASHED"])
        XCTAssertTrue(try store.isSeeded())
    }

    func testSeedingTwiceAddsNothingTheSecondTime() throws {
        try insert("ONE")
        try store.seed(deviceID: deviceID, observed: 0)
        XCTAssertEqual(try store.seed(deviceID: deviceID, observed: 0), 0, "F63: no duplicates")
        XCTAssertEqual(try store.pending().count, 1)
    }

    func testNewCapturesUploadBeforeSeededOnesAndNewestFirst() throws {
        try insert("OLD", createdAt: 1_000)
        try insert("NEWER", createdAt: 2_000)
        try store.seed(deviceID: deviceID, observed: 0)
        try insert("JUST_TAKEN", createdAt: 500)       // older timestamp, but a live change
        try store.queueUpload("JUST_TAKEN")

        XCTAssertEqual(try store.dueUploads(), ["JUST_TAKEN", "NEWER", "OLD"],
                       "a live change never waits behind the seed; the seed goes newest first")
    }
}

// MARK: - F72, F73, and thumbnails end to end through the service

final class SeedingServiceTests: XCTestCase {
    var directory: URL!
    var root: URL!
    var library: Library!
    var saved: (key: String?, token: String?, approved: Bool, confirmed: Bool,
                enabled: Bool, root: URL)!
    let deviceID = "01JBAAAAAAAAAAAAAAAAAAAAAA"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-seedsvc-\(UUID().uuidString)")
        root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        saved = (Keychain.libraryKey, Keychain.libraryDeviceToken, LibraryApproval.isApproved,
                 LibrarySeed.isConfirmed, Settings.shared.libraryEnabled, Settings.shared.libraryRoot)
        Settings.shared.libraryRoot = root
        Settings.shared.libraryEnabled = true
        LibraryService.createKey()
        Keychain.libraryDeviceToken = "darrin.approved"
        LibraryApproval.isApproved = true
        LibrarySeed.isConfirmed = false
        library = try Library(db: try KaptureCore.Database(directory: directory), root: root)
    }

    override func tearDownWithError() throws {
        Keychain.libraryKey = saved.key
        Keychain.libraryDeviceToken = saved.token
        LibraryApproval.isApproved = saved.approved
        LibrarySeed.isConfirmed = saved.confirmed
        Settings.shared.libraryEnabled = saved.enabled
        Settings.shared.libraryRoot = saved.root
        try? FileManager.default.removeItem(at: directory)
    }

    /// A capture made before sync was ever on: written while the library is off, so nothing
    /// publishes it, which is exactly the library seeding has to hand over.
    func preexistingCapture() throws -> CaptureRecord {
        let file = directory.appendingPathComponent("shot.png")
        try Media.png(file, width: 800, height: 600)
        Settings.shared.libraryEnabled = false
        defer { Settings.shared.libraryEnabled = true }
        let (record, _) = try library.storePNG(try Data(contentsOf: file), width: 800, height: 600,
                                               sourceApp: nil, windowTitle: nil, screenID: nil)
        return record
    }

    func testAJoiningMacAsksBeforeAddingItsCaptures() async throws {
        _ = try preexistingCapture()
        let service = LibraryService()
        let store = SyncStore(db: library.db, crypto: LibraryCrypto(key: LibraryService.existingKey()!))
        let blobs = FlakyBlobs(failures: 0)
        _ = await service.start(db: library.db, deviceID: deviceID,
                                transport: FlakyTransport(blobs: blobs, log: FakeLog(), writer: deviceID))

        await service.syncNow()

        let pending = await service.pendingSeedCount()
        XCTAssertEqual(pending, 1, "the pane states the count (F72)")
        XCTAssertTrue(try store.queuedUploads().isEmpty, "and nothing is uploaded before the answer")
        let stored = await blobs.stored
        XCTAssertTrue(stored.isEmpty)
        await service.stop()
    }

    func testConfirmingSeedsAndUploadsBytesAndThumbnail() async throws {
        let record = try preexistingCapture()
        let service = LibraryService()
        let store = SyncStore(db: library.db, crypto: LibraryCrypto(key: LibraryService.existingKey()!))
        let blobs = FlakyBlobs(failures: 0)
        _ = await service.start(db: library.db, deviceID: deviceID,
                                transport: FlakyTransport(blobs: blobs, log: FakeLog(), writer: deviceID))

        await service.confirmSeed()

        XCTAssertTrue(try store.isSeeded())
        let stored = await blobs.stored
        XCTAssertTrue(stored.keys.contains { $0.hasPrefix("blob/") }, "the full-size bytes")
        XCTAssertTrue(stored.keys.contains { $0.hasPrefix("thumb/") }, "and a thumbnail (F67)")
        let row = try XCTUnwrap(try store.localRows()[record.id]?.row)
        XCTAssertNotNil(row.blobs[.thumb], "the row names its thumbnail, so other Macs fetch it")
        await service.stop()
    }

    func testAMacWithNothingLocalNeedsNoConfirmation() async throws {
        // F73: an empty Mac joining a library is not a merge.
        let service = LibraryService()
        let store = SyncStore(db: library.db, crypto: LibraryCrypto(key: LibraryService.existingKey()!))
        _ = await service.start(db: library.db, deviceID: deviceID,
                                transport: FlakyTransport(blobs: FlakyBlobs(failures: 0),
                                                          log: FakeLog(), writer: deviceID))
        await service.syncNow()

        XCTAssertTrue(try store.isSeeded())
        await service.stop()
    }

    func testAPulledThumbnailIsFetchedForTheGrid() async throws {
        // Another Mac's capture: a row naming a thumbnail, sealed with the shared key.
        let crypto = LibraryCrypto(key: LibraryService.existingKey()!)
        let blobs = FlakyBlobs(failures: 0)
        let other = "01JBBBBBBBBBBBBBBBBBBBBBBB"
        let file = directory.appendingPathComponent("theirs.png")
        try Media.png(file, width: 600, height: 400)
        let made = await Thumbnailer.jpeg(for: file, kind: .screenshot)
        let jpeg = try XCTUnwrap(made)
        let locator = BlobLocatorRef(purpose: .thumb, revision: 0, writer: other,
                                     capture: crypto.blind("THEIRS"))
        try await blobs.put(try crypto.seal(jpeg, scope: .blob(purpose: .thumb,
                                                                capture: locator.capture,
                                                                revision: 0), writer: other),
                            at: locator)
        let store = SyncStore(db: library.db, crypto: crypto, root: root)
        var result = MergeResult()
        result.upserts = [SyncedRow(
            captureID: "THEIRS", lamport: 3, deviceID: other, kind: .screenshot, status: .kept,
            createdAt: Date(), width: 600, height: 400, bytes: 1, name: "theirs.png",
            blobs: [.thumb: BlobLocator(revision: 0, writer: other, capture: locator.capture)])]
        try store.apply(result, cursor: nil, deviceID: deviceID)

        let service = LibraryService()
        _ = await service.start(db: library.db, deviceID: deviceID,
                                transport: FlakyTransport(blobs: blobs, log: FakeLog(), writer: deviceID))
        await service.fetchThumbnails()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: LibraryService.thumbnailURL(for: "THEIRS").path),
            "the grid draws a capture this Mac has no file for from this")
        try? FileManager.default.removeItem(at: LibraryService.thumbnailURL(for: "THEIRS"))
        await service.stop()
    }
}
