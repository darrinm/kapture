// Sharing's local half: what the client refuses before it ever reaches the network, and the
// link bookkeeping that decides whether a shared capture's link still describes its pixels.
// The server half is tested in worker/test/worker.test.ts against a real Workers runtime.
import XCTest
@testable import KaptureCore

final class ShareTests: XCTestCase {
    private func makeTempLibrary() throws -> (Library, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(directory: dir.appendingPathComponent("appsupport"))
        let lib = try Library(db: db, root: dir.appendingPathComponent("root"))
        return (lib, dir)
    }

    /// The client's allowlist has to agree with the Worker's, or a share fails after the upload
    /// rather than before it.
    func testContentTypeMatchesTheWorkersAllowlist() {
        let expected = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                        "webp": "image/webp", "gif": "image/gif",
                        "mp4": "video/mp4", "mov": "video/quicktime"]
        for (ext, type) in expected {
            XCTAssertEqual(ShareService.contentType(for: URL(fileURLWithPath: "/tmp/a.\(ext)")), type)
            // and case-insensitively, because Finder-renamed files arrive as .PNG
            XCTAssertEqual(ShareService.contentType(for: URL(fileURLWithPath: "/tmp/a.\(ext.uppercased())")), type)
        }
        XCTAssertNil(ShareService.contentType(for: URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertNil(ShareService.contentType(for: URL(fileURLWithPath: "/tmp/a.svg")))
        XCTAssertNil(ShareService.contentType(for: URL(fileURLWithPath: "/tmp/noextension")))
    }

    /// An unshareable file is refused from what the file itself says, before any Keychain read.
    /// That ordering is load-bearing: the test binary is not the app, so a Keychain read here
    /// blocks on a permission dialog and the suite hangs instead of failing.
    func testUploadRefusesAnUnsupportedTypeBeforeTouchingTheKeychain() async {
        do {
            _ = try await ShareService.upload(fileURL: URL(fileURLWithPath: "/tmp/nothing.pdf"))
            XCTFail("expected a failure")
        } catch let failure as ShareFailure {
            XCTAssertTrue(failure.description.contains("pdf"), "got: \(failure.description)")
            XCTAssertFalse(failure.isAuthFailure, "this is a file problem, not a token problem")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEndpointRejectsANonHTTPSOverride() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "shareEndpoint")
        defer { defaults.set(previous, forKey: "shareEndpoint") }

        defaults.set("http://evil.example", forKey: "shareEndpoint")
        XCTAssertEqual(Settings.shared.shareEndpoint.absoluteString, "https://kapture.sh",
                       "a plaintext endpoint would send the bearer token in the clear")
        defaults.set("https://share.example.com", forKey: "shareEndpoint")
        XCTAssertEqual(Settings.shared.shareEndpoint.absoluteString, "https://share.example.com")
    }

    /// The Worker answers every error as {"error": "..."}; the app shows that wording rather than
    /// a status code, and flags 401 so the UI can send the user to Settings.
    func testDecodeSurfacesTheServersOwnWording() throws {
        func response(_ status: Int) -> URLResponse {
            HTTPURLResponse(url: URL(string: "https://kapture.sh/api/upload")!, statusCode: status,
                            httpVersion: nil, headerFields: nil)!
        }
        let ok = try ShareService.decode(Data(#"{"id":"ab12","url":"https://kapture.sh/ab12"}"#.utf8),
                                         response(200))
        XCTAssertEqual(ok["id"] as? String, "ab12")

        for (status, message, isAuth) in [(401, "unauthorized", true),
                                          (429, "daily byte quota reached", false),
                                          (415, "unsupported content-type: text/html", false)] {
            XCTAssertThrowsError(try ShareService.decode(
                Data("{\"error\":\"\(message)\"}".utf8), response(status))) { error in
                guard let failure = error as? ShareFailure else { return XCTFail("wrong error type") }
                XCTAssertEqual(failure.description, message)
                XCTAssertEqual(failure.isAuthFailure, isAuth)
            }
        }
        // an error with no JSON body still has to say something a user can act on
        XCTAssertThrowsError(try ShareService.decode(Data("gateway timeout".utf8), response(504))) { error in
            XCTAssertEqual((error as? ShareFailure)?.description, "http 504")
        }
    }

    func testSettingALinkClearsTheStaleFlag() throws {
        let (lib, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (record, _) = try lib.storePNG(Data([1, 2, 3]), width: 1, height: 1,
                                           sourceApp: nil, windowTitle: nil, screenID: nil)
        try lib.setShareLink(record.id, url: "https://kapture.sh/abc12345")
        var stored = try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) }
        XCTAssertEqual(stored?.shareURL, "https://kapture.sh/abc12345")
        XCTAssertFalse(stored?.shareStale ?? true)

        // an edit invalidates the link: the bytes behind it are no longer what the library shows
        try lib.applyEdit(record.id, flattenedPNG: Data([4, 5, 6]), layersJSON: "[]", width: 1, height: 1)
        stored = try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) }
        XCTAssertTrue(stored?.shareStale ?? false, "an edited capture's link is out of date")

        // re-sharing replaces the link and clears the flag again
        try lib.setShareLink(record.id, url: "https://kapture.sh/def67890")
        stored = try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) }
        XCTAssertFalse(stored?.shareStale ?? true)

        // and deleting the link leaves nothing behind to copy
        try lib.setShareLink(record.id, url: nil)
        stored = try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) }
        XCTAssertNil(stored?.shareURL)
    }

    /// An unshared capture must never come back stale — the flag is only meaningful next to a URL.
    func testEditingAnUnsharedCaptureLeavesItUnstale() throws {
        let (lib, dir) = try makeTempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (record, _) = try lib.storePNG(Data([1, 2, 3]), width: 1, height: 1,
                                           sourceApp: nil, windowTitle: nil, screenID: nil)
        try lib.applyEdit(record.id, flattenedPNG: Data([4, 5, 6]), layersJSON: "[]", width: 1, height: 1)
        let stored = try lib.db.queue.read { try CaptureRecord.fetchOne($0, key: record.id) }
        XCTAssertFalse(stored?.shareStale ?? true)
        XCTAssertNil(stored?.shareURL)
    }
}
