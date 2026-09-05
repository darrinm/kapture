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
    public struct Annotations: Codable {
        /// original (pre-flatten) pixels, relative to library root, under .originals/
        public var original: String
        /// editor layer stack, JSON-encoded by KaptureEditor (opaque to Core)
        public var layersJSON: String
    }
    public var annotations: Annotations?
    // ai / share sections extend this in later milestones

    public init(id: String, created: Date, app: String?, window: String?) {
        self.v = 1; self.id = id; self.created = created
        self.source = Source(app: app, window: window)
    }

    public static func read(for fileURL: URL) -> Sidecar? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(for: fileURL)) else { return nil }
        return try? dec.decode(Sidecar.self, from: data)
    }

    /// Mutation paths must distinguish a missing sidecar from one we cannot safely interpret.
    public static func readIfPresent(for fileURL: URL) throws -> Sidecar? {
        let data: Data
        do { data = try Data(contentsOf: url(for: fileURL)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Sidecar.self, from: data)
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
