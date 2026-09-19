// The general pasteboard holds a concrete URL after a copy, and the AI rename moves the file
// about 30s later. The clipboard is AppKit and not testable here, but the thing it depends on —
// "a move tells me the old and new URL, after it has happened" — is.
import XCTest
@testable import KaptureCore

final class FileMoveTests: XCTestCase {
    private func moves(from lib: Library, during body: () throws -> Void) throws -> [FileMove] {
        var heard: [FileMove] = []
        let observer = NotificationCenter.default.addObserver(forName: Library.fileDidMove, object: lib, queue: nil) {
            guard let move = $0.userInfo?[Library.fileMoveKey] as? FileMove else { return }
            // Posted after the move: the old path is gone and the new one is there.
            XCTAssertFalse(FileManager.default.fileExists(atPath: move.from.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: move.to.path))
            heard.append(move)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try body()
        return heard
    }

    func testARenamePostsTheOldAndNewURL() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        let before = lib.url(for: capture)

        let heard = try moves(from: lib) {
            XCTAssertTrue(lib.applyName(capture.id, baseName: "renamed", tags: [], summary: "", aiState: .namedLocal))
        }
        XCTAssertEqual(heard.map(\.from), [before])
        XCTAssertEqual(heard.map(\.to), [lib.url(for: try record(lib, capture.id))])
        XCTAssertEqual(heard.first?.to.lastPathComponent, "renamed.png")
    }

    func testDiscardAndRestorePostTheirMoves() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = try shot(lib)
        let live = lib.url(for: capture)

        let heard = try moves(from: lib) {
            try lib.discard(capture)
            _ = try XCTUnwrap(lib.restore(id: capture.id))
        }
        XCTAssertEqual(heard.count, 2)
        XCTAssertEqual(heard.first?.from, live)
        XCTAssertEqual(heard.last?.to, live)
    }

    /// A write is a move too, from the staging file — but nothing outside the library ever
    /// held that path, and an unchanged name must not look like a move either.
    func testAStoreAndAnUnchangedNamePostNothing() throws {
        let (lib, dir) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        var capture: CaptureRecord?
        let heard = try moves(from: lib) {
            capture = try shot(lib)
            let name = lib.url(for: try XCTUnwrap(capture)).deletingPathExtension().lastPathComponent
            XCTAssertTrue(lib.applyName(try XCTUnwrap(capture).id, baseName: name, tags: [], summary: "", aiState: .namedLocal))
        }
        XCTAssertTrue(heard.isEmpty)
    }
}
