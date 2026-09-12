// The library's HTTP surface (docs/SHARED-LIBRARY.md §5.3), end to end through the Worker.

import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index";
import { loadOwners, saveOwners, sha256Hex } from "../src/common";

const ULID_A = "01JBAAAAAAAAAAAAAAAAAAAAAA";
const ULID_B = "01JBBBBBBBBBBBBBBBBBBBBBBB";

/** The suite's owner token is "test-token" for `darrin`, per vitest.config.ts. */
const ownerAuth = { authorization: "Bearer test-token" };

async function call(path: string, init: RequestInit = {}, withEnv = env) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new Request(`https://kapture.sh${path}`, init), withEnv, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

/** The allowlist is empty by default (F118); most tests need it on. */
const enabled = () => ({ ...env, LIBRARY_OWNERS: "darrin" });

async function resetOwners() {
  const owners = await loadOwners(env);
  for (const record of Object.values(owners)) {
    delete record.devices;
    delete record.hadDevice;
    delete record.keyID;
  }
  await saveOwners(env, owners);
}

async function enrolFirstDevice(deviceID = ULID_A) {
  const response = await call("/api/library/enroll", {
    method: "POST",
    headers: { ...ownerAuth, "content-type": "application/json" },
    body: JSON.stringify({ deviceID, name: "Studio", platform: "macOS", keyID: "abc123" }),
  }, enabled());
  return await response.json() as
    { deviceID: string; token: string; approved: boolean; fingerprint: string };
}

beforeEach(resetOwners);

describe("F118 — the allowlist gates every route", () => {
  it("404s enrolment when the owner is not allowlisted", async () => {
    const response = await call("/api/library/enroll", {
      method: "POST", headers: ownerAuth, body: JSON.stringify({ deviceID: ULID_A }),
    });
    expect(response.status).toBe(404);
  });

  it("leaves the M5 share routes working for the same owner", async () => {
    const response = await call("/api/list", { headers: ownerAuth });
    expect(response.status).toBe(200);
  });
});

describe("§3.2 — enrolment", () => {
  it("enrols the first device silently and issues a credential (F5)", async () => {
    const body = await enrolFirstDevice();
    expect(body.approved).toBe(true);
    expect(body.token).toBeTruthy();
  });

  it("requires approval for every later device (F113)", async () => {
    await enrolFirstDevice();
    const response = await call("/api/library/enroll", {
      method: "POST",
      headers: { ...ownerAuth, "content-type": "application/json" },
      body: JSON.stringify({ deviceID: ULID_B, name: "Laptop" }),
    }, enabled());
    expect(response.status).toBe(202);
    const body = await response.json() as { approved: boolean; token: string };
    expect(body.approved).toBe(false);

    // The unapproved credential opens nothing.
    const denied = await call("/api/library/changes?since=0", {
      headers: { authorization: `Bearer ${body.token}` },
    }, enabled());
    expect(denied.status).toBe(401);
  });

  it("keeps the gate closed after the last device is revoked (F114)", async () => {
    const first = await enrolFirstDevice();
    await call(`/api/library/devices/${ULID_A}`, {
      method: "DELETE", headers: { authorization: `Bearer ${first.token}` },
    }, enabled());

    // A stolen Mac still holding the owner token must not simply enrol again.
    const again = await call("/api/library/enroll", {
      method: "POST",
      headers: { ...ownerAuth, "content-type": "application/json" },
      body: JSON.stringify({ deviceID: ULID_B }),
    }, enabled());
    expect(again.status).toBe(202);
    expect((await again.json() as { approved: boolean }).approved).toBe(false);
  });

  it("refuses a device carrying a different library key (F117)", async () => {
    await enrolFirstDevice();
    const response = await call("/api/library/enroll", {
      method: "POST",
      headers: { ...ownerAuth, "content-type": "application/json" },
      body: JSON.stringify({ deviceID: ULID_B, keyID: "a-different-key" }),
    }, enabled());
    expect(response.status).toBe(409);
  });

  it("approves a pending device, which then works (F125)", async () => {
    const first = await enrolFirstDevice();
    const pending = await call("/api/library/enroll", {
      method: "POST",
      headers: { ...ownerAuth, "content-type": "application/json" },
      body: JSON.stringify({ deviceID: ULID_B }),
    }, enabled());
    const second = await pending.json() as { token: string; fingerprint: string };
    expect(second.fingerprint).toMatch(/^[0-9A-F]{4}-[0-9A-F]{4}$/);

    await call(`/api/library/devices/${ULID_B}/approve`, {
      method: "POST", headers: { authorization: `Bearer ${first.token}` },
    }, enabled());

    const allowed = await call("/api/library/changes?since=0", {
      headers: { authorization: `Bearer ${second.token}` },
    }, enabled());
    expect(allowed.status).toBe(200);
  });
});

describe("F2/F21 — the owner credential does not open the library", () => {
  it("refuses the owner token on a device route", async () => {
    await enrolFirstDevice();
    const response = await call("/api/library/changes?since=0", { headers: ownerAuth }, enabled());
    expect(response.status).toBe(401);
  });
});

