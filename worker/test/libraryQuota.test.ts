// Stored-byte quota and multipart upload (docs/SHARED-LIBRARY.md §8.4, §9).

import { env, createExecutionContext, waitOnExecutionContext, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index";
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

describe("F54, F87 — multipart upload through R2's own API", () => {
  // The previous implementation staged parts as objects and joined them in Worker memory, about
  // twice the file in a 128 MB isolate, so no recording over the threshold could ever complete.

  async function upload(auth: Record<string, string>, path: string, parts: string[]) {
    const started = await call(`${path}?uploads`, { method: "POST", headers: auth }, enabled());
    const { uploadId } = await started.json() as { uploadId: string };
    const done: { partNumber: number; etag: string }[] = [];
    for (const [index, body] of parts.entries()) {
      const response = await call(`${path}?uploadId=${uploadId}&part=${index + 1}`,
                                  { method: "PUT", headers: auth, body }, enabled());
      done.push(await response.json() as { partNumber: number; etag: string });
    }
    return { uploadId, done };
  }

  it("assembles the parts into one object", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/BIG1/1/${ULID_A}`;
    // R2 requires every part but the last to be at least 5 MiB.
    const first = "a".repeat(5 * 1024 * 1024);
    const { uploadId, done } = await upload(auth, path, [first, "tail"]);

    const completed = await call(`${path}?uploadId=${uploadId}&complete`, {
      method: "POST", headers: { ...auth, "content-type": "application/json" },
      body: JSON.stringify({ parts: done }),
    }, enabled());
    expect(completed.status).toBe(200);

    const get = await call(path, { headers: auth }, enabled());
    const text = await get.text();
    expect(text.length).toBe(first.length + 4);
    expect(text.endsWith("tail")).toBe(true);
  });

  it("leaves no object behind when the upload is never completed", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/BIG2/1/${ULID_A}`;
    await upload(auth, path, ["only one"]);

    expect(await env.BUCKET.head(`lib/darrin/blob/BIG2/1/${ULID_A}`)).toBeNull();
  });

  it("charges parts as they arrive", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/BIG3/1/${ULID_A}`;
    await upload(auth, path, ["abcde"]);

    const usage = await call("/api/library/usage", { headers: auth }, enabled());
    expect((await usage.json() as { storedBytes: number }).storedBytes).toBe(5);
  });

  // The counter and R2 must agree after each of these, which is what `?reconcile=1` checks.
  // Stage 4 found a 2.27 GB recording's 70 parts counted as 70 objects, and two app restarts
  // mid-upload leaving 946 MB charged that R2 did not hold.
  async function counterAgreesWithR2(auth: Record<string, string>) {
    const counter = await (await call("/api/library/usage", { headers: auth }, enabled())).json();
    const actual = await (await call("/api/library/usage?reconcile=1",
                                     { headers: auth }, enabled())).json();
    expect(counter).toEqual(actual);
    return actual as { storedBytes: number; storedObjects: number };
  }

  async function complete(auth: Record<string, string>, path: string, uploadId: string,
                          parts: { partNumber: number; etag: string }[]) {
    const response = await call(`${path}?uploadId=${uploadId}&complete`, {
      method: "POST", headers: { ...auth, "content-type": "application/json" },
      body: JSON.stringify({ parts }),
    }, enabled());
    expect(response.status).toBe(200);
  }

  it("counts a completed upload as one object, however many parts it had", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/BIG5/1/${ULID_A}`;
    const part = "p".repeat(5 * 1024 * 1024);
    const { uploadId, done } = await upload(auth, path, [part, part, "end"]);
    await complete(auth, path, uploadId, done);

    const usage = await counterAgreesWithR2(auth);
    expect(usage.storedObjects).toBe(1);
    expect(usage.storedBytes).toBe(2 * part.length + 3);
  });

  it("credits the parts of an upload a restarted device abandoned", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/BIG6/1/${ULID_A}`;
    const part = "q".repeat(5 * 1024 * 1024);
    await upload(auth, path, [part]);                 // the app quits here
    const { uploadId, done } = await upload(auth, path, [part, "end"]);
    await complete(auth, path, uploadId, done);

    const usage = await counterAgreesWithR2(auth);
    expect(usage.storedBytes).toBe(part.length + 3);
  });

  it("charges a part sent twice once", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/BIG7/1/${ULID_A}`;
    const part = "r".repeat(5 * 1024 * 1024);
    const { uploadId } = await upload(auth, path, [part]);
    // The response to part 1 was lost, so the device sends it again.
    const again = await call(`${path}?uploadId=${uploadId}&part=1`,
                             { method: "PUT", headers: auth, body: part }, enabled());
    const first = await again.json() as { partNumber: number; etag: string };
    const last = await call(`${path}?uploadId=${uploadId}&part=2`,
                            { method: "PUT", headers: auth, body: "end" }, enabled());
    await complete(auth, path, uploadId,
                   [first, await last.json() as { partNumber: number; etag: string }]);

    await counterAgreesWithR2(auth);
  });

  it("reports an object that already exists instead of starting a second upload", async () => {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    const path = `/api/library/blob/blob/BIG4/1/${ULID_A}`;
    await call(path, { method: "PUT", headers: auth, body: "done earlier" }, enabled());

    const started = await call(`${path}?uploads`, { method: "POST", headers: auth }, enabled());
    expect((await started.json() as { exists: boolean }).exists).toBe(true);
  });
});

