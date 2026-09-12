// Stored-byte quota and multipart upload (docs/SHARED-LIBRARY.md §8.4, §9).

import { env, createExecutionContext, waitOnExecutionContext, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index";
import { loadOwners, saveOwners } from "../src/common";
import { quotaFor, STORED_BYTES_PER_OWNER } from "../src/quota";

const ULID_A = "01JBAAAAAAAAAAAAAAAAAAAAAA";
const ownerAuth = { authorization: "Bearer test-token" };
const enabled = () => ({ ...env, LIBRARY_OWNERS: "darrin" });

async function call(path: string, init: RequestInit = {}, withEnv = env) {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new Request(`https://kapture.sh${path}`, init), withEnv, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

async function device() {
  const owners = await loadOwners(env);
  for (const record of Object.values(owners)) {
    delete record.devices; delete record.hadDevice; delete record.keyID;
  }
  await saveOwners(env, owners);
  const response = await call("/api/library/enroll", {
    method: "POST",
    headers: { ...ownerAuth, "content-type": "application/json" },
    body: JSON.stringify({ deviceID: ULID_A, name: "Studio" }),
  }, enabled());
  return (await response.json() as { token: string }).token;
}

describe("F56 — stored bytes are charged and credited", () => {
  it("charges an upload and credits a delete", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/QUOTA1/1/${ULID_A}`;

    await call(path, { method: "PUT", headers: auth, body: "0123456789" }, enabled());
    let usage = await call("/api/library/usage", { headers: auth }, enabled());
    expect((await usage.json() as { storedBytes: number }).storedBytes).toBe(10);

    await call(path, { method: "DELETE", headers: auth }, enabled());
    usage = await call("/api/library/usage", { headers: auth }, enabled());
    expect((await usage.json() as { storedBytes: number }).storedBytes).toBe(0);
  });

  it("refuses an upload that would cross the stored ceiling (F58)", async () => {
    const token = await device();
    const stub = quotaFor(env, "darrin");
    await runInDurableObject(stub, async (_instance, state) => {
      await state.storage.put("stored",
        { storedBytes: STORED_BYTES_PER_OWNER - 2, storedObjects: 1 });
    });

    const response = await call(`/api/library/blob/blob/QUOTA2/1/${ULID_A}`, {
      method: "PUT", headers: { authorization: `Bearer ${token}` }, body: "0123456789",
    }, enabled());

    expect(response.status).toBe(429);
    expect((await response.json() as { error: string }).error).toContain("stored quota");
  });

  it("never credits below zero, whatever the caller claims", async () => {
    const stub = quotaFor(env, "credit-floor");
    await stub.creditLibrary(1_000_000);
    expect((await stub.storedUsage()).storedBytes).toBe(0);
  });

  it("reconciles drift from what R2 actually holds (F76)", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    await call(`/api/library/blob/blob/DRIFT1/1/${ULID_A}`,
               { method: "PUT", headers: auth, body: "12345" }, enabled());

    // Counters drift when a delete fails partway; pretend they have.
    const stub = quotaFor(env, "darrin");
    await runInDurableObject(stub, async (_instance, state) => {
      await state.storage.put("stored", { storedBytes: 999_999, storedObjects: 42 });
    });

    const response = await call("/api/library/usage?reconcile=1", { headers: auth }, enabled());
    const usage = await response.json() as { storedBytes: number };
    expect(usage.storedBytes).toBe(5);
  });
});

describe("F54, F87 — multipart upload", () => {
  it("joins staged parts into one object and cleans them up", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/BIG1/1/${ULID_A}`;

    await call(`${path}?part=1`, { method: "PUT", headers: auth, body: "hello " }, enabled());
    await call(`${path}?part=2`, { method: "PUT", headers: auth, body: "world" }, enabled());
    const done = await call(`${path}?complete=2`, { method: "POST", headers: auth }, enabled());
    expect(done.status).toBe(200);

    const get = await call(path, { headers: auth }, enabled());
    expect(await get.text()).toBe("hello world");

    // The staged parts are gone, so a failed upload cannot leave the bucket littered.
    expect(await env.BUCKET.head(`lib/darrin/blob/BIG1/1/${ULID_A}.part1`)).toBeNull();
  });

  it("refuses completion when a part never arrived", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/BIG2/1/${ULID_A}`;
    await call(`${path}?part=1`, { method: "PUT", headers: auth, body: "only one" }, enabled());

    const done = await call(`${path}?complete=3`, { method: "POST", headers: auth }, enabled());

    expect(done.status).toBe(409);
    expect((await done.json() as { error: string }).error).toContain("missing part");
  });

  it("charges the joined size against the quota", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/BIG3/1/${ULID_A}`;
    await call(`${path}?part=1`, { method: "PUT", headers: auth, body: "abcde" }, enabled());
    await call(`${path}?complete=1`, { method: "POST", headers: auth }, enabled());

    const usage = await call("/api/library/usage", { headers: auth }, enabled());
    expect((await usage.json() as { storedBytes: number }).storedBytes).toBe(5);
  });
});
