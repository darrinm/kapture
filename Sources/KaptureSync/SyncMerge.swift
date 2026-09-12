// Applying what the log says to what this Mac holds (docs/SHARED-LIBRARY.md §7).
//
// F90: this is a pure function from (local rows, incoming ops) to (new rows, outbox ops). It
// touches no URLSession, no GRDB and no filesystem — transport and persistence call it, and are
// not inside it. That is what lets F91 drive two simulated devices through interleaved streams
// and assert on the conflict rules, which is the part of this design most likely to be wrong
// and the part hardest to exercise on two real Macs.

import Foundation
import KaptureCore

/// A capture as the log carries it: `CaptureRecord` less the device-local fields (F83, F84).
public struct SyncedRow: Codable, Sendable, Equatable {
    public var captureID: String
    public var lamport: Int64
    public var deviceID: String
    public var kind: CaptureKind
    public var status: CaptureStatus
    public var createdAt: Date
    public var trashedAt: Date?
    public var width: Int
    public var height: Int
    public var bytes: Int
    /// The file's name, without a path. F83 keeps `relPath` device-local: each Mac has its own
    /// root and its own collision history, so one capture legitimately sits at different paths.
    public var name: String
    public var sourceApp: String?
    public var windowTitle: String?
    public var contentRevision: Int64
    public var contentHash: String?
    /// The `contentHash` this revision was derived from, or nil for an original capture.
    ///
    /// Without it, a divergent lineage (F112) and an ordinary sequential edit are indis-
    /// tinguishable: both present a higher revision with a different hash. Forking on that
    /// signature alone would fork every normal edit in the library.
    public var parentHash: String?
    public var aiState: CaptureRecord.AIState
    public var summary: String?
    public var ocr: String?
    public var shareURL: String?
    public var durationS: Double?
    /// Where each purpose's bytes live (F23, F129): the row alone must be enough to reach them.
    public var blobs: [BlobPurpose: BlobLocator]
    /// Set when this row is a fork of another capture (F35).
    public var forkedFrom: String?

    public init(captureID: String, lamport: Int64, deviceID: String, kind: CaptureKind,
                status: CaptureStatus, createdAt: Date, trashedAt: Date? = nil,
                width: Int, height: Int, bytes: Int, name: String, sourceApp: String? = nil,
                windowTitle: String? = nil, contentRevision: Int64 = 0, contentHash: String? = nil,
                parentHash: String? = nil,
                aiState: CaptureRecord.AIState = .none, summary: String? = nil, ocr: String? = nil,
                shareURL: String? = nil, durationS: Double? = nil,
                blobs: [BlobPurpose: BlobLocator] = [:], forkedFrom: String? = nil) {
        self.captureID = captureID; self.lamport = lamport; self.deviceID = deviceID
        self.kind = kind; self.status = status; self.createdAt = createdAt
        self.trashedAt = trashedAt; self.width = width; self.height = height; self.bytes = bytes
        self.name = name; self.sourceApp = sourceApp; self.windowTitle = windowTitle
        self.contentRevision = contentRevision; self.contentHash = contentHash
        self.parentHash = parentHash
        self.aiState = aiState; self.summary = summary; self.ocr = ocr
        self.shareURL = shareURL; self.durationS = durationS; self.blobs = blobs
        self.forkedFrom = forkedFrom
    }
}

/// Everything needed to fetch and decrypt one blob, carried in the row so a snapshot preserves
/// it (F129). `capture` is the blindedID the bytes are filed under, which is not the naming
/// row's own for a fork (F128).
public struct BlobLocator: Codable, Sendable, Equatable {
    public var revision: Int64
    public var writer: String
    public var capture: String

    public init(revision: Int64, writer: String, capture: String) {
        self.revision = revision; self.writer = writer; self.capture = capture
    }
}

public enum OpKind: String, Codable, Sendable {
    case upsert, trash, restore, delete
}

/// One decrypted operation, paired with the envelope facts the merge needs.
public struct SyncOp: Sendable, Equatable {
    public var seq: Int64
    public var kind: OpKind
    public var row: SyncedRow
    /// The seq this device had applied when it wrote the op (F106, F109).
    public var observed: Int64

    public init(seq: Int64, kind: OpKind, row: SyncedRow, observed: Int64 = 0) {
        self.seq = seq; self.kind = kind; self.row = row; self.observed = observed
    }
}