describe("F128 — a fork's bytes outlive the capture it forked from", () => {
  // A fork keeps its bytes under the capture it forked from. The delete of that capture
  // removed its whole prefix, the fork's content included, and every later push of the fork
  // was refused as missing-blob.
  let seq = 0;
  function op(blindedID: string, kind: string, requires: object[] = [], observed = 0) {
    seq += 1;
    return { opID: `01JBQP${String(seq).padStart(20, "0")}`, blindedID, v: 1, kind,
             requires, observed, ciphertext: btoa(`${kind}-${blindedID}`) };
  }
  async function push(auth: Record<string, string>, ops: object[]) {
    const response = await call("/api/library/ops", {
      method: "POST", headers: { ...auth, "content-type": "application/json" },
      body: JSON.stringify({ ops }),
    }, enabled());
    return await response.json() as { assigned: unknown[]; head: number; released?: unknown };
  }
  /** The GET's status, with its body read so no R2 object is left open at teardown. */
  async function statusOf(path: string, auth: Record<string, string>) {
    const response = await call(path, { headers: auth }, enabled());
    await response.arrayBuffer();
    return response.status;
  }
  const original = { purpose: "blob", revision: 1, writer: ULID_A, capture: "PARENT1" };
  const parentPath = `/api/library/blob/blob/PARENT1/1/${ULID_A}`;

  async function forkOfADeletedParent() {
    const token = await device();
    const auth = { authorization: `Bearer ${token}` };
    await call(parentPath, { method: "PUT", headers: auth, body: "edit" }, enabled());
    await push(auth, [op("PARENT1", "upsert", [original])]);
    await push(auth, [op("FORK1", "upsert", [original])]);   // the fork names PARENT1's bytes
    const trashed = await push(auth, [op("PARENT1", "trash", [original])]);
    const deleted = await push(auth, [op("PARENT1", "delete", [], trashed.head)]);
    return { auth, deleted };
  }

  it("leaves the bytes a fork uses when its parent is deleted", async () => {
    const { auth, deleted } = await forkOfADeletedParent();
    expect(deleted.assigned).toHaveLength(1);
    expect(deleted.released).toBeUndefined();                // never sent to a client
    expect(await statusOf(parentPath, auth)).toBe(200);
    const again = await push(auth, [op("FORK1", "upsert", [original])]);
    expect(again.assigned).toHaveLength(1);                  // not missing-blob
  });

  it("deletes them, and returns the space, when the fork is deleted too", async () => {
    const { auth } = await forkOfADeletedParent();
    const trashed = await push(auth, [op("FORK1", "trash", [original])]);
    await push(auth, [op("FORK1", "delete", [], trashed.head)]);

    expect(await statusOf(parentPath, auth)).toBe(404);
    const usage = await (await call("/api/library/usage", { headers: auth }, enabled())).json();
    expect(usage).toEqual({ storedBytes: 0, storedObjects: 0 });
  });

  it("deletes them when the fork is edited and no longer uses them", async () => {
    const { auth } = await forkOfADeletedParent();
    const own = { purpose: "blob", revision: 2, writer: ULID_A, capture: "FORK1" };
    await call(`/api/library/blob/blob/FORK1/2/${ULID_A}`,
               { method: "PUT", headers: auth, body: "fork edit" }, enabled());
    await push(auth, [op("FORK1", "upsert", [own])]);

    expect(await statusOf(parentPath, auth)).toBe(404);
    const usage = await (await call("/api/library/usage", { headers: auth }, enabled())).json();
    expect(usage).toEqual({ storedBytes: "fork edit".length, storedObjects: 1 });
  });
});
