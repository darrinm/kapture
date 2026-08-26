import Foundation

/// Every capture gets a sidecar at insert (spec §2.3 F5) — files + sidecars are the durable truth.
public struct Sidecar: Codable {
    public var v: Int
    public var id: String
    public var created: Date
    public var source: Source?
    public struct Source: Codable {
        public var app: String?
        public var window: String?
    }
    // annotations / ai / share sections extend this in later milestones

    public init(id: String, created: Date, app: String?, window: String?) {
        self.v = 1; self.id = id; self.created = created
        self.source = Source(app: app, window: window)
    }

    public static func url(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("kapture")
    }

    public func write(next fileURL: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Sidecar.url(for: fileURL), options: .atomic)
    }
}