describe("§6 — push and pull", () => {
  it("round-trips an op and returns it to another cursor", async () => {
    const device = await enrolFirstDevice();
    const auth = { authorization: `Bearer ${device.token}`, "content-type": "application/json" };

    const push = await call("/api/library/ops", {
      method: "POST", headers: auth,
      body: JSON.stringify({ ops: [{
        opID: "01JBQP00000000000000000001", blindedID: "CAPTURE1", v: 1, kind: "upsert",
        requires: [], observed: 0, ciphertext: btoa("sealed-row"),
      }] }),
    }, enabled());
    expect(push.status).toBe(200);
    const assigned = await push.json() as { assigned: { seq: number }[]; head: number };
    expect(assigned.assigned[0].seq).toBe(1);

    const pull = await call("/api/library/changes?since=0", {
      headers: { authorization: `Bearer ${device.token}` },
    }, enabled());
    const page = await pull.json() as { ops: { ciphertext: string; kind: string }[]; head: number };
    expect(page.head).toBe(1);
    expect(atob(page.ops[0].ciphertext)).toBe("sealed-row");
    expect(page.ops[0].kind).toBe("upsert");
  });

  it("is idempotent for a retried batch (F31)", async () => {
    const device = await enrolFirstDevice();
    const auth = { authorization: `Bearer ${device.token}`, "content-type": "application/json" };
    const body = JSON.stringify({ ops: [{
      opID: "01JBQP00000000000000000002", blindedID: "CAPTURE1", v: 1, kind: "upsert",
      requires: [], observed: 0, ciphertext: btoa("x"),
    }] });

    const first = await call("/api/library/ops", { method: "POST", headers: auth, body }, enabled());
    const second = await call("/api/library/ops", { method: "POST", headers: auth, body }, enabled());

    const a = await first.json() as { assigned: { seq: number }[] };
    const b = await second.json() as { assigned: { seq: number }[] };
    expect(b.assigned[0].seq).toBe(a.assigned[0].seq);
  });

  it("rejects an op naming a blob that is not there (F32)", async () => {
    const device = await enrolFirstDevice();
    const response = await call("/api/library/ops", {
      method: "POST",
      headers: { authorization: `Bearer ${device.token}`, "content-type": "application/json" },
      body: JSON.stringify({ ops: [{
        opID: "01JBQP00000000000000000003", blindedID: "CAPTURE1", v: 1, kind: "upsert",
        requires: [{ purpose: "blob", revision: 1, writer: ULID_A }],
        observed: 0, ciphertext: btoa("x"),
      }] }),
    }, enabled());
    expect(response.status).toBe(409);
    const body = await response.json() as { rejected: { reason: string }[] };
    expect(body.rejected[0].reason).toContain("missing blob");
  });

  it("caps a batch at 100 ops (F30)", async () => {
    const device = await enrolFirstDevice();
    const ops = Array.from({ length: 101 }, (_, i) => ({
      opID: `01JBQP0000000000000000${String(i).padStart(4, "0")}`,
      blindedID: "C", v: 1, kind: "upsert", requires: [], observed: 0, ciphertext: btoa("x"),
    }));
    const response = await call("/api/library/ops", {
      method: "POST",
      headers: { authorization: `Bearer ${device.token}`, "content-type": "application/json" },
      body: JSON.stringify({ ops }),
    }, enabled());
    expect(response.status).toBe(400);
  });
});

describe("§8 — blobs", () => {
  it("stores and returns bytes, and treats an identical re-PUT as a retry (F99)", async () => {
    const device = await enrolFirstDevice();
    const auth = { authorization: `Bearer ${device.token}` };
    const path = `/api/library/blob/blob/CAPTURE1/1/${ULID_A}`;

    const first = await call(path, { method: "PUT", headers: auth, body: "pixels" }, enabled());
    expect(first.status).toBe(200);

    const retry = await call(path, { method: "PUT", headers: auth, body: "pixels" }, enabled());
    expect(retry.status).toBe(200);
    expect((await retry.json() as { retry: boolean }).retry).toBe(true);

    const conflict = await call(path, { method: "PUT", headers: auth, body: "other" }, enabled());
    expect(conflict.status).toBe(409);

    const get = await call(path, { headers: auth }, enabled());
    expect(await get.text()).toBe("pixels");
  });

  it("refuses to let a device write another device's blob", async () => {
    const device = await enrolFirstDevice();
    const response = await call(`/api/library/blob/blob/CAPTURE1/1/${ULID_B}`, {
      method: "PUT", headers: { authorization: `Bearer ${device.token}` }, body: "x",
    }, enabled());
    expect(response.status).toBe(403);
  });
});

describe("§7.4 — the sweep lease over HTTP", () => {
  it("grants once and reports eligible captures", async () => {
    const device = await enrolFirstDevice();
    const auth = { authorization: `Bearer ${device.token}`, "content-type": "application/json" };
    await call("/api/library/ops", {
      method: "POST", headers: auth,
      body: JSON.stringify({ ops: [{
        opID: "01JBQP00000000000000000009", blindedID: "OLDONE", v: 1, kind: "trash",
        requires: [], observed: 0, ciphertext: btoa("x"),
      }] }),
    }, enabled());

    const lease = await call("/api/library/lease/sweep?windowMs=0", {
      method: "POST", headers: auth,
    }, enabled());
    expect(lease.status).toBe(200);
    const body = await lease.json() as { granted: boolean; eligible: string[] };
    expect(body.granted).toBe(true);
    expect(body.eligible).toContain("OLDONE");
  });
});
