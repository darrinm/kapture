// Turning the pieces into a feature: keys, enrolment, publishing, and the periodic sync (§6.2 F28).
//
// Everything decision-shaped lives in `SyncMerge`; everything durable lives in `SyncStore`. This
// file holds the code that reads the Keychain, schedules the timer and builds the network
// transport, and it is kept the thinnest of the three.

import Foundation
import CryptoKit
import KaptureCore

public enum LibraryState: Sendable, Equatable {
    /// The toggle is off. The default, and it costs nothing (G6).
    case disabled
    /// The toggle is on and this Mac holds no device credential: create a library, join one, or
    /// enter a recovery code. Without this state a fresh Mac had no route to the setup screen —
    /// turning the toggle on went straight to `.locked`.
    case needsSetup
    /// Enrolled, but this Mac has no library key and can decrypt nothing. Shown as locked and
    /// never as empty (F86).
    case locked
    /// Enrolled with a key, waiting for another Mac or the dashboard to approve it (F113).
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

/// Whether the server has accepted this Mac's credential.
///
/// Remembered rather than inferred from "a token exists". An enrolment answered 202 stores a
/// token the server refuses until the Mac is approved, and treating that as ready showed the
/// running screen — and enabled publishing — on a Mac that could not yet sync.
public enum LibraryApproval {
    static let key = "libraryApproved"

    public static var isApproved: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
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
    private var changeObserver: NSObjectProtocol?
    private var db: KaptureCore.Database?
    private(set) public var state: LibraryState = .disabled
    private(set) public var lastSync: Date?
    private(set) public var lastError: String?

    public init() {}

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

    /// The recovery code for the key this Mac holds (F85).
    ///
    /// Re-displayable rather than shown once and lost: the code is derived from the key, so a
    /// Mac that can still read the library can always print it again. What cannot be recovered
    /// is the key itself once every Mac has lost it (F16).
    public static func recoveryCode() -> String? {
        existingKey().map { LibraryCrypto(key: $0).recoveryCode() }
    }

    public static var hasKey: Bool { Keychain.hasLibraryKey }
    public static var isEnrolled: Bool {
        !(Keychain.libraryDeviceToken ?? "").isEmpty
    }

    /// What this Mac can do, from settings and the Keychain alone.
    ///
    /// `start` gates on it and the Settings pane reads it, so the pane shows the right screen
    /// before the service has run and the two can never disagree about which one that is.
    public static func localState() -> LibraryState {
        guard Settings.shared.libraryEnabled else { return .disabled }
        guard isEnrolled else { return .needsSetup }
        guard hasKey else { return .locked }
        return LibraryApproval.isApproved ? .ready : .awaitingApproval
    }

    /// The running state when the service is up, the local one when it is not.
    public func currentState() -> LibraryState {
        engine == nil ? Self.localState() : state
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
        LibraryApproval.isApproved = result.approved
        return result
    }

    /// Create the library on this Mac and enrol it as the first device (F5).
    ///
    /// Returns the recovery code, which the caller must show before anything is uploaded: after
    /// this point the key is the only thing standing between the owner and a library nobody can
    /// read, the operator included (F16).
    public static func createLibrary(ownerToken: String,
                                     deviceName: String) async throws -> (EnrolmentResult, String) {
        if existingKey() == nil { _ = createKey() }
        let result = try await enrol(ownerToken: ownerToken, deviceName: deviceName)
        guard let code = recoveryCode() else { throw SyncFailure("the key could not be read back") }
        return (result, code)
    }

    // MARK: - Device administration (§3.3)

    public func devices() async throws -> [DeviceInfo] {
        guard let transport else { throw SyncFailure("sync is not running") }
        return try await transport.devices()
    }

    public func approve(deviceID: String) async throws {
        guard let transport else { throw SyncFailure("sync is not running") }
        try await transport.approve(deviceID: deviceID)
    }

    public func revoke(deviceID: String) async throws {
        guard let transport else { throw SyncFailure("sync is not running") }
        try await transport.revoke(deviceID: deviceID)
    }

    // MARK: - Lifecycle

    /// Bring the service up for a database, or take it down if this Mac cannot sync. Returns the
    /// state the UI should show.
    @discardableResult
    public func start(db: KaptureCore.Database, deviceID: String,
                      transport injected: (any LibraryTransport)? = nil) async -> LibraryState {
        let local = Self.localState()
        guard local == .ready || local == .awaitingApproval,
              let key = Self.existingKey(),
              let token = Keychain.libraryDeviceToken, !token.isEmpty else {
            tearDown()
            state = local
            return state
        }

        let root = Settings.shared.libraryRoot
        let crypto = LibraryCrypto(key: key)
        let store = SyncStore(db: db, crypto: crypto, root: root)
        if ((try? store.identity()) ?? nil) == nil {
            _ = try? store.enable(deviceID: deviceID)
        }
        // F135: a build whose capabilities widened goes back for what it skipped.
        _ = try? store.replaySkippedIfCapabilitiesWidened()
        self.store = store
        let blobs = BlobStore(db: db, root: root, crypto: crypto,
                              thumbnailDirectory: Self.thumbnailDirectory())
        self.blobs = blobs
        // One transport for the whole session. Rebuilding it per call read the Keychain again
        // and gave uploads and ops two sources of truth for the endpoint and the credential,
        // which can disagree within a session after a re-enrolment.
        let transport = injected ?? HTTPTransport(endpoint: Settings.shared.libraryEndpoint,
                                                  deviceToken: token)
        self.transport = transport
        self.sweeper = SweepCoordinator(store: store, blobs: blobs, deviceID: deviceID)
        self.engine = SyncEngine(store: store, transport: transport, deviceID: deviceID)
        self.db = db
        installChangeObserver(for: db)
        state = local
        startTimer()
        // An unapproved Mac asks once now, so a fresh approval and "Check again" both take
        // effect without waiting for the five-minute timer.
        if state == .awaitingApproval { await syncNow() }
        return state
    }