/// A local row plus the one fact the merge cannot infer: whether the log has ever seen it.
public struct LocalRow: Sendable, Equatable {
    public var row: SyncedRow
    /// F130. A row the log once acknowledged, absent from a later snapshot, was deleted while
    /// this Mac was away. A row the log has never seen is genuinely local.
    public var acknowledged: Bool

    public init(row: SyncedRow, acknowledged: Bool) {
        self.row = row; self.acknowledged = acknowledged
    }
}

public struct MergeResult: Sendable, Equatable {
    /// Rows to write locally, replacing any row with the same `captureID`.
    public var upserts: [SyncedRow] = []
    /// Captures to remove locally. Their bytes go too.
    public var deletions: [String] = []
    /// Rows this device must push, because a conflict made it the loser (F35) or because a
    /// snapshot revealed local-only work.
    public var outbox: [SyncedRow] = []
    /// Captures that now exist twice, for the badge F36 requires.
    public var forks: [String] = []
}

public enum SyncMerge {
    // MARK: - Ordering (§7)

    /// `(lamport, deviceID)`, a total order without clock sync. It decides *which* row wins; it
    /// cannot decide *whether* there was a conflict, which is what F81 exists for.
    static func wins(_ a: SyncedRow, over b: SyncedRow) -> Bool {
        if a.lamport != b.lamport { return a.lamport > b.lamport }
        return a.deviceID > b.deviceID
    }

    /// F81: two writes of the same `(captureID, contentRevision)` with different content are
    /// concurrent by construction, because revision N+1 always descends from N. Ordering alone
    /// would linearize them and silently discard one side's annotation.
    static func isFork(_ a: SyncedRow, _ b: SyncedRow) -> Bool {
        a.contentRevision == b.contentRevision
            && a.contentHash != nil && b.contentHash != nil
            && a.contentHash != b.contentHash
    }

    /// F112: the same id on two Macs from a copied library rather than a ULID collision, edited
    /// independently to different revisions.
    ///
    /// Divergence needs positive evidence, never the mere fact that revisions differ — that is
    /// what an ordinary sequential edit looks like, and forking on it would fork the whole
    /// library. The evidence is `parentHash`: a descendant names the hash it came from, so a row
    /// whose parent is not the other side's content is not descended from it. Absent a
    /// `parentHash` on either side the answer is "not divergent", because a false fork is worse
    /// than a missed one and the missed one still converges on the higher revision.
    static func lineagesDiverge(_ a: SyncedRow, _ b: SyncedRow) -> Bool {
        guard a.contentRevision != b.contentRevision else { return false }
        guard a.contentHash != nil, b.contentHash != nil else { return false }
        let (older, newer) = a.contentRevision < b.contentRevision ? (a, b) : (b, a)
        guard let parent = newer.parentHash else { return false }
        return parent != older.contentHash
    }

    // MARK: - Field-level rules

    /// F41, F42: the name and `aiState` resolve as one unit, and a manual rename pins the name
    /// against every device's namer rather than only its own.
    static func resolveNaming(winner: SyncedRow, loser: SyncedRow) -> SyncedRow {
        var resolved = winner
        if !loser.aiState.acceptsName && winner.aiState.acceptsName {
            resolved.name = loser.name
            resolved.aiState = loser.aiState
            resolved.summary = loser.summary
        }
        return resolved
    }

    /// F38 and F39 together, and the order matters.
    ///
    /// F38's "trash beats keep" governs *concurrent* writes only — equal lamports, neither
    /// having seen the other. Applied unconditionally it makes trash absorbing and F39's restore
    /// can never win, so a capture restored on one Mac would be re-trashed by every later sync.
    /// A causally later write (strictly greater lamport) therefore decides on its own; only a
    /// genuine tie breaks toward the recoverable outcome, because an accidental keep is a
    /// nuisance and an unintended delete is data loss.
    static func resolveStatus(_ a: SyncedRow, _ b: SyncedRow) -> CaptureStatus {
        if a.lamport != b.lamport { return a.lamport > b.lamport ? a.status : b.status }
        if a.status == .trashed || b.status == .trashed { return .trashed }
        return wins(a, over: b) ? a.status : b.status
    }

