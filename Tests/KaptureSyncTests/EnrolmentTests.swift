// The path from off to running (rollout stage 1).
//
// The feature was complete and unreachable for three commits: nothing called `enrol`,
// `createKey` or `adoptKey`, so the toggle could only ever reach `.locked`. These cover the
// entry points the Settings pane now drives.

import XCTest
import CryptoKit
import KaptureCore
@testable import KaptureSync

final class EnrolmentTests: XCTestCase {
    var savedKey: String?
    var savedToken: String?

    override func setUpWithError() throws {
        savedKey = Keychain.libraryKey
        savedToken = Keychain.libraryDeviceToken
        Keychain.libraryKey = nil
        Keychain.libraryDeviceToken = nil
    }

    override func tearDownWithError() throws {
        Keychain.libraryKey = savedKey
        Keychain.libraryDeviceToken = savedToken
    }

    // MARK: - F85: the recovery code

    func testCreatingAKeyMakesARecoveryCodeAvailable() throws {
        XCTAssertNil(LibraryService.recoveryCode(), "no key, no code")

        LibraryService.createKey()

        let code = try XCTUnwrap(LibraryService.recoveryCode())
        XCTAssertFalse(code.isEmpty)
        XCTAssertTrue(LibraryService.hasKey)
    }

    func testTheRecoveryCodeIsRedisplayableRatherThanShownOnce() throws {
        // It is derived from the key, so a Mac that can still read the library can always print
        // it again. What cannot be recovered is the key once every Mac has lost it (F16).
        LibraryService.createKey()
        let first = try XCTUnwrap(LibraryService.recoveryCode())
        let second = try XCTUnwrap(LibraryService.recoveryCode())
        XCTAssertEqual(first, second)
    }

    func testAdoptingARecoveryCodeGivesThisMacTheSameLibrary() throws {
        LibraryService.createKey()
        let original = try XCTUnwrap(LibraryService.existingKey())
        let code = try XCTUnwrap(LibraryService.recoveryCode())
        let keyID = LibraryCrypto(key: original).keyID

        // A different Mac: no key at all.
        Keychain.libraryKey = nil
        XCTAssertFalse(LibraryService.hasKey)

        try LibraryService.adoptKey(fromRecoveryCode: code)

        let adopted = try XCTUnwrap(LibraryService.existingKey())
        XCTAssertEqual(LibraryCrypto(key: adopted).keyID, keyID)
    }

    func testAdoptingTheSameCodeTwiceIsHarmless() throws {
        LibraryService.createKey()
        let code = try XCTUnwrap(LibraryService.recoveryCode())
        try LibraryService.adoptKey(fromRecoveryCode: code)
        try LibraryService.adoptKey(fromRecoveryCode: code)
        XCTAssertEqual(LibraryService.recoveryCode(), code)
    }

    func testAMistypedRecoveryCodeIsRefusedRatherThanSilentlyWrong() throws {
        LibraryService.createKey()
        let code = try XCTUnwrap(LibraryService.recoveryCode())
        var characters = Array(code)
        let index = try XCTUnwrap(characters.firstIndex { $0 != "-" })
        characters[index] = characters[index] == "A" ? "B" : "A"

        XCTAssertThrowsError(try LibraryService.adoptKey(fromRecoveryCode: String(characters)))
        // And the Mac keeps the key it had, rather than being left with a broken one.
        XCTAssertEqual(LibraryService.recoveryCode(), code)
    }

    // MARK: - enrolment state

    func testEnrolmentStateIsReadableBeforeAnythingIsRunning() {
        XCTAssertFalse(LibraryService.hasKey)
        XCTAssertFalse(LibraryService.isEnrolled)

        LibraryService.createKey()
        XCTAssertTrue(LibraryService.hasKey)
        XCTAssertFalse(LibraryService.isEnrolled, "a key is not a credential")

        Keychain.libraryDeviceToken = "a-device-credential"
        XCTAssertTrue(LibraryService.isEnrolled)
    }

    func testTheDeviceIdIsStableAcrossCalls() {
        // F3: generated once and kept, so the id this Mac enrols with is the id it signs with.
        let defaults = UserDefaults(suiteName: "enrolment-tests-\(UUID().uuidString)")!
        let first = LibraryDeviceID.current(defaults: defaults)
        let second = LibraryDeviceID.current(defaults: defaults)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 26)
    }

    func testTwoMacsGetDifferentDeviceIds() {
        // Restoring the same Keychain onto two Macs must not make them one device.
        let a = UserDefaults(suiteName: "enrolment-a-\(UUID().uuidString)")!
        let b = UserDefaults(suiteName: "enrolment-b-\(UUID().uuidString)")!
        XCTAssertNotEqual(LibraryDeviceID.current(defaults: a),
                          LibraryDeviceID.current(defaults: b))
    }

    func testEnrolRefusesWithoutAKey() async {
        // Enrolling a Mac that cannot decrypt anything would produce the F86 locked state with
        // no way out; the key has to come first.
        do {
            _ = try await LibraryService.enrol(ownerToken: "token", deviceName: "Mac")
            XCTFail("expected a failure")
        } catch let failure as SyncFailure {
            XCTAssertTrue(failure.description.contains("recovery code"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
