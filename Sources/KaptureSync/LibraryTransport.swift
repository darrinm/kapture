// Talking to the library log (docs/SHARED-LIBRARY.md §5.3).
//
// The protocol here is what the engine drives; `LibraryTransport` is the only thing in
// KaptureSync that touches the network, so the engine and the merge stay testable without one.

import Foundation
import KaptureCore

public struct SyncFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public let isAuthFailure: Bool
    /// The device is enrolled but not yet approved (F113): the person has to approve it.
    public let awaitingApproval: Bool

    public init(_ description: String, isAuthFailure: Bool = false,
                awaitingApproval: Bool = false) {
        self.description = description
        self.isAuthFailure = isAuthFailure
        self.awaitingApproval = awaitingApproval
    }
}

/// One op as the wire carries it: the envelope in the clear, the payload sealed.
public struct WireOp: Codable, Sendable, Equatable {
    public var seq: Int64
    public var opID: String
    public var deviceID: String
    public var blindedID: String
    public var v: Int
    public var kind: String
    public var observed: Int64
    public var ciphertext: String

    public init(seq: Int64, opID: String, deviceID: String, blindedID: String, v: Int,
                kind: String, observed: Int64, ciphertext: String) {
        self.seq = seq; self.opID = opID; self.deviceID = deviceID; self.blindedID = blindedID
        self.v = v; self.kind = kind; self.observed = observed; self.ciphertext = ciphertext
    }
}

public struct ChangesPage: Codable, Sendable {
    public var ops: [WireOp]
    public var head: Int64
    public var oldestRetained: Int64
}

public struct PushOutcome: Codable, Sendable {
    public struct Assigned: Codable, Sendable { public var opID: String; public var seq: Int64 }
    public struct Rejected: Codable, Sendable { public var opID: String; public var reason: String }
    public var assigned: [Assigned]
    public var rejected: [Rejected]
    public var head: Int64
}

public struct EnrolmentResult: Sendable {
    public var deviceID: String
    public var token: String
    public var approved: Bool
    public var fingerprint: String
}

/// What the engine needs from a server. A test supplies its own; production uses `HTTPTransport`.
public protocol LibraryTransport: Sendable {
    func changes(since: Int64, limit: Int) async throws -> ChangesPage
    func push(_ ops: [OutgoingOp]) async throws -> PushOutcome
    func snapshotClaim(supportsV: Int, seq: Int64) async throws -> Bool
}

public struct OutgoingOp: Codable, Sendable {
    public var opID: String
    public var blindedID: String
    public var v: Int
    public var kind: String
    public var requires: [BlobLocatorRef]
    public var observed: Int64
    public var ciphertext: String

    public init(opID: String, blindedID: String, v: Int, kind: String,
                requires: [BlobLocatorRef], observed: Int64, ciphertext: String) {
        self.opID = opID; self.blindedID = blindedID; self.v = v; self.kind = kind
        self.requires = requires; self.observed = observed; self.ciphertext = ciphertext
    }
}

/// The real thing. A device credential authorizes every call (F2); the owner token is used only
/// to enrol, which is why it is a separate entry point.
public struct HTTPTransport: LibraryTransport {
    public let endpoint: URL
    public let deviceToken: String
    public let session: URLSession

    public init(endpoint: URL, deviceToken: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.deviceToken = deviceToken
        self.session = session
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "authorization")
        return request
    }

    public func changes(since: Int64, limit: Int = 500) async throws -> ChangesPage {
        var components = URLComponents(
            url: endpoint.appendingPathComponent("api/library/changes"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 60
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(ChangesPage.self, from: data)
    }

    public func push(_ ops: [OutgoingOp]) async throws -> PushOutcome {
        var request = self.request("api/library/ops", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(["ops": ops])
        let (data, response) = try await session.data(for: request)
        // 409 carries a usable body: some ops were admitted and some refused.
        if let http = response as? HTTPURLResponse, http.statusCode == 409 {
            return try JSONDecoder().decode(PushOutcome.self, from: data)
        }
        try Self.check(response, data)
        return try JSONDecoder().decode(PushOutcome.self, from: data)
    }

    public func snapshotClaim(supportsV: Int, seq: Int64) async throws -> Bool {
        var request = self.request("api/library/snapshot", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["supportsV": supportsV, "seq": seq])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncFailure("no response") }
        if http.statusCode == 409 { return false }
        try Self.check(response, data)
        return true
    }

    /// Enrol this Mac (F5, F113). Takes the owner token, not a device credential — this is how a
    /// device gets one. A 202 means the credential exists but awaits approval.
    public static func enrol(endpoint: URL, ownerToken: String, deviceID: String,
                             name: String, keyID: String,
                             session: URLSession = .shared) async throws -> EnrolmentResult {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/library/enroll"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "deviceID": deviceID, "name": name, "platform": "macOS", "keyID": keyID,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncFailure("no response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard http.statusCode == 200 || http.statusCode == 202 else {
            throw SyncFailure(json["error"] as? String ?? "http \(http.statusCode)",
                              isAuthFailure: http.statusCode == 401)
        }
        return EnrolmentResult(
            deviceID: json["deviceID"] as? String ?? deviceID,
            token: json["token"] as? String ?? "",
            approved: json["approved"] as? Bool ?? false,
            fingerprint: json["fingerprint"] as? String ?? "")
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncFailure("no response") }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw SyncFailure(json?["error"] as? String ?? "http \(http.statusCode)",
                              isAuthFailure: http.statusCode == 401,
                              awaitingApproval: http.statusCode == 403)
        }
    }
}
