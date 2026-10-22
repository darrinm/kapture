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
