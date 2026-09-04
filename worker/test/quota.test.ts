import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { DAILY_BYTES_PER_OWNER, quotaFor } from "../src/quota";
import worker from "../src/index";
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";

const day = () => new Date().toISOString().slice(0, 10);

describe("transactional quotas", () => {
  it("reserves the final object slot exactly once across concurrent upload requests", async () => {
    await env.QUOTAS.put(`quota:darrin:${day()}`, JSON.stringify({ bytes: 0, objects: 499 }));
    const statuses = await Promise.all(Array.from({ length: 12 }, async () => {
      const ctx = createExecutionContext();
      const response = await worker.fetch(new Request("https://kapture.sh/api/upload", {
        method: "POST", headers: { authorization: "Bearer test-token", "content-type": "image/png" },
        body: new Uint8Array([1, 2, 3]),
      }), env, ctx);
      await waitOnExecutionContext(ctx);
      return response.status;
    }));
    expect(statuses.filter((status) => status === 200)).toHaveLength(1);
    expect(statuses.filter((status) => status === 429)).toHaveLength(11);
    expect(await quotaFor(env, "darrin").usage("darrin")).toEqual({ bytes: 3, objects: 500 });
    expect((await env.BUCKET.list({ prefix: "shares/" })).objects).toHaveLength(1);
  });

  it("cannot lose simultaneous byte charges", async () => {
    await env.QUOTAS.put(`quota:bytes:${day()}`, JSON.stringify({ bytes: DAILY_BYTES_PER_OWNER - 10, objects: 0 }));
    const stub = quotaFor(env, "bytes");
    const results = await Promise.all(Array.from({ length: 10 }, () => stub.charge("bytes", 6)));
    expect(results.filter((result) => result === null)).toHaveLength(1);
    expect(await stub.usage("bytes")).toEqual({ bytes: DAILY_BYTES_PER_OWNER - 4, objects: 1 });
  });

  it("isolates owners and resets the counter at the next UTC day", async () => {
    const stub = quotaFor(env, "yesterday");
    await runInDurableObject(stub, async (_instance, state) => {
      await state.storage.put("usage", { day: "2000-01-01", bytes: DAILY_BYTES_PER_OWNER, objects: 500 });
    });
    expect(await stub.charge("yesterday", 5)).toBeNull();
    expect(await stub.usage("yesterday")).toEqual({ bytes: 5, objects: 1 });
    expect(await quotaFor(env, "another").usage("another")).toEqual({ bytes: 0, objects: 0 });
  });

  it("persists accounting independently of stale legacy KV values", async () => {
    const stub = quotaFor(env, "migrated");
    await env.QUOTAS.put(`quota:migrated:${day()}`, JSON.stringify({ bytes: 10, objects: 1 }));
    expect(await stub.charge("migrated", 20)).toBeNull();
    await env.QUOTAS.put(`quota:migrated:${day()}`, JSON.stringify({ bytes: 0, objects: 0 }));
    expect(await stub.usage("migrated")).toEqual({ bytes: 30, objects: 2 });
  });
});
