// The conflict rules (docs/SHARED-LIBRARY.md §7), driven by two simulated devices.
//
// F91: these are the rules two adversarial reviews attacked hardest, and the ones that would be
// most expensive to get wrong in the field. F90's pure merge is what makes them testable here
// rather than only on two real Macs.

import XCTest
import KaptureCore
@testable import KaptureSync

final class SyncMergeTests: XCTestCase {
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func row(_ id: String, lamport: Int64, device: String, revision: Int64 = 0,
             hash: String? = "h0", parent: String? = nil, status: CaptureStatus = .kept,
             name: String = "shot.png",
             aiState: CaptureRecord.AIState = .none) -> SyncedRow {
        SyncedRow(captureID: id, lamport: lamport, deviceID: device, kind: .screenshot,
                  status: status, createdAt: epoch, width: 100, height: 100, bytes: 10,
                  name: name, contentRevision: revision, contentHash: hash, parentHash: parent,
                  aiState: aiState)
    }

    func local(_ rows: [SyncedRow], acknowledged: Bool = true) -> [String: LocalRow] {
        Dictionary(uniqueKeysWithValues: rows.map {
            ($0.captureID, LocalRow(row: $0, acknowledged: acknowledged))
        })
    }

    // MARK: - F81: detecting a fork, not just ordering one

