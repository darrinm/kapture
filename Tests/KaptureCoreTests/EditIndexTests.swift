// Redaction has to reach the search index, not just the pixels. Blurring a password out of a
// capture and then finding it by searching for that password would make the feature a lie.
import XCTest
@testable import KaptureCore

final class EditIndexTests: XCTestCase {
    func testEditingClearsTheTextThatDescribedTheOldPixels() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(directory: dir.appendingPathComponent("appsupport"))
        let lib = try Library(db: db, root: dir.appendingPathComponent("root"))

        let (record, _) = try lib.storePNG(Data([1, 2, 3]), width: 10, height: 10,
                                           sourceApp: nil, windowTitle: nil, screenID: nil)
        try lib.updateSearchText(record.id, ocr: "correcthorsebatterystaple")
        XCTAssertFalse(lib.search("correcthorsebatterystaple").isEmpty,
                       "precondition: the text is indexed before the edit")

        // what a redaction does: new pixels flattened over the old ones
        try lib.applyEdit(record.id, flattenedPNG: Data([4, 5, 6]), layersJSON: "[]",
                          width: 10, height: 10)

        XCTAssertTrue(lib.search("correcthorsebatterystaple").isEmpty,
                      "the redacted text is still findable in the library")
        // the capture itself is still there — only what it used to say is gone
        XCTAssertEqual(lib.search("").count, 1)
    }
}
