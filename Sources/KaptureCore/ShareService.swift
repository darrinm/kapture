// Uploading a capture to kapture.sh. The server is a single Worker (see worker/README.md):
// a bearer token identifies the owner, the response carries a permanent unguessable link, and
// the link is the only capability a recipient needs. Nothing is uploaded without an explicit
// share action — this is the second path (after AI naming) by which a capture leaves the Mac.
import Foundation

public struct ShareLink: Sendable, Equatable {
    public let id: String
    public let url: URL
    public let filename: String
    public let bytes: Int
    public let uploadedAt: Date

    public init(id: String, url: URL, filename: String = "", bytes: Int = 0, uploadedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.filename = filename
        self.bytes = bytes
        self.uploadedAt = uploadedAt
    }
}

public struct ShareFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    /// Set when the server refused the token, so the UI can point at Settings instead of retrying.
    public let isAuthFailure: Bool

    public init(_ description: String, isAuthFailure: Bool = false) {
        self.description = description
        self.isAuthFailure = isAuthFailure
    }
}

public enum ShareService {
    /// The Worker's allowlist. A type absent here is refused server-side with 415, so failing
    /// locally keeps the user from waiting on a round trip to learn the same thing.
    static let contentTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "webp": "image/webp", "gif": "image/gif",
        "mp4": "video/mp4", "mov": "video/quicktime",
    ]

    /// Workers cap a request body at 100MB; the Worker itself rejects above 95.
    public static let maxUploadBytes = 95 * 1024 * 1024

    public static var isConfigured: Bool { Keychain.shareToken?.isEmpty == false }

    public static func contentType(for url: URL) -> String? {
        contentTypes[url.pathExtension.lowercased()]
    }

    /// Uploads from disk rather than from memory: a screen recording can be tens of megabytes,
    /// and `upload(for:fromFile:)` streams it instead of holding a second copy in the app.
    public static func upload(fileURL: URL, filename: String? = nil) async throws -> ShareLink {
        guard let token = Keychain.shareToken, !token.isEmpty else {
            throw ShareFailure("no share token — add one in Settings › Sharing", isAuthFailure: true)
        }
        guard let type = contentType(for: fileURL) else {
            throw ShareFailure("kapture.sh does not accept .\(fileURL.pathExtension) files")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxUploadBytes {
            throw ShareFailure("too large to share (\(size / 1_048_576) MB; the limit is 95 MB)")
        }

        var request = URLRequest(url: Settings.shared.shareEndpoint.appendingPathComponent("api/upload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(type, forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(filename ?? fileURL.lastPathComponent, forHTTPHeaderField: "x-filename")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        let json = try decode(data, response)
        guard let id = json["id"] as? String,
              let urlString = json["url"] as? String, let url = URL(string: urlString)
        else { throw ShareFailure("unexpected response from \(Settings.shared.shareEndpoint.host ?? "server")") }
        return ShareLink(id: id, url: url, filename: filename ?? fileURL.lastPathComponent,
                         bytes: size)
    }

    /// Revokes a link. The bytes go with it; the link 404s from then on.
    public static func delete(id: String) async throws {
        guard let token = Keychain.shareToken, !token.isEmpty else {
            throw ShareFailure("no share token", isAuthFailure: true)
        }
        var request = URLRequest(url: Settings.shared.shareEndpoint.appendingPathComponent("api/\(id)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShareFailure("no response") }
        // 404 means the link is already gone, which is the state the caller wanted
        guard http.statusCode == 204 || http.statusCode == 404 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw ShareFailure(json?["error"] as? String ?? "http \(http.statusCode)",
                               isAuthFailure: http.statusCode == 401)
        }
    }

    /// Everything this token has shared, newest first. Used by the Shared filter in the library
    /// to reconcile links made from another Mac.
    public static func list() async throws -> [ShareLink] {
        guard let token = Keychain.shareToken, !token.isEmpty else {
            throw ShareFailure("no share token", isAuthFailure: true)
        }
        var request = URLRequest(url: Settings.shared.shareEndpoint.appendingPathComponent("api/list"))
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try decode(data, response)
        let base = Settings.shared.shareEndpoint
        let items = (json["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let uploaded = (item["uploadedAt"] as? String).flatMap(ISO8601DateFormatter().date(from:))
            return ShareLink(id: id, url: base.appendingPathComponent(id),
                             filename: item["filename"] as? String ?? "",
                             bytes: item["bytes"] as? Int ?? 0,
                             uploadedAt: uploaded ?? Date())
        }
    }

    /// Cheap round trip so Settings can say "connected" before the user relies on it mid-share.
    public static func verifyToken() async throws {
        _ = try await list()
    }

    static func decode(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw ShareFailure("no response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            // the Worker always answers errors as {"error": "..."} — prefer its wording to a code
            let message = json?["error"] as? String ?? "http \(http.statusCode)"
            throw ShareFailure(message, isAuthFailure: http.statusCode == 401)
        }
        guard let json else { throw ShareFailure("malformed response") }
        return json
    }
}
