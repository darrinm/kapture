// The shared library log — see docs/SHARED-LIBRARY.md.
//
// One Durable Object per owner holds the ordered operation log. The DO is single-threaded per
// instance, which is what makes `seq` a total order without a lock (§5.1 F17, F18) — the same
// guarantee the client's `withOperation` gives locally.
//
// Everything here acts on the plaintext envelope. The payload is ciphertext this Worker cannot
// read and never tries to (§6.1 F97): every rule below is expressible over the envelope alone,
// which is the constraint that makes them enforceable rather than aspirational.

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./common";

/** What a client sends. `ciphertext` is opaque; everything else is the envelope (F97). */
export interface OpEnvelope {
  opID: string;
  deviceID: string;
  blindedID: string;
  /** Payload version, so the server can police snapshot completeness (F102). */
  v: number;
  /** Blob revisions this op names, checked against R2 before the op is admitted (F32, F98). */
  requires: BlobRef[];
  /** The seq this device had applied when it wrote the op (F106, F109). */
  observed: number;
  /** Only `delete` is meaningful to the server; the rest are opaque labels it stores. */
  kind: "upsert" | "trash" | "restore" | "delete";
  ciphertext: ArrayBuffer | Uint8Array;
}

export interface BlobRef {
  purpose: "blob" | "thumb" | "orig";
  revision: number;
  writer: string;
  /**
   * The blindedID the bytes are filed under, defaulting to the op's own (F98, F128). A fork
   * gets a fresh blindedID but re-uploads nothing, so its dependency has to name the capture it
   * forked from or it would resolve to a key nobody ever wrote.
   */
  capture?: string;
}

/** One op as the log stores it: the envelope, plus the ciphertext the server never opens. */
export type StoredOp = {
  seq: number;
  opID: string;
  deviceID: string;
  blindedID: string;
  v: number;
  kind: string;
  observed: number;
  ciphertext: ArrayBuffer;
  at: string;
  [key: string]: SqlStorageValue;
};

/**
 * Why an op was refused.
 *
 * The code, not the prose, is what a client branches on: `tombstoned` and `stale-delete` can
 * never succeed on retry and `missing-blob` can, and a client that told them apart by matching
 * substrings of `reason` would change behaviour the next time either sentence was reworded.
 */
export type RejectionCode = "tombstoned" | "stale-delete" | "missing-blob";

export interface AppendOutcome {
  assigned: { opID: string; seq: number }[];
  rejected: { opID: string; code: RejectionCode; reason: string }[];
  head: number;
}

/**
 * The R2 key layout, in one place (§5.2).
 *
 * `append`'s F32 dependency check and the blob route both build these. Spelled out twice they
 * can drift, and the failure is silent in the worst direction: `append` rejects every op with
 * "missing blob" while the bytes are sitting in the bucket.
 */
export function blobKey(owner: string, purpose: string, capture: string,
                        revision: number, writer: string): string {
  return `${ownerPrefix(owner)}${purpose}/${capture}/${revision}/${writer}`;
}

export function snapshotKey(owner: string, seq: number, writer: string): string {
  return `${ownerPrefix(owner)}snap/${seq}/${writer}`;
}

export function ownerPrefix(owner: string): string {
  return `lib/${owner}/`;
}

