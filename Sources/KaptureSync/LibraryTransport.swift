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

    public struct Rejected: Codable, Sendable {
        public var opID: String
        /// Why, as a value rather than a sentence.
        ///
        /// This used to be decided by matching substrings of `reason`, which meant rewording a
        /// server message silently changed client behaviour — and classifying a permanent
        /// rejection as retryable re-pushes it every minute forever, which also blocks every
        /// snapshot, because a backing-off op still counts as pending.
        public var code: String?
        public var reason: String

        /// Retrying can never help: the log has already moved past this op.
        public var isPermanent: Bool { code == "tombstoned" || code == "stale-delete" }
    }
    public var assigned: [Assigned]
    public var rejected: [Rejected]
    public var head: Int64
}

/// One device as the server lists it (§5.3).
public struct DeviceInfo: Codable, Sendable, Identifiable, Equatable {
    public var deviceID: String
    public var name: String
    public var platform: String
    public var createdAt: String
    public var lastSeenAt: String?
    public var approved: Bool
    /// Shown on both screens so the person approving sees which Mac they are approving (F124).
    public var fingerprint: String
    public var current: Bool

    public var id: String { deviceID }
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
    /// Create-only (F22). An identical re-PUT is a retry, not a conflict (F99).
    func putBlob(_ data: Data, at locator: BlobLocatorRef) async throws
    func getBlob(_ locator: BlobLocatorRef) async throws -> Data
    func putSnapshot(_ data: Data, seq: Int64) async throws
    func getSnapshot(seq: Int64, writer: String) async throws -> Data
    /// Take the sweep lease and learn which captures are eligible (F43, F45, F108).
    func acquireSweepLease(windowMs: Int64) async throws -> SweepLease
    func devices() async throws -> [DeviceInfo]
    func approve(deviceID: String) async throws
    func revoke(deviceID: String) async throws
}

public extension LibraryTransport {
    // Most transports in tests care about ops or bytes, not device administration.
    func devices() async throws -> [DeviceInfo] { [] }
    func approve(deviceID: String) async throws {}
    func revoke(deviceID: String) async throws {}
}

public struct SweepLease: Codable, Sendable {
    public var granted: Bool
    public var until: Int64
    public var eligible: [String]

    public init(granted: Bool, until: Int64 = 0, eligible: [String] = []) {
        self.granted = granted; self.until = until; self.eligible = eligible
    }
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

    /// `query` goes through `URLComponents`, never into `path`: `appendingPathComponent`
    /// percent-encodes `?`, which would bury the query string inside the path and miss the route.
    private func request(_ path: String, method: String = "GET",
                         query: [String: String] = [:]) -> URLRequest {
        var url = endpoint.appendingPathComponent(path)
        if !query.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "authorization")
        return request
    }

    public func changes(since: Int64, limit: Int = 500) async throws -> ChangesPage {
        let request = self.request("api/library/changes",
                                   query: ["since": String(since), "limit": String(limit)])
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
        if (response as? HTTPURLResponse)?.statusCode != 409 { try Self.check(response, data) }
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
        // 202 means enrolled but awaiting approval (F113), which is a success here.
        if (response as? HTTPURLResponse)?.statusCode != 202 { try Self.check(response, data) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return EnrolmentResult(
            deviceID: json["deviceID"] as? String ?? deviceID,
            token: json["token"] as? String ?? "",
            approved: json["approved"] as? Bool ?? false,
            fingerprint: json["fingerprint"] as? String ?? "")
    }

    // MARK: - Blobs (§8)

    func blobPath(_ locator: BlobLocatorRef) -> String {
        "api/library/blob/\(locator.purpose.rawValue)/\(locator.capture)/\(locator.revision)/\(locator.writer)"
    }

    public func putBlob(_ data: Data, at locator: BlobLocatorRef) async throws {
        if data.count > HTTPTransport.multipartThreshold {
            return try await putMultipart(data, at: locator)
        }
        var request = self.request(blobPath(locator), method: "PUT")
        request.httpBody = data
        let (body, response) = try await session.data(for: request)
        try Self.check(response, body)
    }

    public func getBlob(_ locator: BlobLocatorRef) async throws -> Data {
        let (data, response) = try await session.data(for: request(blobPath(locator)))
        try Self.check(response, data)
        return data
    }

    /// F54, F87: above the threshold the upload is split. Parts are 32 MB because each one
    /// passes through a Worker invocation that must hold it in memory, and a Worker has a 128 MB
    /// ceiling — 64 MB plus request and response overhead leaves too little headroom to rely on.
    public static let multipartThreshold = 90 * 1024 * 1024
    public static let partSize = 32 * 1024 * 1024

    func putMultipart(_ data: Data, at locator: BlobLocatorRef) async throws {
        var offset = 0
        var part = 1
        while offset < data.count {
            let end = min(offset + Self.partSize, data.count)
            var request = self.request(blobPath(locator), method: "PUT",
                                       query: ["part": String(part)])
            request.httpBody = data[offset..<end]
            let (body, response) = try await session.data(for: request)
            try Self.check(response, body)
            offset = end
            part += 1
        }
        var complete = self.request(blobPath(locator), method: "POST",
                                    query: ["complete": String(part - 1)])
        complete.setValue("application/json", forHTTPHeaderField: "content-type")
        let (body, response) = try await session.data(for: complete)
        try Self.check(response, body)
    }

    // MARK: - Snapshots (§6.4)

    public func putSnapshot(_ data: Data, seq: Int64) async throws {
        var request = self.request("api/library/snapshot/\(seq)", method: "PUT")
        request.httpBody = data
        let (body, response) = try await session.data(for: request)
        try Self.check(response, body)
    }

    public func getSnapshot(seq: Int64, writer: String) async throws -> Data {
        let (data, response) = try await session.data(
            for: request("api/library/snapshot/\(seq)/\(writer)"))
        try Self.check(response, data)
        return data
    }

    // MARK: - Devices (§3.1, §3.3)

    public func devices() async throws -> [DeviceInfo] {
        let (data, response) = try await session.data(for: request("api/library/devices"))
        try Self.check(response, data)
        struct Listing: Decodable { var items: [DeviceInfo] }
        return try JSONDecoder().decode(Listing.self, from: data).items
    }

    public func approve(deviceID: String) async throws {
        let (data, response) = try await session.data(
            for: request("api/library/devices/\(deviceID)/approve", method: "POST"))
        try Self.check(response, data)
    }

    public func revoke(deviceID: String) async throws {
        let (data, response) = try await session.data(
            for: request("api/library/devices/\(deviceID)", method: "DELETE"))
        try Self.check(response, data)
    }

    // MARK: - Sweep (§7.4)

    public func acquireSweepLease(windowMs: Int64) async throws -> SweepLease {
        let request = self.request("api/library/lease/sweep", method: "POST",
                                   query: ["windowMs": String(windowMs)])
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 409 {
            return SweepLease(granted: false)
        }
        try Self.check(response, data)
        return try JSONDecoder().decode(SweepLease.self, from: data)
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncFailure("no response") }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = json?["error"] as? String
            // The status alone is not enough: the blob routes answer 403 for a device writing
            // someone else's bytes, and flipping the whole service to "waiting for approval"
            // over that would tell the user to approve a Mac that is already approved.
            throw SyncFailure(message ?? "http \(http.statusCode)",
                              isAuthFailure: http.statusCode == 401,
                              awaitingApproval: http.statusCode == 403
                                  && message == "awaiting approval")
        }
    }
}