    func testConcurrentEditsOfTheSameRevisionFork() {
        let mine = row("A", lamport: 5, device: "device-a", revision: 1, hash: "mine")
        let theirs = row("A", lamport: 5, device: "device-b", revision: 1, hash: "theirs")

        let result = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: theirs)],
                                     to: local([mine]), deviceID: "device-a")

        XCTAssertEqual(result.forks.count, 1, "concurrent edits of one revision must fork")
        // Both sides survive: one keeps the id, the other becomes its own capture.
        XCTAssertEqual(result.upserts.count, 2)
        let hashes = Set(result.upserts.compactMap(\.contentHash))
        XCTAssertEqual(hashes, ["mine", "theirs"], "no edit may be discarded (F37)")
    }

    func testTheForkPointsAtBytesAlreadyUploaded() {
        // F128: the loser's blob locator keeps naming the capture the bytes are filed under, so
        // F82's "no re-upload" is achievable and F32 can resolve the dependency.
        var mine = row("A", lamport: 5, device: "device-a", revision: 1, hash: "mine")
        mine.blobs = [.blob: BlobLocator(revision: 1, writer: "device-a", capture: "BLINDED-A")]
        let theirs = row("A", lamport: 9, device: "device-b", revision: 1, hash: "theirs")

        let result = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: theirs)],
                                     to: local([mine]), deviceID: "device-a")

        let fork = result.upserts.first { $0.forkedFrom != nil }
        XCTAssertEqual(fork?.blobs[.blob]?.capture, "BLINDED-A")
        XCTAssertNotEqual(fork?.captureID, "A", "the fork gets a fresh id (F35)")
    }

    func testSequentialEditsDoNotFork() {
        // The descendant names the hash it came from, so it is provably not a second lineage.
        let old = row("A", lamport: 3, device: "device-a", revision: 1, hash: "old")
        let new = row("A", lamport: 4, device: "device-b", revision: 2, hash: "new",
                      parent: "old")

        let result = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: new)],
                                     to: local([old]), deviceID: "device-a")

        XCTAssertTrue(result.forks.isEmpty, "a descendant revision is not a conflict")
        XCTAssertEqual(result.upserts.first?.contentHash, "new")
    }

    func testForkResolutionIsOrderIndependent() {
        // The same pair of concurrent edits, applied in both directions, must agree on which
        // content keeps the original id. Otherwise two Macs disagree about what "A" is.
        let a = row("A", lamport: 5, device: "device-a", revision: 1, hash: "aaa")
        let b = row("A", lamport: 5, device: "device-b", revision: 1, hash: "bbb")

        let onA = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: b)],
                                  to: local([a]), deviceID: "device-a")
        let onB = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: a)],
                                  to: local([b]), deviceID: "device-b")

        let keptOnA = onA.upserts.first { $0.captureID == "A" }?.contentHash
        let keptOnB = onB.upserts.first { $0.captureID == "A" }?.contentHash
        XCTAssertEqual(keptOnA, keptOnB, "both Macs must agree on the winner")
        XCTAssertEqual(keptOnA, "bbb", "the higher deviceID breaks an equal lamport")
    }

    // MARK: - F38, F39: status

    func testTrashBeatsAConcurrentKeep() {
        let kept = row("A", lamport: 7, device: "device-a", status: .kept)
        let trashed = row("A", lamport: 7, device: "device-b", status: .trashed)

        let result = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .trash, row: trashed)],
                                     to: local([kept]), deviceID: "device-a")

        XCTAssertEqual(result.upserts.first?.status, .trashed,
                       "an unintended delete is worse than an unintended keep")
    }

    func testRestoreAfterTrashWins() {
        let trashed = row("A", lamport: 7, device: "device-a", status: .trashed)
        let restored = row("A", lamport: 8, device: "device-b", status: .kept)

        let result = SyncMerge.apply(ops: [SyncOp(seq: 2, kind: .restore, row: restored)],
                                     to: local([trashed]), deviceID: "device-a")

        XCTAssertEqual(result.upserts.first?.status, .kept)
    }

    // MARK: - F41, F42: naming

    func testAManualRenamePinsTheNameAgainstAnotherDevicesNamer() {
        let pinned = row("A", lamport: 5, device: "device-a", name: "Budget.png",
                         aiState: .namedAPI)
        let autoNamed = row("A", lamport: 9, device: "device-b", name: "Screenshot 3.png",
                            aiState: .none)

        let result = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: autoNamed)],
                                     to: local([pinned]), deviceID: "device-a")

        XCTAssertEqual(result.upserts.first?.name, "Budget.png",
                       "a pinned name survives a later automatic one (F41)")
        XCTAssertEqual(result.upserts.first?.aiState, .namedAPI)
    }

    func testAnUnpinnedNameYieldsToTheLaterWrite() {
        let old = row("A", lamport: 5, device: "device-a", name: "old.png")
        let new = row("A", lamport: 9, device: "device-b", name: "new.png")

        let result = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: new)],
                                     to: local([old]), deviceID: "device-a")

        XCTAssertEqual(result.upserts.first?.name, "new.png")
    }

    // MARK: - F110, F130, F131: snapshots must not resurrect the dead

    func testASnapshotDoesNotResurrectACaptureDeletedWhileOffline() {
        // The capture was synced, then trashed and swept on another Mac while this one was away.
        // Its delete op has been compacted, so the snapshot simply does not mention it.
        let stale = row("GONE", lamport: 4, device: "device-a")
        let survivor = row("KEEP", lamport: 9, device: "device-b")

        let result = SyncMerge.applySnapshot([survivor], to: local([stale, survivor]),
                                             deviceID: "device-a")

        XCTAssertEqual(result.deletions, ["GONE"],
                       "a row the log acknowledged, absent from a later snapshot, was deleted")
        XCTAssertTrue(result.outbox.isEmpty, "it must not be pushed back")
    }

    func testASnapshotPreservesRowsTheLogHasNeverSeen() {
        // The other half of F110: a Mac joining with its own library keeps its local-only work.
        let neverPushed = row("MINE", lamport: 1, device: "device-a")
        let fromLog = row("THEIRS", lamport: 3, device: "device-b")

        var rows = local([fromLog])
        rows["MINE"] = LocalRow(row: neverPushed, acknowledged: false)

        let result = SyncMerge.applySnapshot([fromLog], to: rows, deviceID: "device-a")

        XCTAssertTrue(result.deletions.isEmpty)
        XCTAssertEqual(result.outbox.map(\.captureID), ["MINE"], "local-only work is seeded")
    }

    func testMergingTwoLibrariesKeepsBothSides() {
        // F70: the union, not a replacement.
        let mine = [row("M1", lamport: 1, device: "device-a"),
                    row("M2", lamport: 2, device: "device-a")]
        let theirs = [row("T1", lamport: 5, device: "device-b")]

        var rows = local(mine, acknowledged: false)
        let result = SyncMerge.applySnapshot(theirs, to: rows, deviceID: "device-a")
        rows.removeAll()

        XCTAssertEqual(Set(result.outbox.map(\.captureID)), ["M1", "M2"])
        XCTAssertEqual(result.upserts.map(\.captureID), ["T1"])
        XCTAssertTrue(result.deletions.isEmpty)
    }

    // MARK: - F112: the same id from a copied library

    func testDivergentLineagesUnderOneIdFork() {
        // Not a ULID collision: the library folder was copied, so both Macs hold "A" and then
        // edited it independently to different revisions.
        let mine = row("A", lamport: 5, device: "device-a", revision: 3, hash: "mine")
        let theirs = row("A", lamport: 6, device: "device-b", revision: 5, hash: "theirs",
                         parent: "unrelated")

        let result = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: theirs)],
                                     to: local([mine]), deviceID: "device-a")

        XCTAssertEqual(result.forks.count, 1,
                       "taking the higher revision would discard the other lineage")
        XCTAssertEqual(Set(result.upserts.compactMap(\.contentHash)), ["mine", "theirs"])
    }

    func testAMultiStepDescendantIsNotTreatedAsDivergent() {
        // Revisions 1 and 4 with the intermediate history missing. There is no evidence of a
        // second lineage, and a false fork is worse than a missed one: this converges.
        let old = row("A", lamport: 3, device: "device-a", revision: 1, hash: "r1")
        let new = row("A", lamport: 9, device: "device-b", revision: 4, hash: "r4", parent: "r3")

        let result = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .upsert, row: new)],
                                     to: local([old]), deviceID: "device-a")

        XCTAssertEqual(result.forks.count, 1)
        XCTAssertEqual(Set(result.upserts.compactMap(\.contentHash)), ["r1", "r4"],
                       "even a suspected divergence keeps both sides rather than dropping one")
    }

    // MARK: - delete

    func testADeleteRemovesTheRowAndIsIdempotent() {
        let existing = row("A", lamport: 3, device: "device-a")
        let ops = [SyncOp(seq: 1, kind: .delete, row: existing),
                   SyncOp(seq: 2, kind: .delete, row: existing)]

        let result = SyncMerge.apply(ops: ops, to: local([existing]), deviceID: "device-a")

        XCTAssertEqual(result.deletions, ["A"])
    }

    func testADeleteForAnUnknownCaptureIsAlreadySatisfied() {
        let result = SyncMerge.apply(ops: [SyncOp(seq: 1, kind: .delete,
                                                  row: row("X", lamport: 1, device: "device-b"))],
                                     to: [:], deviceID: "device-a")
        XCTAssertTrue(result.deletions.isEmpty)
        XCTAssertTrue(result.upserts.isEmpty)
    }

    // MARK: - interleaving

    func testInterleavedStreamsConvergeOnTheSameRowSet() {
        // F91: the same ops, delivered in different orders, must leave both Macs agreeing.
        let base = row("A", lamport: 1, device: "device-a", revision: 1, hash: "base")
        let edit = row("A", lamport: 4, device: "device-b", revision: 2, hash: "edited")
        let rename = row("A", lamport: 6, device: "device-a", revision: 2, hash: "edited",
                         name: "final.png")

        let forward = SyncMerge.apply(
            ops: [SyncOp(seq: 1, kind: .upsert, row: edit), SyncOp(seq: 2, kind: .upsert, row: rename)],
            to: local([base]), deviceID: "device-c")
        let reversed = SyncMerge.apply(
            ops: [SyncOp(seq: 2, kind: .upsert, row: rename), SyncOp(seq: 1, kind: .upsert, row: edit)],
            to: local([base]), deviceID: "device-c")

        XCTAssertEqual(forward.upserts.last?.name, reversed.upserts.last?.name)
        XCTAssertEqual(forward.upserts.last?.contentHash, reversed.upserts.last?.contentHash)
        XCTAssertEqual(forward.upserts.last?.name, "final.png")
    }
}
