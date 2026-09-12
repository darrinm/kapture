// The feature's states (docs/SHARED-LIBRARY.md §3.2, F86, G6).

import XCTest
import CryptoKit
import KaptureCore
@testable import KaptureSync

final class LibraryServiceTests: XCTestCase {
    var directory: URL!
    var database: KaptureCore.Database!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try KaptureCore.Database(directory: directory)
        Settings.shared.libraryEnabled = false
    }

    override func tearDownWithError() throws {
        Settings.shared.libraryEnabled = false
        try? FileManager.default.removeItem(at: directory)
    }

    func testItIsOffUntilEnabled() async throws {
        // G6: a library that is never enabled costs nothing and changes no behaviour.
        let state = await LibraryService().start(db: database, deviceID: ULID.generate())
        XCTAssertEqual(state, .disabled)
    }

    func testAKeylessMacReportsLockedRatherThanEmpty() async throws {
        // F86 is the whole point: "empty" and "locked" are indistinguishable to someone who
        // thinks they have just lost a year of captures, and only one of them is true.
        Settings.shared.libraryEnabled = true
        let previous = Keychain.libraryKey
        Keychain.libraryKey = nil
        defer { Keychain.libraryKey = previous }

        let state = await LibraryService().start(db: database, deviceID: ULID.generate())

        XCTAssertEqual(state, .locked)
    }

    // MARK: - keys and the recovery code

    func testTheRecoveryCodeCarriesTheLibraryBetweenMacs() throws {
        // F85: the only way in for a Mac that cannot get the key from iCloud Keychain.
        let key = LibraryCrypto.generateKey()
        let code = LibraryCrypto(key: key).recoveryCode()

        let adopted = try LibraryCrypto.key(fromRecoveryCode: code)

        XCTAssertEqual(LibraryCrypto(key: adopted).keyID, LibraryCrypto(key: key).keyID)
    }

    func testTheEndpointDefaultsToTheShareWorkerButIsSeparate() {
        // F120, F121: the same Worker serves both, and Settings still names it independently so
        // nothing implies kapture.sh will hold anyone else's library.
        let previous = Settings.shared.shareEndpoint
        defer { Settings.shared.shareEndpoint = previous }
        Settings.shared.shareEndpoint = URL(string: "https://example.test")!
        UserDefaults.standard.removeObject(forKey: "libraryEndpoint")

        XCTAssertEqual(Settings.shared.libraryEndpoint, URL(string: "https://example.test")!)

        Settings.shared.libraryEndpoint = URL(string: "https://library.test")!
        XCTAssertEqual(Settings.shared.libraryEndpoint, URL(string: "https://library.test")!)
        XCTAssertEqual(Settings.shared.shareEndpoint, URL(string: "https://example.test")!)
    }

    func testAnInsecureEndpointIsIgnored() {
        // A bearer token must never go out in the clear, which is the rule shareEndpoint
        // already follows.
        Settings.shared.libraryEndpoint = URL(string: "https://library.test")!
        UserDefaults.standard.set("http://plain.test", forKey: "libraryEndpoint")
        XCTAssertEqual(Settings.shared.libraryEndpoint, Settings.shared.shareEndpoint)
        UserDefaults.standard.removeObject(forKey: "libraryEndpoint")
    }
}
