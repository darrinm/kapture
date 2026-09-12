// The shared-library log, against a real Workers runtime.
//
// These are the rules docs/SHARED-LIBRARY.md claims the server can enforce. Each was a paper
// assertion until this file ran: the point of the suite is that a requirement the server cannot
// check from the plaintext envelope is not a requirement (§6.1 F97).

import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { libraryEnabled, libraryLogFor, type OpEnvelope } from "../src/library";

const bytes = (n = 8) => new Uint8Array(Array.from({ length: n }, (_, i) => i + 1));

let counter = 0;
function op(overrides: Partial<OpEnvelope> = {}): OpEnvelope {
  counter += 1;
  return {
    opID: `op-${counter}-${Math.random().toString(36).slice(2)}`,
    deviceID: "device-a",
    blindedID: "CAPTURE1",
    v: 1,
    requires: [],
    observed: 0,
    kind: "upsert",
    ciphertext: bytes(),
    ...overrides,
  };
}

/** A unique owner per test, so each gets its own Durable Object instance. */
const owner = () => `owner-${Math.random().toString(36).slice(2)}`;

describe("the log assigns one total order", () => {
  it("numbers concurrent batches from different devices without collision or gap", async () => {
    const log = libraryLogFor(env, owner());
    const batches = await Promise.all(
      Array.from({ length: 8 }, (_, i) =>
        log.append("o", [op({ deviceID: `device-${i}`, blindedID: `CAP${i}` })]),
      ),
    );
    const seqs = batches.flatMap((b) => b.assigned.map((a) => a.seq)).sort((a, b) => a - b);
    expect(seqs).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
  });

  it("returns the original seq for a retried opID instead of storing it twice (F31)", async () => {
    const log = libraryLogFor(env, owner());
    const retried = op();
    const first = await log.append("o", [retried]);
    const second = await log.append("o", [retried]);
    expect(second.assigned[0].seq).toBe(first.assigned[0].seq);
    expect((await log.stats()).ops).toBe(1);
  });
});

describe("F32/F98 — blob dependencies are checked from the envelope", () => {
  it("rejects an op naming a blob R2 does not hold", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    const result = await log.append(name, [op({
      requires: [{ purpose: "blob", revision: 3, writer: "device-a" }],
    })]);
    expect(result.assigned).toHaveLength(0);
    expect(result.rejected[0].reason).toContain("missing blob");
  });

  it("admits the same op once the blob is present", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    await env.BUCKET.put(`lib/${name}/blob/CAPTURE1/3/device-a`, bytes());
    const result = await log.append(name, [op({
      requires: [{ purpose: "blob", revision: 3, writer: "device-a" }],
    })]);
    expect(result.rejected).toHaveLength(0);
    expect(result.assigned[0].seq).toBe(1);
  });

  it("checks every purpose, not only the full-resolution blob", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    await env.BUCKET.put(`lib/${name}/blob/CAPTURE1/1/device-a`, bytes());
    const result = await log.append(name, [op({
      requires: [
        { purpose: "blob", revision: 1, writer: "device-a" },
        { purpose: "thumb", revision: 1, writer: "device-a" },
      ],
    })]);
    expect(result.rejected[0].reason).toContain("thumb");
  });
});

describe("F106 — a delete is conditional on the log, not on a past pull", () => {
  it("refuses a delete when a restore landed after the sweeper's observed seq", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    // The sweeper pulls to head and sees the capture as trash...
    const trash = await log.append(name, [op({ kind: "trash" })]);
    const observed = trash.head;
    // ...another Mac restores it before the delete is issued...
    await log.append(name, [op({ kind: "restore", deviceID: "device-b" })]);
    // ...and the delete, which satisfied every other precondition in §7.4, is refused.
    const result = await log.append(name, [op({ kind: "delete", observed })]);
    expect(result.assigned).toHaveLength(0);
    expect(result.rejected[0].reason).toContain("stale delete");
  });

  it("admits a delete when nothing touched the capture since", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    const trash = await log.append(name, [op({ kind: "trash" })]);
    const result = await log.append(name, [op({ kind: "delete", observed: trash.head })]);
    expect(result.rejected).toHaveLength(0);
  });

  it("is per capture: an op on a different capture does not block the delete", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    const trash = await log.append(name, [op({ kind: "trash", blindedID: "CAPTURE1" })]);
    await log.append(name, [op({ blindedID: "CAPTURE2" })]);
    const result = await log.append(name, [
      op({ kind: "delete", blindedID: "CAPTURE1", observed: trash.head }),
    ]);
    expect(result.rejected).toHaveLength(0);
  });
});

describe("F102 — only a complete client may snapshot", () => {
  it("refuses a snapshot from a device that cannot read the newest payload version", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    await log.append(name, [op({ v: 2 })]);
    const claim = await log.claimSnapshot("old-device", 1, 1);
    expect(claim.granted).toBe(false);
    expect(claim.required).toBe(2);
  });

  it("allows a snapshot from a device at the log's version", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    await log.append(name, [op({ v: 2 })]);
    const claim = await log.claimSnapshot("current", 2, 1);
    expect(claim.granted).toBe(true);
  });

  it("refuses a snapshot that is not taken at head", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    await log.append(name, [op()]);
    await log.append(name, [op()]);
    expect((await log.claimSnapshot("current", 1, 1)).granted).toBe(false);
  });
});

describe("F43 — the sweep lease admits one holder", () => {
  it("grants to the first caller and refuses the rest", async () => {
    const log = libraryLogFor(env, owner());
    const results = await Promise.all(
      Array.from({ length: 6 }, (_, i) => log.acquireSweepLease(`device-${i}`)),
    );
    expect(results.filter((r) => r.granted)).toHaveLength(1);
  });

  it("grants again once the lease has expired", async () => {
    const log = libraryLogFor(env, owner());
    const first = await log.acquireSweepLease("device-a");
    expect(first.granted).toBe(true);
    const later = await log.acquireSweepLease("device-b", Date.now() + 31 * 60 * 1000);
    expect(later.granted).toBe(true);
  });
});

describe("F26 — pull is ordered and paged", () => {
  it("returns ops after the cursor, in seq order, capped at the page size", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    for (let i = 0; i < 5; i++) await log.append(name, [op()]);
    const page = await log.changes(2, 2);
    expect(page.ops.map((o) => o.seq)).toEqual([3, 4]);
    expect(page.head).toBe(5);
  });

  it("reports the oldest retained seq so a client can tell it needs a snapshot (F27)", async () => {
    const name = owner();
    const log = libraryLogFor(env, name);
    await log.append(name, [op()]);
    expect((await log.changes(0)).oldestRetained).toBe(1);
  });
});

describe("F118 — the library is off unless an owner is allowlisted", () => {
  it("is disabled when the allowlist is unset", () => {
    expect(libraryEnabled({ ...env, LIBRARY_OWNERS: undefined }, "darrin")).toBe(false);
  });

  it("is disabled when the allowlist is empty or whitespace", () => {
    expect(libraryEnabled({ ...env, LIBRARY_OWNERS: "   " }, "darrin")).toBe(false);
  });

  it("enables only the named owners", () => {
    const withList = { ...env, LIBRARY_OWNERS: "darrin, someone" };
    expect(libraryEnabled(withList, "darrin")).toBe(true);
    expect(libraryEnabled(withList, "someone")).toBe(true);
    expect(libraryEnabled(withList, "friend")).toBe(false);
  });
});