    // MARK: - The merge

    /// Apply a page of ops to the local row set.
    public static func apply(ops: [SyncOp], to local: [String: LocalRow],
                             deviceID: String) -> MergeResult {
        var rows = local
        var result = MergeResult()

        for op in ops.sorted(by: { $0.seq < $1.seq }) {
            let incoming = op.row
            guard let existing = rows[incoming.captureID]?.row else {
                // Unknown capture. A delete for one we never had is already satisfied.
                if op.kind == .delete { continue }
                rows[incoming.captureID] = LocalRow(row: incoming, acknowledged: true)
                result.upserts.append(incoming)
                continue
            }

            switch op.kind {
            case .delete:
                rows.removeValue(forKey: incoming.captureID)
                result.deletions.append(incoming.captureID)

            case .trash, .restore, .upsert:
                if isFork(existing, incoming) || lineagesDiverge(existing, incoming) {
                    let localLoses = wins(incoming, over: existing)
                    let winner = localLoses ? incoming : existing
                    let loser = localLoses ? existing : incoming

                    var kept = resolveNaming(winner: winner, loser: loser)
                    kept.status = resolveStatus(existing, incoming)
                    rows[kept.captureID] = LocalRow(row: kept, acknowledged: true)
                    result.upserts.append(kept)

                    // F35, F37: the loser becomes its own capture rather than being discarded.
                    // F128 keeps its blob locators pointing at the bytes already uploaded under
                    // the original capture, so F82's "no re-upload" holds.
                    var fork = loser
                    fork.captureID = ULID.generate()
                    fork.forkedFrom = winner.captureID
                    fork.lamport = max(existing.lamport, incoming.lamport) + 1
                    fork.deviceID = deviceID
                    rows[fork.captureID] = LocalRow(row: fork, acknowledged: false)
                    result.upserts.append(fork)
                    result.forks.append(fork.captureID)
                    // Only this device knows about the fork until it pushes it.
                    if !localLoses { result.outbox.append(fork) }
                    continue
                }

                // No conflict: order decides, with the field rules layered on top.
                let winner = wins(incoming, over: existing) ? incoming : existing
                let loser = wins(incoming, over: existing) ? existing : incoming
                var resolved = resolveNaming(winner: winner, loser: loser)
                resolved.status = resolveStatus(existing, incoming)
                rows[resolved.captureID] = LocalRow(row: resolved, acknowledged: true)
                result.upserts.append(resolved)
            }
        }

        return result
    }

    /// Apply a snapshot (F27, F110, F130, F131).
    ///
    /// A snapshot is merged, never substituted: replacing the row set would destroy the
    /// local-only rows F70's merge exists to preserve. But seeding *everything* the snapshot
    /// omits resurrects captures deleted while this Mac was offline, because a deletion whose op
    /// has been compacted away looks exactly like a capture the snapshot never knew. The
    /// acknowledged flag is what separates the two.
    public static func applySnapshot(_ snapshot: [SyncedRow], to local: [String: LocalRow],
                                     deviceID: String) -> MergeResult {
        var result = MergeResult()
        let inSnapshot = Set(snapshot.map(\.captureID))

        for row in snapshot {
            guard let existing = local[row.captureID]?.row else {
                result.upserts.append(row)
                continue
            }
            if isFork(existing, row) || lineagesDiverge(existing, row) {
                let ops = [SyncOp(seq: 0, kind: .upsert, row: row)]
                let nested = apply(ops: ops, to: [row.captureID: LocalRow(row: existing,
                                                                         acknowledged: true)],
                                   deviceID: deviceID)
                result.upserts.append(contentsOf: nested.upserts)
                result.outbox.append(contentsOf: nested.outbox)
                result.forks.append(contentsOf: nested.forks)
                continue
            }
            result.upserts.append(wins(row, over: existing) ? row : existing)
        }

        for (captureID, localRow) in local where !inSnapshot.contains(captureID) {
            if localRow.acknowledged {
                // The log knew this capture and the snapshot does not: it was deleted while this
                // Mac was away, and its delete op has been compacted (F131).
                result.deletions.append(captureID)
            } else {
                // Never pushed, so the snapshot's silence says nothing about it (F62, F70).
                result.outbox.append(localRow.row)
            }
        }

        return result
    }
}
