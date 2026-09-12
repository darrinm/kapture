// Bytes: what syncs eagerly, what is fetched when opened, and what gets evicted (§8).
//
// D3 in one sentence — every Mac holds every row and every thumbnail, and full-resolution bytes
// come down when a capture is actually opened. A recording library is tens to hundreds of
// gigabytes and a laptop should not need all of it.

import Foundation
import GRDB
import KaptureCore

/// Where a capture's pixels are, from this Mac's point of view (F48).
public enum BlobState: String, Codable, Sendable {
    /// The file is here. Either this Mac made the capture or it has fetched it.
    case local
    /// The server has it and this Mac does not. The thumbnail renders; opening fetches.
    case remote
    case fetching
    /// The server has no such revision. Reachable only through data loss or a partial delete,
    /// and shown as such rather than as an empty editor (F50).
    case missing
}

public struct BlobStore: Sendable {
    public let db: KaptureCore.Database
    public let root: URL
    public let crypto: LibraryCrypto
    /// Thumbnails live outside the library root, beside the index: they are derived data, and
    /// the root is the user's folder of real files.
    public let thumbnailDirectory: URL

    public init(db: KaptureCore.Database, root: URL, crypto: LibraryCrypto,
                thumbnailDirectory: URL) {
        self.db = db
        self.root = root
        self.crypto = crypto
        self.thumbnailDirectory = thumbnailDirectory
    }

    // MARK: - Thumbnails (F47)

    /// Long edge 512, JPEG 0.7, target under 60 KB. Ten thousand captures is about 600 MB on
    /// every Mac, which is what makes a complete grid affordable everywhere.
    public static let thumbnailMaxEdge = 512
    public static let thumbnailQuality = 0.7

    public func thumbnailURL(for captureID: String) -> URL {
        thumbnailDirectory.appendingPathComponent("\(captureID).jpg")
    }

    public func hasThumbnail(_ captureID: String) -> Bool {
        FileManager.default.fileExists(atPath: thumbnailURL(for: captureID).path)
    }

    public func writeThumbnail(_ data: Data, for captureID: String) throws {
        try FileManager.default.createDirectory(at: thumbnailDirectory,
                                                withIntermediateDirectories: true)
        try data.write(to: thumbnailURL(for: captureID), options: .atomic)
    }

    // MARK: - State

    public func state(of captureID: String) throws -> BlobState {
        try db.queue.read { d in
            let raw = try String.fetchOne(d, sql: "SELECT blobState FROM captures WHERE id = ?",
                                          arguments: [captureID])
            return raw.flatMap(BlobState.init(rawValue:)) ?? .local
        }
    }

    public func setState(_ state: BlobState, for captureID: String) throws {
        try db.queue.write { d in
            try d.execute(sql: "UPDATE captures SET blobState = ? WHERE id = ?",
                          arguments: [state.rawValue, captureID])
        }
    }

    public func locator(for captureID: String, purpose: BlobPurpose) throws -> BlobLocatorRef? {
        try db.queue.read { d in
            guard let row = try Row.fetchOne(d, sql: """
                SELECT revision, writer, owningCapture FROM blob_cache
                WHERE captureId = ? AND purpose = ?
                """, arguments: [captureID, purpose.rawValue]) else { return nil }
            return BlobLocatorRef(purpose: purpose, revision: row["revision"],
                                  writer: row["writer"], capture: row["owningCapture"])
        }
    }

