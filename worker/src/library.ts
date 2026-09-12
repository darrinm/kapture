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

export interface AppendOutcome {
  assigned: { opID: string; seq: number }[];
  rejected: { opID: string; reason: string }[];
  head: number;
}

/** opIDs outlive their ops so a retry after compaction is still recognized (F103). */
const OPID_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const SWEEP_LEASE_MS = 30 * 60 * 1000;
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

  /** The highest payload version anyone has written. A snapshot from below this is refused. */
  private maxVersion(): number {
    const row = this.sql().exec<{ v: number | null }>("SELECT MAX(v) AS v FROM ops").one();
    return row.v ?? 0;
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
    const missing = new Map<string, string>();
    for (const op of ops) {
      for (const ref of op.requires ?? []) {
        const key = `lib/${owner}/${ref.purpose}/${op.blindedID}/${ref.revision}/${ref.writer}`;
        if (!(await this.env.BUCKET.head(key))) {
          missing.set(op.opID, `missing blob ${ref.purpose}/${ref.revision}`);
          break;
        }
      }
    }

    const assigned: { opID: string; seq: number }[] = [];
    const rejected: { opID: string; reason: string }[] = [];
    const now = Date.now();

    this.ctx.storage.transactionSync(() => {
      this.sql().exec("DELETE FROM seen_ops WHERE expires < ?", now);

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

        const reason = missing.get(op.opID);
        if (reason) {
          rejected.push({ opID: op.opID, reason });
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
            rejected.push({ opID: op.opID, reason: `stale delete: capture changed at ${latest}` });
            continue;
          }
        }

        const bytes = op.ciphertext instanceof Uint8Array
          ? op.ciphertext.byteLength
          : op.ciphertext.byteLength;
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
    return { granted: true as const, seq, required };
  }

  async recordSnapshot(seq: number, key: string, bytes: number) {
    this.ctx.storage.transactionSync(() => {
      this.sql().exec(
        "INSERT OR REPLACE INTO snapshots (seq, key, bytes, at) VALUES (?, ?, ?, ?)",
        seq, key, bytes, new Date().toISOString(),
      );
    });
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

  async noteDevice(deviceID: string, cursor: number) {
    this.ctx.storage.transactionSync(() => {
      this.sql().exec(
        `INSERT INTO devices (deviceID, cursor, lastSeenAt) VALUES (?, ?, ?)
         ON CONFLICT(deviceID) DO UPDATE SET cursor = excluded.cursor, lastSeenAt = excluded.lastSeenAt`,
        deviceID, cursor, new Date().toISOString(),
      );
    });
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
