// Read-only checks for rollout stage 4 (docs/SHARED-LIBRARY-ROLLOUT.md): does the server's
// byte counter agree with what R2 holds, and does a large recording come back from the server
// byte-identical? Nothing here writes to the index or the library, so it can run beside the app.
import CryptoKit
import Foundation
import GRDB
import KaptureCore

public enum LibraryCheck {
    public struct Usage: Decodable, Equatable, Sendable {
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

    /// The multipart path that drifted in stage 4, against the real server: an upload started,
    /// abandoned after one part and started again under the same key (an app restart), a part
    /// sent twice (a lost response), then completed and deleted. Returns the counter and R2's
    /// total after completing and after deleting; each pair should agree.
    ///
    /// The object is `orig/STAGE4MULTIPART/1/<this device>`, which names no capture, and the
    /// blob delete route removes it without adding anything to the log.
    public static func multipartRestartCheck(db: KaptureCore.Database) async throws
        -> (afterUpload: (Usage, Usage), afterDelete: (Usage, Usage)) {
        guard let token = Keychain.libraryDeviceToken else {
            throw SyncFailure("this Mac has no device credential")
        }
        let device = try await db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT deviceID FROM sync_state")
        }
        guard let device else { throw SyncFailure("sync is not enabled") }
        let base = Settings.shared.libraryEndpoint
            .appendingPathComponent("api/library/blob/orig/STAGE4MULTIPART/1/\(device)")

        func send(_ method: String, _ query: [URLQueryItem], _ body: Data? = nil) async throws -> Data {
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            components.queryItems = query.isEmpty ? nil : query
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "content-type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            try HTTPTransport.check(response, data)
            return data
        }
        func begin() async throws -> String {
            let data = try await send("POST", [URLQueryItem(name: "uploads", value: nil)])
            guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["uploadId"]
                as? String else { throw SyncFailure("no uploadId: \(String(decoding: data, as: UTF8.self))") }
            return id
        }
        func part(_ uploadId: String, _ number: Int, _ bytes: Data) async throws -> [String: Any] {
            let data = try await send("PUT", [URLQueryItem(name: "uploadId", value: uploadId),
                                              URLQueryItem(name: "part", value: "\(number)")], bytes)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        let big = Data((0..<(5 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let abandoned = try await begin()
        _ = try await part(abandoned, 1, big)                 // the app quits here
        let uploadId = try await begin()
        _ = try await part(uploadId, 1, big)
        let first = try await part(uploadId, 1, big)          // the response was lost; sent again
        let last = try await part(uploadId, 2, Data("end".utf8))
        let parts = try JSONSerialization.data(withJSONObject: ["parts": [first, last]])
        _ = try await send("POST", [URLQueryItem(name: "uploadId", value: uploadId),
                                    URLQueryItem(name: "complete", value: nil)], parts)
        let afterUpload = (try await usage(reconcile: false), try await usage(reconcile: true))

        _ = try await send("DELETE", [])
        let afterDelete = (try await usage(reconcile: false), try await usage(reconcile: true))
        return (afterUpload, afterDelete)
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
