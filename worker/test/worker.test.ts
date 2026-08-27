// The security-relevant behavior gets tests: auth, the filename injection path a reviewer
// found in the first draft, the type allowlist, owner scoping, quotas, and header posture.
import { env, createExecutionContext, waitOnExecutionContext, SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker from "../src/index";

const TOKEN = "test-token";
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);

async function upload(opts: {
  token?: string;
  type?: string;
  filename?: string;
  body?: Uint8Array;
} = {}) {
  const request = new Request("https://kapture.sh/api/upload", {
    method: "POST",
    headers: {
      authorization: `Bearer ${opts.token ?? TOKEN}`,
      "content-type": opts.type ?? "image/png",
      ...(opts.filename ? { "x-filename": opts.filename } : {}),
    },
    body: (opts.body ?? PNG) as BodyInit,
  });
  const ctx = createExecutionContext();
  const response = await worker.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

describe("auth", () => {
  it("rejects a missing or wrong token", async () => {
    expect((await upload({ token: "" })).status).toBe(401);
    expect((await upload({ token: "nope" })).status).toBe(401);
  });

  it("accepts a known token and returns an id and url", async () => {
    const response = await upload();
    expect(response.status).toBe(200);
    const body = (await response.json()) as { id: string; url: string };
    expect(body.id).toMatch(/^[A-Za-z0-9]{8}$/);
    expect(body.url).toBe(`https://kapture.sh/${body.id}`);
  });
});

describe("uploads", () => {
  it("refuses a type outside the allowlist", async () => {
    expect((await upload({ type: "text/html" })).status).toBe(415);
    expect((await upload({ type: "image/svg+xml" })).status).toBe(415);
  });

  it("gives each upload a distinct id", async () => {
    const a = (await (await upload()).json()) as { id: string };
    const b = (await (await upload()).json()) as { id: string };
    expect(a.id).not.toBe(b.id);
  });
});

describe("quotas", () => {
  /// content-length is attacker-controlled. Charging it instead of the bytes that arrive let a
  /// valid token upload the 95MB maximum per request while consuming none of the daily budget.
  it("charges the quota for the bytes that arrive, not the header", async () => {
    const payload = new Uint8Array(40_000);
    payload.set([0x89, 0x50, 0x4e, 0x47]);
    const request = new Request("https://kapture.sh/api/upload", {
      method: "POST",
      headers: {
        authorization: `Bearer ${TOKEN}`,
        "content-type": "image/png",
        "content-length": "0",   // the lie
      },
      body: payload as BodyInit,
    });
    const ctx = createExecutionContext();
    expect((await worker.fetch(request, env, ctx)).status).toBe(200);
    await waitOnExecutionContext(ctx);

    const day = new Date().toISOString().slice(0, 10);
    const quota = (await env.QUOTAS.get(`quota:darrin:${day}`, "json")) as
      { bytes: number; objects: number } | null;
    expect(quota).not.toBeNull();
    expect(quota!.bytes).toBeGreaterThanOrEqual(40_000);
  });

  it("ignores a poisoned counter rather than disabling the quota", async () => {
    const day = new Date().toISOString().slice(0, 10);
    await env.QUOTAS.put(`quota:darrin:${day}`, JSON.stringify({ bytes: null, objects: "lots" }));
    const response = await upload();
    expect(response.status).toBe(200);
    const quota = (await env.QUOTAS.get(`quota:darrin:${day}`, "json")) as
      { bytes: number; objects: number };
    expect(Number.isFinite(quota.bytes)).toBe(true);
    expect(Number.isFinite(quota.objects)).toBe(true);
  });
});

describe("viewer", () => {
  it("escapes a hostile filename everywhere it renders", async () => {
    const hostile = `"><meta http-equiv=refresh content=0;url=https://evil.example>`;
    const { id } = (await (await upload({ filename: hostile })).json()) as { id: string };
    const html = await (await SELF.fetch(`https://kapture.sh/${id}`)).text();
    // the injection must not survive as markup anywhere — title, og:title or the footer
    expect(html).not.toContain("<meta http-equiv=refresh");
    // whatever survives is inert text at every site the name reaches — title, og:title,
    // the img alt and the footer — none of them may carry an HTML metacharacter
    const sites = [
      html.match(/<title>([^<]*)<\/title>/)![1],
      html.match(/property="og:title" content="([^"]*)"/)![1],
      html.match(/alt="([^"]*)"/)![1],
      html.match(/<span class="name">([^<]*)<\/span>/)![1],
    ];
    for (const site of sites) expect(site).not.toMatch(/[<>"'&]/);
    // and an ordinary filename keeps its digits and extension intact
    const plain = (await (await upload({ filename: "capture 2026-08-26.png" })).json()) as { id: string };
    const plainHTML = await (await SELF.fetch(`https://kapture.sh/${plain.id}`)).text();
    expect(plainHTML).toContain("capture 2026-08-26.png");
  });

  it("sets a deny-everything CSP and nosniff", async () => {
    const { id } = (await (await upload()).json()) as { id: string };
    const response = await SELF.fetch(`https://kapture.sh/${id}`);
    const csp = response.headers.get("content-security-policy") ?? "";
    expect(csp).toContain("script-src 'none'");
    expect(csp).toContain("frame-ancestors 'none'");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
  });

  it("404s an unknown id", async () => {
    expect((await SELF.fetch("https://kapture.sh/abcd1234")).status).toBe(404);
  });
});

describe("raw asset", () => {
  it("serves the bytes sandboxed, immutable and nosniff", async () => {
    const { id } = (await (await upload()).json()) as { id: string };
    const response = await SELF.fetch(`https://kapture.sh/${id}/raw`);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("image/png");
    expect(response.headers.get("cache-control")).toContain("immutable");
    expect(response.headers.get("content-security-policy")).toContain("sandbox");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(PNG);
  });
});

describe("list and delete", () => {
  it("lists only the caller's own uploads", async () => {
    const mine = (await (await upload()).json()) as { id: string };
    const request = new Request("https://kapture.sh/api/list", {
      headers: { authorization: `Bearer ${TOKEN}` },
    });
    const ctx = createExecutionContext();
    const response = await worker.fetch(request, env, ctx);
    await waitOnExecutionContext(ctx);
    const body = (await response.json()) as { items: { id: string }[] };
    expect(body.items.some((i) => i.id === mine.id)).toBe(true);
    // the owner comes from the token; a query param must not widen it
    const spoof = await SELF.fetch("https://kapture.sh/api/list?owner=friend", {
      headers: { authorization: `Bearer ${TOKEN}` },
    });
    const spoofed = (await spoof.json()) as { items: unknown[] };
    expect(spoofed.items.length).toBe(body.items.length);
  });

  it("deletes an owned object and 404s afterwards", async () => {
    const { id } = (await (await upload()).json()) as { id: string };
    const del = await SELF.fetch(`https://kapture.sh/api/${id}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${TOKEN}` },
    });
    expect(del.status).toBe(204);
    expect((await SELF.fetch(`https://kapture.sh/${id}`)).status).toBe(404);
  });

  it("refuses an unauthenticated delete", async () => {
    const { id } = (await (await upload()).json()) as { id: string };
    expect((await SELF.fetch(`https://kapture.sh/api/${id}`, { method: "DELETE" })).status).toBe(401);
  });
});

describe("updates", () => {
  it("redirects /download to the immutable GitHub asset rather than proxying", async () => {
    const response = await SELF.fetch("https://kapture.sh/download", { redirect: "manual" });
    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toContain("github.com/darrinm/kapture/releases");
  });
});