    public func recordLocator(_ locator: BlobLocatorRef, for captureID: String,
                              bytes: Int) throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO blob_cache (captureId, purpose, revision, writer, owningCapture, bytes, lastOpenedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(captureId, purpose) DO UPDATE SET
                  revision = excluded.revision, writer = excluded.writer,
                  owningCapture = excluded.owningCapture, bytes = excluded.bytes
                """, arguments: [captureID, locator.purpose.rawValue, locator.revision,
                                 locator.writer, locator.capture, bytes, Date()])
        }
    }

    public func noteOpened(_ captureID: String) throws {
        try db.queue.write { d in
            try d.execute(sql: "UPDATE blob_cache SET lastOpenedAt = ? WHERE captureId = ?",
                          arguments: [Date(), captureID])
        }
    }

    // MARK: - Fetching (F48, F49, F50)

    /// Bring a capture's bytes down and write them where its row says they belong.
    ///
    /// A failure leaves the capture `remote` rather than `local` with an empty file: F49 exists
    /// because a silently empty editor is worse than a visible retry.
    @discardableResult
    public func fetch(_ captureID: String, using transport: any LibraryTransport) async throws -> URL {
        guard let locator = try locator(for: captureID, purpose: .blob) else {
            try setState(.missing, for: captureID)
            throw SyncFailure("this capture has no bytes on the server")
        }
        try setState(.fetching, for: captureID)
        do {
            let ciphertext = try await transport.getBlob(locator)
            let plaintext = try crypto.open(
                ciphertext,
                scope: .blob(purpose: .blob, capture: locator.capture, revision: locator.revision),
                writer: locator.writer)
            let destination = try destinationURL(for: captureID)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plaintext.write(to: destination, options: .atomic)
            try setState(.local, for: captureID)
            try noteOpened(captureID)
            return destination
        } catch {
            try? setState(.remote, for: captureID)
            throw error
        }
    }

    func destinationURL(for captureID: String) throws -> URL {
        let relPath = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT relPath FROM captures WHERE id = ?",
                                arguments: [captureID])
        }
        guard let relPath else { throw SyncFailure("no such capture") }
        return root.appendingPathComponent(relPath)
    }

    // MARK: - Uploading

    /// Seal and upload a capture's bytes, returning the locator its row should name.
    public func upload(_ captureID: String, from file: URL, revision: Int64,
                       writer: String, using transport: any LibraryTransport) async throws
        -> BlobLocatorRef {
        let plaintext = try Data(contentsOf: file)
        let capture = crypto.blind(captureID)
        let locator = BlobLocatorRef(purpose: .blob, revision: revision,
                                     writer: writer, capture: capture)
        let sealed = try crypto.seal(
            plaintext,
            scope: .blob(purpose: .blob, capture: capture, revision: revision),
            writer: writer)
        try await transport.putBlob(sealed, at: locator)
        try recordLocator(locator, for: captureID, bytes: plaintext.count)
        return locator
    }

    // MARK: - Eviction (F51, F52, F53)

    public struct EvictionPlan: Sendable, Equatable {
        public var evicted: [String] = []
        public var freed: Int = 0
    }

    /// Least-recently-opened, down to the ceiling.
    ///
    /// Two things are never evicted: a capture whose bytes the server has not acknowledged
    /// (F52), because the local copy is the only copy, and anything still named by an unsynced
    /// `.originals/` entry. Eviction is for bytes that can be fetched again, and nothing else.
    public func planEviction(ceilingBytes: Int) throws -> EvictionPlan {
        try db.queue.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT c.id AS id, c.bytes AS bytes, b.lastOpenedAt AS lastOpenedAt
                FROM captures c
                JOIN blob_cache b ON b.captureId = c.id AND b.purpose = 'blob'
                WHERE c.blobState = 'local' AND c.acknowledged = 1
                  AND c.id NOT IN (SELECT captureId FROM sync_outbox)
                  AND c.id NOT IN (SELECT captureId FROM blocked_captures)
                ORDER BY b.lastOpenedAt ASC NULLS FIRST
                """)
            let total = try Int.fetchOne(d, sql: """
                SELECT COALESCE(SUM(bytes), 0) FROM captures WHERE blobState = 'local'
                """) ?? 0

            var plan = EvictionPlan()
            var remaining = total
            for row in rows where remaining > ceilingBytes {
                let id: String = row["id"]
                let bytes: Int = row["bytes"] ?? 0
                plan.evicted.append(id)
                plan.freed += bytes
                remaining -= bytes
            }
            return plan
        }
    }

    /// Carry out a plan: the file goes, the row stays, and the capture becomes `remote`.
    public func evict(_ plan: EvictionPlan) throws {
        for captureID in plan.evicted {
            if let url = try? destinationURL(for: captureID) {
                try? FileManager.default.removeItem(at: url)
            }
            try setState(.remote, for: captureID)
        }
    }

    public func localBytes() throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COALESCE(SUM(bytes), 0) FROM captures WHERE blobState = 'local'
                """) ?? 0
        }
    }
}
