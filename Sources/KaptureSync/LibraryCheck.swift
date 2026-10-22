// Read-only checks for rollout stage 4 (docs/SHARED-LIBRARY-ROLLOUT.md): does the server's
// byte counter agree with what R2 holds, and does a large recording come back from the server
// byte-identical? Nothing here writes to the index or the library, so it can run beside the app.
import CryptoKit
import Foundation
import GRDB
import KaptureCore

public enum LibraryCheck {
    public struct Usage: Decodable, Sendable {
        public let storedBytes: Int64
        public let storedObjects: Int64
    }

    public struct RoundTrip: Sendable {
        public let captureID: String
        public let relPath: String
        public let bytes: Int
        public let matches: Bool
        public let seconds: Double
    }

    /// The stored-byte counter, or with `reconcile` the total recomputed from R2 (F76).
    /// Reconciling also resets the counter to that total.
    public static func usage(reconcile: Bool) async throws -> Usage {
        guard let token = Keychain.libraryDeviceToken else {
            throw SyncFailure("this Mac has no device credential")
        }
        var components = URLComponents(
            url: Settings.shared.libraryEndpoint.appendingPathComponent("api/library/usage"),
            resolvingAgainstBaseURL: false)!
        if reconcile { components.queryItems = [URLQueryItem(name: "reconcile", value: "1")] }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPTransport.check(response, data)
        return try JSONDecoder().decode(Usage.self, from: data)
    }

    /// Downloads the largest recording of at least `minBytes` whose bytes the server holds,
    /// decrypts it in memory, and compares it with the file on disk. Nil when no recording that
    /// large has uploaded yet.
    public static func largestRecordingRoundTrip(db: KaptureCore.Database, root: URL,
                                                 minBytes: Int) async throws -> RoundTrip? {
        guard let key = LibraryService.existingKey(), let token = Keychain.libraryDeviceToken
        else { throw SyncFailure("this Mac has no library key or device credential") }
        let row = try await db.queue.read { d in
            try Row.fetchOne(d, sql: """
                SELECT c.id, c.relPath, c.bytes, b.revision, b.writer, b.owningCapture
                FROM captures c JOIN blob_cache b ON b.captureId = c.id AND b.purpose = 'blob'
                WHERE c.kind = 'recording' AND c.bytes >= ?
                ORDER BY c.bytes DESC LIMIT 1
                """, arguments: [minBytes])
        }
        guard let row else { return nil }
        let captureID: String = row["id"], relPath: String = row["relPath"]
        let locator = BlobLocatorRef(purpose: .blob, revision: row["revision"],
                                     writer: row["writer"], capture: row["owningCapture"])
        let transport = HTTPTransport(endpoint: Settings.shared.libraryEndpoint,
                                      deviceToken: token)
        let started = Date()
        let ciphertext = try await transport.getBlob(locator)
        let plaintext = try LibraryCrypto(key: key).open(
            ciphertext,
            scope: .blob(purpose: .blob, capture: locator.capture, revision: locator.revision),
            writer: locator.writer)
        let seconds = Date().timeIntervalSince(started)
        let local = try Data(contentsOf: root.appendingPathComponent(relPath),
                             options: .mappedIfSafe)
        return RoundTrip(captureID: captureID, relPath: relPath, bytes: plaintext.count,
                         matches: SHA256.hash(data: plaintext) == SHA256.hash(data: local),
                         seconds: seconds)
    }
}
