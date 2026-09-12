// Turning the pieces into a feature: keys, enrolment, and the periodic sync (§6.2 F28).
//
// Everything decision-shaped lives in `SyncMerge`; everything durable lives in `SyncStore`. This
// is the part that knows about the Keychain, the clock and the network, and it is deliberately
// the thinnest of the three.

import Foundation
import CryptoKit
import KaptureCore

public enum LibraryState: Sendable, Equatable {
    /// Off, which is the default and costs nothing (G6).
    case disabled
    /// Enrolled, but this Mac has no library key: it can decrypt nothing and must not pretend
    /// the library is empty (F86).
    case locked
    /// Enrolled and waiting for another device or the dashboard to approve it (F113).
    case awaitingApproval
    case ready
}

/// This Mac's `deviceID` (F3).
///
/// Generated once and kept in UserDefaults rather than the Keychain, deliberately: two Macs
/// restoring the same Keychain must not become the same device, and a synchronized item is
/// exactly how that would happen.
public enum LibraryDeviceID {
    static let key = "libraryDeviceID"

    public static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let generated = ULID.generate()
        defaults.set(generated, forKey: key)
        return generated
    }
}

public actor LibraryService {
    public static let shared = LibraryService()

    private var engine: SyncEngine?
    private var store: SyncStore?
    private var blobs: BlobStore?
    private var transport: (any LibraryTransport)?
    private var sweeper: SweepCoordinator?
    private var timer: Task<Void, Never>?
    private(set) public var state: LibraryState = .disabled
    private(set) public var lastSync: Date?
    private(set) public var lastError: String?

    // MARK: - Keys (F11, F85)

    /// The library key from the iCloud Keychain, or nil when this Mac has never had one.
    public static func existingKey() -> SymmetricKey? {
        guard let encoded = Keychain.libraryKey, let data = Data(base64Encoded: encoded)
        else { return nil }
        return SymmetricKey(data: data)
    }

    /// Create the library's key. Only ever called on the Mac that creates the library; every
    /// other Mac receives it through iCloud Keychain (F5) or the recovery code (F85).
    @discardableResult
    public static func createKey() -> SymmetricKey {
        let key = LibraryCrypto.generateKey()
        Keychain.libraryKey = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        return key
    }

    public static func adoptKey(fromRecoveryCode code: String) throws {
        let key = try LibraryCrypto.key(fromRecoveryCode: code)
        Keychain.libraryKey = key.withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    // MARK: - Enrolment (§3.2)

    /// Enrol this Mac and remember its credential. The owner token is used here and nowhere
    /// else: every later call authenticates as the device (F2).
    public static func enrol(ownerToken: String, deviceName: String) async throws -> EnrolmentResult {
        guard let key = existingKey() else {
            throw SyncFailure("this Mac has no library key — enter the recovery code first")
        }
        // The id this Mac signs its ops with (F3). Minting a fresh one here would register a
        // device the log never hears from: the server stamps each op with the *authenticated*
        // device's id, and a reader derives the row key from it (F12), so an enrolment id that
        // differs from `LibraryDeviceID.current()` makes every op this Mac writes undecryptable.
        let deviceID = LibraryDeviceID.current()
        let result = try await HTTPTransport.enrol(
            endpoint: Settings.shared.libraryEndpoint,
            ownerToken: ownerToken,
            deviceID: deviceID,
            name: deviceName,
            keyID: LibraryCrypto(key: key).keyID)
        Keychain.libraryDeviceToken = result.token
        return result
    }

    // MARK: - Lifecycle

    /// Bring the service up for a database. Returns the state the UI should show.
    @discardableResult
    public func start(db: KaptureCore.Database, deviceID: String) async -> LibraryState {
        guard Settings.shared.libraryEnabled else {
            state = .disabled
            return state
        }
        guard let key = LibraryService.existingKey() else {
            // F86: enrolled but keyless. Showing an empty library here is the one thing this
            // must never do — empty and locked look identical to someone who fears the worst.
            state = .locked
            return state
        }
        guard let token = Keychain.libraryDeviceToken, !token.isEmpty else {
            state = .awaitingApproval
            return state
        }

        let crypto = LibraryCrypto(key: key)
        let store = SyncStore(db: db, crypto: crypto)
        if ((try? store.identity()) ?? nil) == nil {
            _ = try? store.enable(deviceID: deviceID)
        }
        // F135: a build whose capabilities widened goes back for what it skipped.
        _ = try? store.replaySkippedIfCapabilitiesWidened()
        self.store = store
        let blobs = BlobStore(db: db, root: Settings.shared.libraryRoot, crypto: crypto,
                              thumbnailDirectory: Self.thumbnailDirectory())
        self.blobs = blobs
        // One transport for the whole session. Rebuilding it per call read the Keychain again
        // and gave uploads and ops two sources of truth for the endpoint and the credential,
        // which can disagree within a session after a re-enrolment.
        let transport = HTTPTransport(endpoint: Settings.shared.libraryEndpoint,
                                      deviceToken: token)
        self.transport = transport
        self.sweeper = SweepCoordinator(store: store, blobs: blobs, deviceID: deviceID)
        self.engine = SyncEngine(store: store, transport: transport, deviceID: deviceID)
        state = .ready
        startTimer()
        return state
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        engine = nil
        store = nil
        blobs = nil
        transport = nil
        sweeper = nil
        state = .disabled
    }

    /// F28: on enable, on foreground, every 5 minutes, and on demand. There is no push channel
    /// in v1 (§14 Q1), so this is the whole schedule.
    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if Task.isCancelled { return }
                await self?.syncNow()
            }
        }
    }

    /// Derived data lives beside the index, not in the user's folder of real files.
    static func thumbnailDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Kapture/Thumbnails")
    }

    // MARK: - Publishing a capture (§6.3, §8)

    /// Upload a capture's bytes and queue its row.
    ///
    /// This is the caller the byte half of sync was missing: without it no op ever names a blob,
    /// the server's F32 dependency check has nothing to check, and a second Mac receives a row
    /// whose pixels it can never fetch. Bytes go first, because F32 refuses an op naming a
    /// revision the server does not yet hold.
    public func publish(captureID: String, file: URL, revision: Int64) async {
        guard state == .ready, let store, let blobs, let transport else { return }
        let identity = try? store.identity()
        guard let deviceID = identity?.deviceID else { return }

        do {
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try await blobs.upload(captureID, from: file, revision: revision,
                                           writer: deviceID, using: transport)
            }
            // The row is read *after* the upload so it carries the locator the upload recorded
            // (F23, F129), and `enqueue` derives `requires` from it (F98).
            try store.enqueueCurrentRow(captureID, kind: .upsert,
                                        observed: identity?.cursor ?? 0, deviceID: deviceID)
            lastError = nil
        } catch let failure as SyncFailure {
            lastError = failure.description
            Log.store.error("library publish failed: \(failure.description)")
        } catch {
            lastError = error.localizedDescription
            Log.store.error("library publish failed: \(error)")
        }
    }

    /// Queue a status change — a discard or a restore — with no bytes to move.
    public func publishStatus(captureID: String, kind: OpKind) async {
        guard state == .ready, let store else { return }
        guard let identity = try? store.identity() else { return }
        do {
            try store.enqueueCurrentRow(captureID, kind: kind, observed: identity.cursor,
                                        deviceID: identity.deviceID)
        } catch {
            Log.store.error("library status publish failed: \(error)")
        }
    }

    /// Bring a capture's bytes down on demand (F48).
    @discardableResult
    public func materialize(captureID: String) async throws -> URL? {
        guard state == .ready, let blobs, let transport else { return nil }
        return try await blobs.fetch(captureID, using: transport)
    }

    /// One sweep pass (§7.4).
    ///
    /// This is the whole of the trash sweep while the library is shared: `Library.sweepTrash`
    /// stands down (F44), because deleting is the log's decision and only the lease holder may
    /// make it. Without this call nothing sweeps at all once sync is on.
    @discardableResult
    public func sweepNow() async -> SweepCoordinator.SweepOutcome? {
        guard state == .ready, let sweeper, let transport else { return nil }
        do {
            let outcome = try await sweeper.sweep(using: transport,
                                                  cacheCeiling: Settings.shared.libraryCacheBytes)
            if let cursor = try? store?.identity()?.cursor {
                _ = try? await sweeper.snapshotIfNeeded(using: transport,
                                                        opsSinceSnapshot: Int(cursor))
            }
            return outcome
        } catch {
            lastError = String(describing: error)
            Log.store.error("library sweep failed: \(error)")
            return nil
        }
    }

    @discardableResult
    public func syncNow() async -> SyncSummary? {
        guard let engine else { return nil }
        do {
            let summary = try await engine.syncOnce()
            lastSync = Date()
            lastError = nil
            return summary
        } catch let failure as SyncFailure {
            lastError = failure.description
            if failure.awaitingApproval { state = .awaitingApproval }
            Log.store.error("library sync failed: \(failure.description)")
            return nil
        } catch {
            lastError = error.localizedDescription
            Log.store.error("library sync failed: \(error)")
            return nil
        }
    }
}
