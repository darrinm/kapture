// The encryption scheme (docs/SHARED-LIBRARY.md §4).
//
// Both adversarial reviews found their worst error here, and both times it was the same shape:
// a key derived from something the reader cannot see until it has already decrypted. The first
// test below is the one that would have caught it.

import XCTest
import CryptoKit
@testable import KaptureSync

final class LibraryCryptoTests: XCTestCase {
    let crypto = LibraryCrypto(key: LibraryCrypto.generateKey())

    // MARK: - F95, F126: every derivation input is readable before decryption

    func testARowIsDecryptableFromEnvelopeFactsAlone() {
        // The receiving Mac has never seen this capture. All it holds is what the envelope
        // carries: the opID and the writing device. If the scheme needed the captureID or the
        // row's revision — both inside the payload — this could not be written at all.
        let payload = Data("the row".utf8)
        let sealed = try! crypto.seal(payload, scope: .row(opID: "OP-1"), writer: "device-b")

        let opened = try! crypto.open(sealed, scope: .row(opID: "OP-1"), writer: "device-b")

        XCTAssertEqual(opened, payload)
    }

    func testABlobIsDecryptableFromItsKeyPathAlone() {
        let payload = Data("pixels".utf8)
        let scope = KeyScope.blob(purpose: .blob, capture: "BLINDED-A", revision: 4)
        let sealed = try! crypto.seal(payload, scope: scope, writer: "device-b")

        XCTAssertEqual(try! crypto.open(sealed, scope: scope, writer: "device-b"), payload)
    }

    func testAForkReadsBytesFiledUnderTheCaptureItForkedFrom() {
        // F128: the fork has its own blindedID, but the bytes stay filed under the original and
        // are keyed to it. Deriving from the fork's own id would decrypt nothing.
        let payload = Data("pixels".utf8)
        let original = KeyScope.blob(purpose: .blob, capture: "ORIGINAL", revision: 2)
        let sealed = try! crypto.seal(payload, scope: original, writer: "device-b")

        XCTAssertEqual(try! crypto.open(sealed, scope: original, writer: "device-b"), payload)
        let wrongScope = KeyScope.blob(purpose: .blob, capture: "FORKED", revision: 2)
        XCTAssertThrowsError(try crypto.open(sealed, scope: wrongScope, writer: "device-b"))
    }

    // MARK: - scope separation

    func testEachScopeGetsItsOwnKey() {
        let payload = Data("x".utf8)
        let sealed = try! crypto.seal(payload, scope: .row(opID: "OP-1"), writer: "device-a")

        // A different op, purpose, revision or writer must not open it.
        XCTAssertThrowsError(try crypto.open(sealed, scope: .row(opID: "OP-2"), writer: "device-a"))
        XCTAssertThrowsError(try crypto.open(sealed, scope: .row(opID: "OP-1"), writer: "device-b"))
        XCTAssertThrowsError(try crypto.open(
            sealed, scope: .blob(purpose: .blob, capture: "OP-1", revision: 0), writer: "device-a"))
    }

    func testThumbAndFullResolutionDoNotShareAKey() {
        let payload = Data("x".utf8)
        let full = KeyScope.blob(purpose: .blob, capture: "A", revision: 1)
        let thumb = KeyScope.blob(purpose: .thumb, capture: "A", revision: 1)
        let sealed = try! crypto.seal(payload, scope: full, writer: "d")
        XCTAssertThrowsError(try crypto.open(sealed, scope: thumb, writer: "d"))
    }

    // MARK: - F13: uniqueness rests on the nonce

    func testTwoSealsOfTheSamePlaintextUnderOneKeyDiffer() {
        // A rename re-encrypts a row at an unchanged revision, so the derived key repeats. The
        // nonce is what keeps the ciphertexts distinct.
        let payload = Data("identical".utf8)
        let first = try! crypto.seal(payload, scope: .row(opID: "OP-1"), writer: "d")
        let second = try! crypto.seal(payload, scope: .row(opID: "OP-1"), writer: "d")
        XCTAssertNotEqual(first, second, "a repeated key must not produce a repeated ciphertext")
        XCTAssertEqual(try! crypto.open(second, scope: .row(opID: "OP-1"), writer: "d"), payload)
    }

    func testTamperingIsDetected() {
        var sealed = try! crypto.seal(Data("x".utf8), scope: .row(opID: "OP-1"), writer: "d")
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try crypto.open(sealed, scope: .row(opID: "OP-1"), writer: "d"))
    }

    func testAnotherLibrarysKeyCannotOpenIt() {
        let other = LibraryCrypto(key: LibraryCrypto.generateKey())
        let sealed = try! crypto.seal(Data("x".utf8), scope: .row(opID: "OP-1"), writer: "d")
        XCTAssertThrowsError(try other.open(sealed, scope: .row(opID: "OP-1"), writer: "d"))
    }

    // MARK: - F15: blinding

    func testBlindingIsStableAndHidesTheUlidTimestamp() {
        let captureID = "01JB0000000000000000000000"
        XCTAssertEqual(crypto.blind(captureID), crypto.blind(captureID))
        XCTAssertFalse(crypto.blind(captureID).hasPrefix("01JB"),
                       "a ULID's leading timestamp must not survive blinding")
        XCTAssertEqual(crypto.blind(captureID).count, 26)
    }

    func testBlindingDiffersPerLibrary() {
        let other = LibraryCrypto(key: LibraryCrypto.generateKey())
        XCTAssertNotEqual(crypto.blind("A"), other.blind("A"))
    }

    // MARK: - F14, F85: key identity and recovery

    func testKeyIDIsStableAndDistinguishesLibraries() {
        let other = LibraryCrypto(key: LibraryCrypto.generateKey())
        XCTAssertEqual(crypto.keyID.count, 16)
        XCTAssertNotEqual(crypto.keyID, other.keyID)
    }

    func testARecoveryCodeRoundTripsToTheSameLibrary() {
        let code = crypto.recoveryCode()
        let restored = LibraryCrypto(key: try! LibraryCrypto.key(fromRecoveryCode: code))

        XCTAssertEqual(restored.keyID, crypto.keyID)
        // The real test: it can open what the original sealed.
        let sealed = try! crypto.seal(Data("x".utf8), scope: .row(opID: "OP-1"), writer: "d")
        XCTAssertEqual(try! restored.open(sealed, scope: .row(opID: "OP-1"), writer: "d"),
                       Data("x".utf8))
    }

    func testARecoveryCodeSurvivesBeingWrittenDownBadly() {
        // Grouping dashes, lower case and stray spaces are how a handwritten code comes back.
        let code = crypto.recoveryCode()
        let mangled = "  " + code.lowercased().replacingOccurrences(of: "-", with: " ") + "  "
        let restored = try! LibraryCrypto.key(fromRecoveryCode: mangled)
        XCTAssertEqual(LibraryCrypto(key: restored).keyID, crypto.keyID)
    }

    func testACorruptedRecoveryCodeIsRejectedRatherThanSilentlyWrong() {
        var characters = Array(crypto.recoveryCode())
        let index = characters.firstIndex { $0 != "-" }!
        characters[index] = characters[index] == "A" ? "B" : "A"
        XCTAssertThrowsError(try LibraryCrypto.key(fromRecoveryCode: String(characters)),
                            "a mistyped code must fail the checksum, not open the wrong library")
    }
}
