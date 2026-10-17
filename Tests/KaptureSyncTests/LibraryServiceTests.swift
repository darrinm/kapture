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

    func testAnEnrolledMacWithoutTheKeyReportsLockedRatherThanEmpty() async throws {
        // F86 is the whole point: "empty" and "locked" are indistinguishable to someone who
        // thinks they have just lost a year of captures, and only one of them is true. Locked
        // means enrolled and keyless — the credential exists, the key does not.
        Settings.shared.libraryEnabled = true
        let previousKey = Keychain.libraryKey
        let previousToken = Keychain.libraryDeviceToken
        Keychain.libraryKey = nil
        Keychain.libraryDeviceToken = "a-device-credential"
        defer {
            Keychain.libraryKey = previousKey
            Keychain.libraryDeviceToken = previousToken
        }

        let state = await LibraryService().start(db: database, deviceID: ULID.generate())

        XCTAssertEqual(state, .locked)
    }

    func testAFreshMacCanReachTheSetupScreen() async throws {
        // The review's finding 2: with the toggle on, a Mac with no credential went straight to
        // `.locked`, and "Create a library here" was unreachable. A screenshot showed the setup
        // screen only because the harness never started the service.
        Settings.shared.libraryEnabled = true
        let previousKey = Keychain.libraryKey
        let previousToken = Keychain.libraryDeviceToken
        Keychain.libraryKey = nil
        Keychain.libraryDeviceToken = nil
        defer {
            Keychain.libraryKey = previousKey
            Keychain.libraryDeviceToken = previousToken
        }

        let state = await LibraryService().start(db: database, deviceID: ULID.generate())

        XCTAssertEqual(state, .needsSetup)
    }

    func testAMacWithTheKeyButNoCredentialCanStillJoin() async throws {
        // The key arrives through iCloud Keychain before this Mac has ever enrolled; that is a
        // Mac that needs to join, not one awaiting approval.
        Settings.shared.libraryEnabled = true
        let previousKey = Keychain.libraryKey
        let previousToken = Keychain.libraryDeviceToken
        LibraryService.createKey()
        Keychain.libraryDeviceToken = nil
        defer {
            Keychain.libraryKey = previousKey
            Keychain.libraryDeviceToken = previousToken
        }

        let state = await LibraryService().start(db: database, deviceID: ULID.generate())

        XCTAssertEqual(state, .needsSetup)
    }

    func testAnUnapprovedEnrolmentIsNotReportedAsReady() async throws {
        // Finding 13: a 202 enrolment stores a token the server refuses until approval, and
        // "a token exists" was read as ready.
        Settings.shared.libraryEnabled = true
        let previousKey = Keychain.libraryKey
        let previousToken = Keychain.libraryDeviceToken
        let previousApproval = LibraryApproval.isApproved
        LibraryService.createKey()
        Keychain.libraryDeviceToken = "pending-credential"
        LibraryApproval.isApproved = false
        defer {
            Keychain.libraryKey = previousKey
            Keychain.libraryDeviceToken = previousToken
            LibraryApproval.isApproved = previousApproval
        }

        let service = LibraryService()
        let state = await service.start(db: database, deviceID: ULID.generate(),
                                        transport: RefusingTransport())

        XCTAssertEqual(state, .awaitingApproval)
    }

    func testApprovalArrivingLaterReturnsTheServiceToReady() async throws {
        // Finding 12: after one 403, nothing ever set `.ready` again.
        Settings.shared.libraryEnabled = true
        let previousKey = Keychain.libraryKey
        let previousToken = Keychain.libraryDeviceToken
        let previousApproval = LibraryApproval.isApproved
        LibraryService.createKey()
        Keychain.libraryDeviceToken = "pending-credential"
        LibraryApproval.isApproved = false
        defer {
            Keychain.libraryKey = previousKey
            Keychain.libraryDeviceToken = previousToken
            LibraryApproval.isApproved = previousApproval
        }

        let gate = ApprovalGate()
        let service = LibraryService()
        let before = await service.start(db: database, deviceID: ULID.generate(),
                                         transport: GatedTransport(gate: gate))
        XCTAssertEqual(before, .awaitingApproval)

        await gate.approve()
        await service.syncNow()

        let after = await service.currentState()
        XCTAssertEqual(after, .ready)
        XCTAssertTrue(LibraryApproval.isApproved)
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


/// A server that answers every call with F113's "awaiting approval".
struct RefusingTransport: LibraryTransport {
    func refuse() -> SyncFailure { SyncFailure("awaiting approval", awaitingApproval: true) }
    func changes(since: Int64, limit: Int) async throws -> ChangesPage { throw refuse() }
    func push(_ ops: [OutgoingOp]) async throws -> PushOutcome { throw refuse() }
    func snapshotClaim(supportsV: Int, seq: Int64) async throws -> Bool { throw refuse() }
    func putBlob(_ data: Data, at locator: BlobLocatorRef) async throws { throw refuse() }
    func getBlob(_ locator: BlobLocatorRef) async throws -> Data { throw refuse() }
    func putSnapshot(_ data: Data, seq: Int64) async throws { throw refuse() }
    func getSnapshot(seq: Int64, writer: String) async throws -> Data { throw refuse() }
    func acquireSweepLease(windowMs: Int64) async throws -> SweepLease { throw refuse() }
}

actor ApprovalGate {
    private(set) var approved = false
    func approve() { approved = true }
}

/// Refuses until the gate is approved, then behaves like an empty log.
struct GatedTransport: LibraryTransport {
    let gate: ApprovalGate
    func check() async throws {
        guard await gate.approved else {
            throw SyncFailure("awaiting approval", awaitingApproval: true)
        }
    }
    func changes(since: Int64, limit: Int) async throws -> ChangesPage {
        try await check()
        return ChangesPage(ops: [], head: since, oldestRetained: 0)
    }
    func push(_ ops: [OutgoingOp]) async throws -> PushOutcome {
        try await check()
        return PushOutcome(assigned: ops.enumerated().map { .init(opID: $1.opID, seq: Int64($0 + 1)) },
                           rejected: [], head: Int64(ops.count))
    }
    func snapshotClaim(supportsV: Int, seq: Int64) async throws -> Bool { try await check(); return false }
    func putBlob(_ data: Data, at locator: BlobLocatorRef) async throws { try await check() }
    func getBlob(_ locator: BlobLocatorRef) async throws -> Data { try await check(); return Data() }
    func putSnapshot(_ data: Data, seq: Int64) async throws { try await check() }
    func getSnapshot(seq: Int64, writer: String) async throws -> Data { try await check(); return Data() }
    func acquireSweepLease(windowMs: Int64) async throws -> SweepLease {
        try await check()
        return SweepLease(granted: false)
    }
}
