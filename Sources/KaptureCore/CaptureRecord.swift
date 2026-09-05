import Foundation
import GRDB

public enum CaptureKind: String, Codable, Sendable {
    case screenshot, recording, gif, text
}

public enum CaptureStatus: String, Codable, Sendable {
    case staged, kept, trashed, sweeping
}

public struct CaptureRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "captures"

    /// How far the intelligence pipeline has taken this capture. Stored as the same text the
    /// column has always held, so no migration: "none", "ocr", "named:local", "named:api".
    public enum AIState: String, Codable, Sendable {
        case none, ocr
        case namedLocal = "named:local"
        case namedAPI = "named:api"

        /// Lenient: a value written by a newer build (or a hand-edited row) degrades to `.none`
        /// rather than failing the whole row fetch and making the capture vanish from the grid.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = AIState(rawValue: raw) ?? .none
        }

        /// True while naming may still overwrite the file name — a manual rename pins the row.
        public var acceptsName: Bool { self == .none || self == .ocr }
    }

    public var id: String            // ULID
    public var kind: CaptureKind
    public var status: CaptureStatus
    public var createdAt: Date
    public var trashedAt: Date?
    public var width: Int
    public var height: Int
    public var bytes: Int
    public var relPath: String       // relative to library root (incl. .trash/ paths)
    public var sourceApp: String?
    public var windowTitle: String?
    public var screenID: Int?
    public var fastID: String        // "size:mtimeNs:inode" — primary identity (spec §2.2 F11)
    public var contentRevision: Int64 = 0
    public var contentHash: String?  // lazy SHA-256
    public var aiState: AIState
    public var summary: String?
    public var shareURL: String?
    public var shareStale: Bool
    public var durationS: Double?   // recordings

    public init(id: String = ULID.generate(), kind: CaptureKind, status: CaptureStatus = .staged,
                createdAt: Date = Date(), width: Int, height: Int, bytes: Int, relPath: String,
                sourceApp: String? = nil, windowTitle: String? = nil, screenID: Int? = nil,
                fastID: String) {
        self.id = id; self.kind = kind; self.status = status; self.createdAt = createdAt
        self.trashedAt = nil; self.width = width; self.height = height; self.bytes = bytes
        self.relPath = relPath; self.sourceApp = sourceApp; self.windowTitle = windowTitle
        self.screenID = screenID; self.fastID = fastID; self.contentHash = nil
        self.aiState = .none; self.summary = nil; self.shareURL = nil; self.shareStale = false
        self.durationS = nil
    }

    // MARK: What this capture can do
    // One place answers "does this editor/action apply?", so a kind that is neither a still nor
    // a movie (a .gif — playable, but not PNG-editable and not trimmable) can't fall into the
    // wrong tool: the still editor's save writes PNG bytes over whatever file it opened.

    /// Recordings open the native trim UI.
    public var canTrim: Bool { kind == .recording }
    /// Only stills go to the annotation editor (it flattens to PNG on save).
    public var canAnnotate: Bool { kind == .screenshot }
    /// GIF export reads a movie; a GIF is already one.
    public var canExportGIF: Bool { kind == .recording }
    /// Neither in the trash nor being swept: the states an operation may act on.
    public var isLive: Bool { status != .trashed && status != .sweeping }

    /// What replacing the pixels invalidates: their identity, any share of them, and everything
    /// the AI concluded from the old ones. The search index is cleared alongside, by the
    /// operation that commits this.
    public mutating func markContentReplaced() {
        contentRevision += 1
        contentHash = nil
        shareStale = shareURL != nil
        summary = nil
        aiState = .none
    }
}

/// Crockford-base32 ULID: sortable, unique, no deps.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static func generate(now: Date = Date()) -> String {
        var chars = [Character](repeating: "0", count: 26)
        var ms = UInt64(now.timeIntervalSince1970 * 1000)
        for i in (0..<10).reversed() { chars[i] = alphabet[Int(ms & 0x1F)]; ms >>= 5 }
        for i in 10..<26 { chars[i] = alphabet[Int.random(in: 0..<32)] }
        return String(chars)
    }
}