    public func stop() {
        tearDown()
        state = .disabled
    }

    private func tearDown() {
        timer?.cancel()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        engine = nil
        store = nil
        blobs = nil
        transport = nil
        sweeper = nil
        db = nil
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

    // MARK: - Hearing about changes

    /// Every capture change `Library` commits, published to the log.
    ///
    /// This replaces publishing from individual call sites, which reached only new screenshots.
    /// The notification is posted on the operation's own thread while its lock is held, so the
    /// handler hops onto this actor before anything touches the database.
    ///
    /// Only changes from the library whose database this service syncs: the notification is
    /// posted by every `Library`, and publishing another library's capture id would queue an
    /// op for a row this store has never held.
    private func installChangeObserver(for db: KaptureCore.Database) {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        let synced = ObjectIdentifier(db)
        changeObserver = NotificationCenter.default.addObserver(
            forName: Library.captureDidChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let library = note.object as? Library, ObjectIdentifier(library.db) == synced,
                  let change = note.userInfo?[Library.captureChangeKey] as? CaptureChange
            else { return }
            Task { await self?.handle(change) }
        }
    }

    func handle(_ change: CaptureChange) async {
        guard state == .ready else { return }
        switch change.kind {
        case .created, .contentReplaced: await publish(captureID: change.captureID)
        case .metadata: await publishStatus(captureID: change.captureID, kind: .upsert)
        case .trashed: await publishStatus(captureID: change.captureID, kind: .trash)
        case .restored: await publishStatus(captureID: change.captureID, kind: .restore)
        }
    }

    // MARK: - Publishing (§6.3, §8)

    /// Queue a capture's bytes for upload and try now.
    ///
    /// The queue is durable. An upload that fails, or whose response is lost, stays queued and
    /// is retried on the next sync; before, it was logged and the capture never reached the
    /// log at all.
    public func publish(captureID: String) async {
        guard state == .ready, let store else { return }
        do {
            try store.queueUpload(captureID)
        } catch {
            lastError = String(describing: error)
            Log.store.error("library publish failed to queue: \(error)")
            return
        }
        await drainUploads()
    }

    /// Upload what is due, then queue each row that names it. Bytes go first because F32 refuses
    /// an op naming a revision the server does not yet hold.
    func drainUploads() async {
        guard state == .ready, let store, let blobs, let transport,
              let identity = try? store.identity() else { return }
        let root = Settings.shared.libraryRoot
        for captureID in (try? store.dueUploads()) ?? [] {
            do {
                guard let content = try store.currentContent(of: captureID) else {
                    try store.dropUpload(captureID)        // the capture is gone
                    continue
                }
                let file = root.appendingPathComponent(content.relPath)
                if FileManager.default.fileExists(atPath: file.path) {
                    _ = try await blobs.upload(captureID, from: file, revision: content.revision,
                                               writer: identity.deviceID, using: transport)
                }
                try store.completeUpload(captureID, observed: identity.cursor,
                                         deviceID: identity.deviceID)
                lastError = nil
            } catch {
                try? store.deferUpload(captureID, error: String(describing: error))
                lastError = String(describing: error)
                Log.store.error("library upload failed, will retry: \(error)")
            }
        }
    }

    /// Queue a change to the row with no bytes to move: a status, a rename, OCR text.
    public func publishStatus(captureID: String, kind: OpKind) async {
        guard state == .ready, let store, let identity = try? store.identity() else { return }
        do {
            try store.enqueueCurrentRow(captureID, kind: kind, observed: identity.cursor,
                                        deviceID: identity.deviceID)
        } catch {
            Log.store.error("library status publish failed: \(error)")
        }
    }

    /// Bring a capture's bytes here before anything reads its file (F48).
    ///
    /// Returns nil when there is nothing to do — sync is off, or the file is already local — so
    /// a caller can open `library.url(for:)` either way.
    @discardableResult
    public func materialize(captureID: String) async throws -> URL? {
        guard state == .ready, let blobs, let transport else { return nil }
        if (try? blobs.state(of: captureID)) == .local { return nil }
        return try await blobs.fetch(captureID, using: transport)
    }

    // MARK: - Sweeping and syncing

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
            _ = try? await sweeper.snapshotIfNeeded(using: transport)
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
        if state == .ready { await drainUploads() }
        do {
            let summary = try await engine.syncOnce()
            lastSync = Date()
            lastError = nil
            // A successful round trip is the server's answer to "is this Mac approved", and the
            // only way back to `.ready` from `.awaitingApproval`.
            LibraryApproval.isApproved = true
            state = .ready
            return summary
        } catch let failure as SyncFailure {
            lastError = failure.description
            if failure.awaitingApproval {
                LibraryApproval.isApproved = false
                state = .awaitingApproval
            }
            Log.store.error("library sync failed: \(failure.description)")
            return nil
        } catch {
            lastError = error.localizedDescription
            Log.store.error("library sync failed: \(error)")
            return nil
        }
    }
}