/** opIDs outlive their ops so a retry after compaction is still recognized (F103). */
const OPID_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const SWEEP_LEASE_MS = 30 * 60 * 1000;
/** How long a granted snapshot claim stays valid for its upload. */
const SNAPSHOT_CLAIM_MS = 60 * 60 * 1000;
const MAX_PAGE = 500;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS ops (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  opID       TEXT NOT NULL UNIQUE,
  deviceID   TEXT NOT NULL,
  blindedID  TEXT NOT NULL,
  v          INTEGER NOT NULL,
  kind       TEXT NOT NULL,
  observed   INTEGER NOT NULL,
  ciphertext BLOB NOT NULL,
  bytes      INTEGER NOT NULL,
  at         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ops_by_capture ON ops(blindedID, seq);

-- Survives compaction of the op itself, which is the whole point (F103).
CREATE TABLE IF NOT EXISTS seen_ops (
  opID     TEXT PRIMARY KEY,
  seq      INTEGER NOT NULL,
  expires  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS snapshots (
  seq   INTEGER PRIMARY KEY,
  key   TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  deviceID   TEXT PRIMARY KEY,
  cursor     INTEGER NOT NULL DEFAULT 0,
  lastSeenAt TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS leases (
  name   TEXT PRIMARY KEY,
  holder TEXT NOT NULL,
  until  INTEGER NOT NULL
);

-- Below this line: state that must outlive compaction, because a rule depends on it.

-- F132: a delete is final when it is admitted, not when the bytes are removed. Without this,
-- a write accepted in between is destroyed by F20's prefix delete.
CREATE TABLE IF NOT EXISTS tombstones (
  blindedID TEXT PRIMARY KEY,
  seq       INTEGER NOT NULL,
  expires   INTEGER NOT NULL
);

-- F134: F108 dates sweep eligibility from the server's trash time and F45 forbids trusting the
-- client's. Compaction would otherwise erase the only admissible evidence.
CREATE TABLE IF NOT EXISTS trash_marks (
  blindedID TEXT PRIMARY KEY,
  at        INTEGER NOT NULL
);

-- F136: a high-water mark that only rises. MAX(v) over surviving ops falls when compaction
-- removes the op that raised it.
CREATE TABLE IF NOT EXISTS log_meta (
  key   TEXT PRIMARY KEY,
  value INTEGER NOT NULL
);

-- Device credentials (§3). These lived in the KV owner table, which is eventually consistent:
-- inside its propagation window a second Mac could read a stale "no device yet", enrol with no
-- approval, and overwrite the first Mac's entry, and a revoked credential kept working at other
-- edge locations. Here every check and write is one transaction in one place.
CREATE TABLE IF NOT EXISTS credentials (
  deviceID    TEXT PRIMARY KEY,
  hash        TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  platform    TEXT NOT NULL,
  createdAt   TEXT NOT NULL,
  lastSeenAt  TEXT,
  approved    INTEGER NOT NULL,
  fingerprint TEXT NOT NULL
);

-- The library's keyID (F117) and whether it has ever had a device (F114).
CREATE TABLE IF NOT EXISTS library_settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- F102: a snapshot PUT must follow a granted claim, or a device could write a "whole library at
-- seq N" that the completeness gate never examined.
CREATE TABLE IF NOT EXISTS snapshot_claims (
  deviceID TEXT NOT NULL,
  seq      INTEGER NOT NULL,
  expires  INTEGER NOT NULL,
  PRIMARY KEY (deviceID, seq)
);
`;

export class LibraryLog extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.storage.sql.exec(SCHEMA);
  }

  private sql() {
    return this.ctx.storage.sql;
  }

  private head(): number {
    const row = this.sql().exec<{ head: number | null }>("SELECT MAX(seq) AS head FROM ops").one();
    return row.head ?? 0;
  }

  /**
   * The highest payload version ever written (F136). Read from the high-water mark rather than
   * computed from surviving ops: compaction can remove the op that raised it, which would lower
   * the gate and let an old client overwrite a library it cannot fully read.
   */
  private maxVersion(): number {
    const rows = this.sql()
      .exec<{ value: number }>("SELECT value FROM log_meta WHERE key = 'maxVersion'")
      .toArray();
    return rows[0]?.value ?? 0;
  }

  private raiseMaxVersion(v: number, known: number): number {
    if (v <= known) return known;
    this.sql().exec(
      "INSERT OR REPLACE INTO log_meta (key, value) VALUES ('maxVersion', ?)", v,
    );
    return v;
  }

  /**
   * Admit a batch.
   *
   * The R2 existence checks (F32) run before the transaction because they are network calls and
   * a storage transaction may not await one. That leaves a window in which a blob could be
   * deleted between check and commit; deletion is lease-held and follows an admitted delete op
   * (F43, F107), so nothing in the specified flow deletes a blob an in-flight op names.
   */
  async append(owner: string, ops: OpEnvelope[]): Promise<AppendOutcome> {
    // One round trip's latency rather than one per reference: the checks are independent, a
    // batch carries up to 100 ops, and several ops naming one blob (ordinary after a fork)
    // would otherwise head the same key repeatedly.
    const wanted = new Map<string, { opID: string; label: string }[]>();
    for (const op of ops) {
      for (const ref of op.requires ?? []) {
        // `capture` defaults to this op's own, and differs for a fork inheriting bytes it
        // already uploaded under the capture it forked from (F128).
        const key = blobKey(owner, ref.purpose, ref.capture ?? op.blindedID,
                            ref.revision, ref.writer);
        const label = `missing blob ${ref.purpose}/${ref.revision}`;
        wanted.set(key, [...(wanted.get(key) ?? []), { opID: op.opID, label }]);
      }
    }
    const keys = [...wanted.keys()];
    const present = await Promise.all(keys.map((key) => this.env.BUCKET.head(key)));
    const missing = new Map<string, string>();
    keys.forEach((key, index) => {
      if (present[index]) return;
      for (const { opID, label } of wanted.get(key)!) {
        if (!missing.has(opID)) missing.set(opID, label);
      }
    });

    const assigned: { opID: string; seq: number }[] = [];
    const rejected: { opID: string; code: RejectionCode; reason: string }[] = [];
    const now = Date.now();

    this.ctx.storage.transactionSync(() => {
      this.sql().exec("DELETE FROM seen_ops WHERE expires < ?", now);
      this.sql().exec("DELETE FROM tombstones WHERE expires < ?", now);
      let highestVersion = this.maxVersion();

      for (const op of ops) {
        // An opID we have already admitted is a retry whose response was lost (F31). Answer with
        // the seq it got the first time rather than storing it twice.
        const seen = this.sql()
          .exec<{ seq: number }>("SELECT seq FROM seen_ops WHERE opID = ?", op.opID)
          .toArray();
        if (seen.length > 0) {
          assigned.push({ opID: op.opID, seq: seen[0].seq });
          continue;
        }

        // F132: a capture with a tombstone is closed. A write admitted after the delete was
        // accepted would be destroyed by F20's prefix cleanup, so it is refused up front rather
        // than acknowledged and then silently removed.
        const tombstoned = this.sql()
          .exec<{ seq: number }>("SELECT seq FROM tombstones WHERE blindedID = ?", op.blindedID)
          .toArray();
        if (tombstoned.length > 0) {
          rejected.push({ opID: op.opID, code: "tombstoned",
                          reason: `capture deleted at ${tombstoned[0].seq}` });
          continue;
        }

        const reason = missing.get(op.opID);
        if (reason) {
          rejected.push({ opID: op.opID, code: "missing-blob", reason });
          continue;
        }

        // F106: a delete is conditional on nothing having happened to the capture since the
        // holder observed it as trash. Pulling to head is not enough — a restore can land in
        // between, and the sweep lease excludes other sweepers, not other writers.
        if (op.kind === "delete") {
          const latest = this.sql()
            .exec<{ seq: number | null }>(
              "SELECT MAX(seq) AS seq FROM ops WHERE blindedID = ?", op.blindedID,
            ).one().seq ?? 0;
          if (latest > op.observed) {
            rejected.push({ opID: op.opID, code: "stale-delete",
                            reason: `stale delete: capture changed at ${latest}` });
            continue;
          }
        }

        const bytes = op.ciphertext.byteLength;
        this.sql().exec(
          `INSERT INTO ops (opID, deviceID, blindedID, v, kind, observed, ciphertext, bytes, at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          op.opID, op.deviceID, op.blindedID, op.v, op.kind, op.observed,
          op.ciphertext, bytes, new Date().toISOString(),
        );
        const seq = this.sql()
          .exec<{ seq: number }>("SELECT last_insert_rowid() AS seq").one().seq;
        this.sql().exec(
          "INSERT INTO seen_ops (opID, seq, expires) VALUES (?, ?, ?)",
          op.opID, seq, now + OPID_RETENTION_MS,
        );
        highestVersion = this.raiseMaxVersion(op.v, highestVersion);

        // F134: the trash time the sweep will date eligibility from, kept where compaction
        // cannot reach it. A restore or a delete settles the question and clears the mark.
        if (op.kind === "trash") {
          this.sql().exec(
            "INSERT OR REPLACE INTO trash_marks (blindedID, at) VALUES (?, ?)", op.blindedID, now,
          );
        } else if (op.kind === "restore") {
          this.sql().exec("DELETE FROM trash_marks WHERE blindedID = ?", op.blindedID);
        } else if (op.kind === "delete") {
          this.sql().exec("DELETE FROM trash_marks WHERE blindedID = ?", op.blindedID);
          this.sql().exec(
            "INSERT OR REPLACE INTO tombstones (blindedID, seq, expires) VALUES (?, ?, ?)",
            op.blindedID, seq, now + OPID_RETENTION_MS,
          );
        }
        assigned.push({ opID: op.opID, seq });
      }
    });

    return { assigned, rejected, head: this.head() };
  }

  async changes(since: number, limit = MAX_PAGE) {
    const capped = Math.min(Math.max(limit, 1), MAX_PAGE);
    const rows = this.sql().exec<StoredOp>(
      `SELECT seq, opID, deviceID, blindedID, v, kind, observed, ciphertext, at
       FROM ops WHERE seq > ? ORDER BY seq LIMIT ?`,
      since, capped,
    ).toArray();
    const oldest = this.sql()
      .exec<{ seq: number | null }>("SELECT MIN(seq) AS seq FROM ops").one().seq ?? 0;
    return { ops: rows, head: this.head(), oldestRetained: oldest };
  }

  /**
   * F102: a snapshot asserts "this is the whole library at seq N". A device that skipped an op
   * it could not parse cannot make that assertion, and if it did, F34's compaction would delete
   * the only copy of the capture it omitted. Version is the part the server can check.
   */
  async claimSnapshot(deviceID: string, supportsV: number, seq: number) {
    const required = this.maxVersion();
    if (supportsV < required) {
      return { granted: false as const, reason: `log contains v${required} ops`, required };
    }
    if (seq !== this.head()) {
      return { granted: false as const, reason: "snapshot must be taken at head", required };
    }
    this.sql().exec(
      "INSERT OR REPLACE INTO snapshot_claims (deviceID, seq, expires) VALUES (?, ?, ?)",
      deviceID, seq, Date.now() + SNAPSHOT_CLAIM_MS,
    );
    return { granted: true as const, seq, required };
  }

  /** True once, for the device and seq a claim was granted to. */
  async consumeSnapshotClaim(deviceID: string, seq: number): Promise<boolean> {
    let granted = false;
    this.ctx.storage.transactionSync(() => {
      this.sql().exec("DELETE FROM snapshot_claims WHERE expires < ?", Date.now());
      const rows = this.sql()
        .exec("SELECT 1 FROM snapshot_claims WHERE deviceID = ? AND seq = ?", deviceID, seq)
        .toArray();
      if (rows.length === 0) return;
      this.sql().exec("DELETE FROM snapshot_claims WHERE deviceID = ? AND seq = ?", deviceID, seq);
      granted = true;
    });
    return granted;
  }

  async recordSnapshot(seq: number, key: string, bytes: number) {
    this.sql().exec(
      "INSERT OR REPLACE INTO snapshots (seq, key, bytes, at) VALUES (?, ?, ?, ?)",
      seq, key, bytes, new Date().toISOString(),
    );
  }

  /** F43: one sweeper at a time, for a bounded window, not renewable within a pass. */
  async acquireSweepLease(deviceID: string, now = Date.now()) {
    let granted = false;
    let until = 0;
    this.ctx.storage.transactionSync(() => {
      const rows = this.sql()
        .exec<{ holder: string; until: number }>("SELECT holder, until FROM leases WHERE name = 'sweep'")
        .toArray();
      const current = rows[0];
      if (current && current.until > now && current.holder !== deviceID) return;
      until = now + SWEEP_LEASE_MS;
      this.sql().exec(
        "INSERT OR REPLACE INTO leases (name, holder, until) VALUES ('sweep', ?, ?)",
        deviceID, until,
      );
      granted = true;
    });
    return { granted, until };
  }

  /**
   * Captures whose trash mark is older than the window (F45, F108, F134). Both ends are server
   * time: the mark the DO wrote, and the DO's clock. No client timestamp enters the comparison,
   * and no answer depends on an op that compaction may have removed.
   */
  async sweepEligible(windowMs: number, now = Date.now()): Promise<string[]> {
    return this.sql()
      .exec<{ blindedID: string }>(
        "SELECT blindedID FROM trash_marks WHERE at <= ? ORDER BY at", now - windowMs,
      )
      .toArray()
      .map((row) => row.blindedID);
  }

  async noteDevice(deviceID: string, cursor: number) {
    this.ctx.storage.transactionSync(() => {
      this.sql().exec(
        `INSERT INTO devices (deviceID, cursor, lastSeenAt) VALUES (?, ?, ?)
         ON CONFLICT(deviceID) DO UPDATE SET cursor = excluded.cursor, lastSeenAt = excluded.lastSeenAt`,
        deviceID, cursor, new Date().toISOString(),
      );
    });
  }

  /**
   * Drop ops at or below `through`, as F34's compaction will. Exposed so a test can prove the
   * state that must outlive compaction actually does; the real compaction path is M6c.
   */
  async forgetOpsForTest(through: number) {
    this.sql().exec("DELETE FROM ops WHERE seq <= ?", through);
  }

  // ---- device credentials (§3, F8) --------------------------------------

  private setting(key: string): string | null {
    const rows = this.sql()
      .exec<{ value: string }>("SELECT value FROM library_settings WHERE key = ?", key)
      .toArray();
    return rows[0]?.value ?? null;
  }

  /**
   * Enrol a device, atomically.
   *
   * F5/F113/F114 — silent only for the first device this owner has ever had — and F117 — one key
   * per library — are a read followed by a write. In KV that pair raced across edge locations;
   * here it is one transaction on one object, so two Macs enrolling at once cannot both be first.
   */
  async enrol(device: {
    deviceID: string; hash: string; name: string; platform: string;
    keyID: string; fingerprint: string;
  }): Promise<{ approved: boolean } | { error: "key-mismatch"; keyID: string }> {
    let outcome: { approved: boolean } | { error: "key-mismatch"; keyID: string } =
      { approved: false };
    this.ctx.storage.transactionSync(() => {
      const keyID = this.setting("keyID");
      if (keyID && device.keyID && device.keyID !== keyID) {
        outcome = { error: "key-mismatch", keyID };
        return;
      }
      const approved = this.setting("hadDevice") !== "1";
      this.sql().exec(
        `INSERT OR REPLACE INTO credentials
           (deviceID, hash, name, platform, createdAt, approved, fingerprint)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        device.deviceID, device.hash, device.name, device.platform,
        new Date().toISOString(), approved ? 1 : 0, device.fingerprint,
      );
      this.sql().exec(
        "INSERT OR REPLACE INTO library_settings (key, value) VALUES ('hadDevice', '1')");
      if (!keyID && device.keyID) {
        this.sql().exec(
          "INSERT OR REPLACE INTO library_settings (key, value) VALUES ('keyID', ?)", device.keyID);
      }
      outcome = { approved };
    });
    return outcome;
  }

  /**
   * The device a credential hash belongs to, or null.
   *
   * A lookup by hash rather than a constant-time scan: the hash is SHA-256 of a 192-bit random
   * token, so learning anything from lookup timing would need a preimage first.
   */
  async verifyDevice(hash: string): Promise<{ deviceID: string; approved: boolean } | null> {
    const rows = this.sql()
      .exec<{ deviceID: string; approved: number }>(
        "SELECT deviceID, approved FROM credentials WHERE hash = ?", hash)
      .toArray();
    const found = rows[0];
    if (!found) return null;
    this.sql().exec("UPDATE credentials SET lastSeenAt = ? WHERE deviceID = ?",
                    new Date().toISOString(), found.deviceID);
    return { deviceID: found.deviceID, approved: found.approved === 1 };
  }

  async listDevices() {
    return this.sql()
      .exec<{ deviceID: string; name: string; platform: string; createdAt: string;
              lastSeenAt: string | null; approved: number; fingerprint: string }>(
        `SELECT deviceID, name, platform, createdAt, lastSeenAt, approved, fingerprint
         FROM credentials ORDER BY createdAt`)
      .toArray()
      .map((row) => ({ ...row, approved: row.approved === 1 }));
  }

  async approveDevice(deviceID: string): Promise<boolean> {
    const before = this.sql()
      .exec("SELECT 1 FROM credentials WHERE deviceID = ?", deviceID).toArray().length;
    if (before === 0) return false;
    this.sql().exec("UPDATE credentials SET approved = 1 WHERE deviceID = ?", deviceID);
    return true;
  }

  /** Immediate: the next request carrying this credential finds nothing to match (F8). */
  async revokeDevice(deviceID: string): Promise<boolean> {
    const before = this.sql()
      .exec("SELECT 1 FROM credentials WHERE deviceID = ?", deviceID).toArray().length;
    if (before === 0) return false;
    // `hadDevice` stays set, so revoking the last device does not reopen silent enrolment (F114).
    this.sql().exec("DELETE FROM credentials WHERE deviceID = ?", deviceID);
    return true;
  }

  /** Test/diagnostic view. Never routed. */
  async stats() {
    return {
      head: this.head(),
      maxVersion: this.maxVersion(),
      ops: this.sql().exec<{ n: number }>("SELECT COUNT(*) AS n FROM ops").one().n,
      seen: this.sql().exec<{ n: number }>("SELECT COUNT(*) AS n FROM seen_ops").one().n,
    };
  }
}

export function libraryLogFor(env: Env, owner: string): DurableObjectStub<LibraryLog> {
  return env.LIBRARY_LOGS.get(env.LIBRARY_LOGS.idFromName(owner));
}

/**
 * F118: the library routes are enabled for an explicit allowlist, empty by default. A fork
 * deployed without reading the spec serves no libraries, which is the correct default for a
 * feature whose bytes someone has to pay for.
 */
export function libraryEnabled(env: Env, owner: string): boolean {
  const raw = (env.LIBRARY_OWNERS ?? "").trim();
  if (!raw) return false;
  return raw.split(",").map((name) => name.trim()).filter(Boolean).includes(owner);
}
