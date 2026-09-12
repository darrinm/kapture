// The pull/push loop (docs/SHARED-LIBRARY.md §6.2, §6.3).
//
// Thin by design: decrypt, hand to `SyncMerge`, write what comes back, advance the cursor. The
// decisions live in the merge, which is pure and tested without any of this.

import Foundation
import KaptureCore

public actor SyncEngine {
    private let store: SyncStore
    private let transport: any LibraryTransport
    private let crypto: LibraryCrypto
    private let deviceID: String

    public init(store: SyncStore, transport: any LibraryTransport, deviceID: String) {
        self.store = store
        self.transport = transport
        self.crypto = store.crypto
        self.deviceID = deviceID
    }

    @discardableResult
    public func syncOnce() async throws -> SyncSummary {
        var summary = SyncSummary()
        summary.pushed = try await push()
        let pulled = try await pull()
        summary.applied = pulled.applied
        summary.skipped = pulled.skipped
        summary.forks = pulled.forks
        return summary
    }

    // MARK: - Pull (F26, F27)

    struct PullSummary { var applied = 0; var skipped = 0; var forks = 0 }

    func pull() async throws -> PullSummary {
        guard let identity = try store.identity() else { throw SyncFailure("sync is not enabled") }
        var cursor = identity.cursor
        var summary = PullSummary()

        while true {
            let page = try await transport.changes(since: cursor, limit: 500)
            if page.ops.isEmpty { break }

            var ops: [SyncOp] = []
            for wire in page.ops {
                // F78, F104: an op this build cannot apply advances the cursor anyway — holding
                // it back would stall this Mac behind a newer one indefinitely — but it is
                // recorded so F135 can replay it once the build's capabilities widen.
                guard wire.v <= SyncStore.payloadVersion,
                      let kind = OpKind(rawValue: wire.kind) else {
                    try store.noteSkipped(seq: wire.seq, v: wire.v, kind: wire.kind)
                    summary.skipped += 1
                    continue
                }
                guard let ciphertext = Data(base64Encoded: wire.ciphertext) else {
                    try store.noteSkipped(seq: wire.seq, v: wire.v, kind: wire.kind)
                    summary.skipped += 1
                    continue
                }
                // The key derives from the envelope alone (F12, F95): opID and the writing
                // device, both in front of us before anything is decrypted. An op that will not
                // open — a corrupt payload, or one written under a key this Mac does not hold —
                // is skipped like any other unreadable op. Throwing here would leave the cursor
                // where it is and every later sync would stop at the same op, forever.
                guard let row = try? crypto.open(SyncedRow.self, from: ciphertext,
                                                 scope: .row(opID: wire.opID),
                                                 writer: wire.deviceID) else {
                    try store.noteSkipped(seq: wire.seq, v: wire.v, kind: wire.kind)
                    summary.skipped += 1
                    continue
                }
                ops.append(SyncOp(seq: wire.seq, kind: kind, row: row, observed: wire.observed))
            }

            let local = try store.localRows()
            let result = SyncMerge.apply(ops: ops, to: local, deviceID: deviceID)
            cursor = page.ops.map(\.seq).max() ?? cursor
            try store.apply(result, cursor: cursor, deviceID: deviceID)

            summary.applied += result.upserts.count + result.deletions.count
            summary.forks += result.forks.count
            if page.ops.count < 500 || cursor >= page.head { break }
        }

        return summary
    }

    // MARK: - Push (F30, F31, F32)

    func push() async throws -> Int {
        guard try store.identity() != nil else { throw SyncFailure("sync is not enabled") }
        let pending = try store.pending(limit: 100)
        guard !pending.isEmpty else { return 0 }

        let outgoing = pending.map { entry in
            // `observed` is the seq the op was decided against and nothing else (F106). Raising
            // it to the current cursor would tell the log this device had seen work it decided
            // before — a delete queued at seq N would then be admitted over a restore at N+5.
            OutgoingOp(opID: entry.opID, blindedID: crypto.blind(entry.captureID),
                       v: entry.v, kind: entry.kind.rawValue, requires: entry.requires,
                       observed: entry.observed,
                       ciphertext: entry.payload.base64EncodedString())
        }

        let outcome = try await transport.push(outgoing)
        try store.acknowledge(outcome.assigned.map(\.opID))

        for rejection in outcome.rejected {
            // A stale delete (F106) or a tombstoned capture (F132) will never succeed on retry,
            // so it is dropped rather than left to spin. Anything else backs off.
            if rejection.reason.contains("stale delete") || rejection.reason.contains("deleted at") {
                try store.drop(rejection.opID)
            } else {
                try store.deferEntry(rejection.opID, error: rejection.reason, after: 60)
            }
        }
        return outcome.assigned.count
    }
}

public struct SyncSummary: Sendable, Equatable {
    public var pushed = 0
    public var applied = 0
    public var skipped = 0
    public var forks = 0
}
