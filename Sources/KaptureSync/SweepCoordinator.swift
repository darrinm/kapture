// The trash sweep under sync (§7.4), and snapshots (§6.4).
//
// The local sweep runs every six hours in each process. Two Macs doing that against one logical
// library will delete bytes the other just restored, so under sync the deletion half of it moves
// behind a lease and a compare-and-swap, and what stays local is eviction — bytes that can be
// fetched again.

import Foundation
import GRDB
import KaptureCore

public struct SweepCoordinator: Sendable {
    public let store: SyncStore
    public let blobs: BlobStore
    public let deviceID: String

    public init(store: SyncStore, blobs: BlobStore, deviceID: String) {
        self.store = store
        self.blobs = blobs
        self.deviceID = deviceID
    }

    public static let trashWindow: TimeInterval = 7 * 24 * 60 * 60

    public struct SweepOutcome: Sendable, Equatable {
        public var heldLease = false
        public var deleted: [String] = []
        public var evicted = 0
    }

    /// One pass.
    ///
    /// F44: a device without the lease sweeps its own cache only. It never deletes a row, a
    /// remote blob, or an `.originals/` file — those are the log's to decide, and a second
    /// opinion about them is how a restore gets undone.
    public func sweep(using transport: any LibraryTransport, cacheCeiling: Int) async throws
        -> SweepOutcome {
        var outcome = SweepOutcome()

        let plan = try blobs.planEviction(ceilingBytes: cacheCeiling)
        try blobs.evict(plan)
        outcome.evicted = plan.evicted.count

        let lease = try await transport.acquireSweepLease(
            windowMs: Int64(Self.trashWindow * 1000))
        guard lease.granted else { return outcome }
        outcome.heldLease = true

        // F45: eligibility is the server's answer, from the trash marks it retains (F134).
        // A local `trashedAt` is not authoritative and a Mac with a skewed clock would sweep
        // early if it were.
        guard let identity = try store.identity() else { return outcome }
        let eligible = Set(lease.eligible)
        guard !eligible.isEmpty else { return outcome }

        let rows = try store.localRows()
        for (captureID, local) in rows {
            guard eligible.contains(store.crypto.blind(captureID)) else { continue }
            guard local.row.status == .trashed else { continue }
            // F106: the delete names the seq at which this device last saw the capture as
            // trash, and the log refuses it if anything has happened since.
            try enqueueDelete(local.row, observed: identity.cursor)
            outcome.deleted.append(captureID)
        }
        return outcome
    }

    /// Separate and non-async so the write transaction is not opened from an async context,
    /// where GRDB's async overloads would be selected instead.
    func enqueueDelete(_ row: SyncedRow, observed: Int64) throws {
        try store.db.queue.write { d in
            try store.enqueue(row, kind: .delete, observed: observed,
                              deviceID: deviceID, in: d)
        }
    }

    // MARK: - Snapshots (§6.4)

    /// F33, F102, F111: only a complete client may snapshot, so this refuses when anything is
    /// skipped or queued. An incomplete snapshot followed by compaction is silent, permanent
    /// data loss — the one failure mode in this design with no recovery at all.
    public func snapshotIfNeeded(using transport: any LibraryTransport,
                                 opsSinceSnapshot: Int) async throws -> Bool {
        guard opsSinceSnapshot > 10_000 else { return false }
        guard try store.skippedSeqs().isEmpty else { return false }
        guard try store.pending().isEmpty else { return false }
        guard let identity = try store.identity() else { return false }

        guard try await transport.snapshotClaim(supportsV: SyncStore.payloadVersion,
                                                seq: identity.cursor) else { return false }

        let rows = try store.localRows().values.map(\.row)
        let sealed = try store.crypto.seal(rows, scope: .snapshot(seq: identity.cursor),
                                           writer: deviceID)
        try await transport.putSnapshot(sealed, seq: identity.cursor)
        return true
    }

    /// Bootstrap or re-bootstrap from a snapshot (F27, F110, F122).
    public func applySnapshot(_ data: Data, seq: Int64, writer: String) throws -> MergeResult {
        let rows = try store.crypto.open([SyncedRow].self, from: data,
                                         scope: .snapshot(seq: seq), writer: writer)
        let local = try store.localRows()
        let result = SyncMerge.applySnapshot(rows, to: local, deviceID: deviceID)
        try store.apply(result, cursor: seq, deviceID: deviceID)
        try store.clearSkipped()
        return result
    }
}
