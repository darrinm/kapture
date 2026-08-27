// The After Capture list and the Shared scope. Both are settings/query logic that decides what
// happens to every capture, so they get tests rather than a manual click-through.
import XCTest
@testable import KaptureCore

final class CaptureActionTests: XCTestCase {
    private let key = "afterCaptureActions"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: "copyAfterCapture")
        super.tearDown()
    }

    /// Upgrading must not silently change what happens after a capture: someone who had
    /// copy-to-clipboard on keeps it, and someone who had it off does not suddenly get it.
    func testMigratesTheOldCopyAfterCaptureFlag() {
        UserDefaults.standard.set(true, forKey: "copyAfterCapture")
        XCTAssertEqual(Settings.shared.afterCaptureActions, [.copy])

        UserDefaults.standard.set(false, forKey: "copyAfterCapture")
        XCTAssertEqual(Settings.shared.afterCaptureActions, [])
    }

    /// Once the user has touched the list, the old flag no longer speaks for them.
    func testAnExplicitEmptyListSurvivesTheOldFlag() {
        UserDefaults.standard.set(true, forKey: "copyAfterCapture")
        Settings.shared.afterCaptureActions = []
        XCTAssertEqual(Settings.shared.afterCaptureActions, [])
    }

    func testActionsAreStoredInCanonicalOrder() {
        Settings.shared.afterCaptureActions = [.share, .copy, .pin]
        XCTAssertEqual(Settings.shared.afterCaptureActions, [.copy, .pin, .share],
                       "copy has to run before anything that opens a window")
    }

    func testTogglingOneActionLeavesTheOthers() {
        Settings.shared.afterCaptureActions = [.copy, .save]
        Settings.shared.setAfterCaptureAction(.pin, enabled: true)
        XCTAssertEqual(Settings.shared.afterCaptureActions, [.copy, .save, .pin])
        Settings.shared.setAfterCaptureAction(.save, enabled: false)
        XCTAssertEqual(Settings.shared.afterCaptureActions, [.copy, .pin])
        // toggling off something already off is not an error
        Settings.shared.setAfterCaptureAction(.save, enabled: false)
        XCTAssertEqual(Settings.shared.afterCaptureActions, [.copy, .pin])
    }

    /// A stored value from a newer version that lists an action this build doesn't know about
    /// must not crash or poison the rest of the list.
    func testUnknownStoredActionIsIgnored() {
        UserDefaults.standard.set(["copy", "teleport"], forKey: key)
        XCTAssertEqual(Settings.shared.afterCaptureActions, [.copy])
    }
}

final class SharedScopeTests: XCTestCase {
    func testSharedScopeReturnsOnlySharedCaptures() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(directory: dir.appendingPathComponent("appsupport"))
        let lib = try Library(db: db, root: dir.appendingPathComponent("root"))

        let (shared, _) = try lib.storePNG(Data([1]), width: 1, height: 1,
                                           sourceApp: nil, windowTitle: nil, screenID: nil)
        let (unshared, _) = try lib.storePNG(Data([2]), width: 1, height: 1,
                                             sourceApp: nil, windowTitle: nil, screenID: nil)
        try lib.setShareLink(shared.id, url: "https://kapture.sh/abc12345")

        let results = lib.search(scope: .shared).map(\.id)
        XCTAssertEqual(results, [shared.id])
        XCTAssertFalse(results.contains(unshared.id))

        // and a revoked link drops out of the scope again
        try lib.setShareLink(shared.id, url: nil)
        XCTAssertTrue(lib.search(scope: .shared).isEmpty)

        // the other scopes still see both
        XCTAssertEqual(lib.search(scope: .all).count, 2)
    }
}
