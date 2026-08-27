// The dashboard hands out credentials, so its access rules get tested rather than eyeballed.
import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker from "../src/index";

const ADMIN = "test-token";          // sha256 is the `darrin` entry in vitest.config.ts
const COOKIE = "kapture_admin";

async function call(path: string, init: RequestInit = {}) {
  const request = new Request(`https://kapture.sh${path}`, init);
  const ctx = createExecutionContext();
  const response = await worker.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

const asAdmin = (extra: Record<string, string> = {}) => ({
  cookie: `${COOKIE}=${ADMIN}`,
  ...extra,
});

function form(fields: Record<string, string>): RequestInit {
  const body = new URLSearchParams(fields);
  return { method: "POST", body };
}

/** Mint a token through the dashboard and dig it back out of the rendered page. */
async function mint(owner: string): Promise<string> {
  const response = await call("/admin/mint", {
    ...form({ owner }),
    headers: asAdmin(),
  });
  const html = await response.text();
  const match = html.match(/<code>([A-Za-z0-9_-]{20,})<\/code>/);
  expect(match, "the minted token should be shown once").not.toBeNull();
  return match![1];
}

describe("admin access", () => {
  it("shows a sign-in form rather than the dashboard when signed out", async () => {
    const response = await call("/admin");
    const html = await response.text();
    expect(response.status).toBe(200);
    expect(html).toContain("Sign in");
    expect(html).not.toContain("Mint a token");
  });

  it("refuses a wrong token", async () => {
    const response = await call("/admin/login", form({ token: "not-the-token" }));
    expect(response.status).toBe(401);
    expect(response.headers.get("set-cookie")).toBeNull();
  });

  /// The whole point of owners: a friend's token uploads, and does nothing else.
  it("refuses a non-admin owner", async () => {
    const friend = await mint("friend2");
    const response = await call("/admin/login", form({ token: friend }));
    expect(response.status).toBe(401);
    const page = await call("/admin", { headers: { cookie: `${COOKIE}=${friend}` } });
    expect(await page.text()).not.toContain("Mint a token");
  });

  it("signs the admin in with a hardened cookie", async () => {
    const response = await call("/admin/login", form({ token: ADMIN }));
    expect(response.status).toBe(303);
    const cookie = response.headers.get("set-cookie") ?? "";
    expect(cookie).toContain("HttpOnly");
    expect(cookie).toContain("Secure");
    expect(cookie).toContain("SameSite=Strict");
    expect(cookie).toContain("Path=/admin");
  });

  it("serves the dashboard to a signed-in admin, with scripting still forbidden", async () => {
    const response = await call("/admin", { headers: asAdmin() });
    const html = await response.text();
    expect(html).toContain("Mint a token");
    expect(response.headers.get("content-security-policy")).toContain("script-src 'none'");
    expect(html).not.toContain("<script");
  });

  it("refuses a cross-origin form post", async () => {
    const response = await call("/admin/mint", {
      ...form({ owner: "evil" }),
      headers: asAdmin({ origin: "https://evil.example" }),
    });
    expect(response.status).toBe(403);
  });
});

describe("minting and revoking", () => {
  it("mints a token that actually works, then revokes it", async () => {
    const token = await mint("alex");

    const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);
    const upload = () => call("/api/upload", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "image/png" },
      body: png as BodyInit,
    });

    expect((await upload()).status).toBe(200);

    const revoked = await call("/admin/revoke", { ...form({ owner: "alex" }), headers: asAdmin() });
    expect(revoked.status).toBe(303);
    expect((await upload()).status).toBe(401);
  });

  it("will not silently replace an existing owner's token", async () => {
    const first = await mint("sam");
    const response = await call("/admin/mint", { ...form({ owner: "sam" }), headers: asAdmin() });
    const html = await response.text();
    expect(html).not.toContain("<code>");   // no new token issued

    // and the original still works
    const check = await call("/api/list", { headers: { authorization: `Bearer ${first}` } });
    expect(check.status).toBe(200);
  });

  it("rejects an owner name that isn't boring", async () => {
    for (const name of ["", "has space", "../etc", "a".repeat(40), "<script>"]) {
      const response = await call("/admin/mint", { ...form({ owner: name }), headers: asAdmin() });
      expect(await response.text()).not.toContain("<code>");
    }
  });

  /// Locking yourself out of your own dashboard should not be one click away.
  it("will not let the admin revoke themselves", async () => {
    await call("/admin/revoke", { ...form({ owner: "darrin" }), headers: asAdmin() });
    const page = await call("/admin", { headers: asAdmin() });
    expect(await page.text()).toContain("Mint a token");
  });
});

describe("share management", () => {
  it("deletes a share and the link stops resolving", async () => {
    const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 9, 9]);
    const uploaded = await call("/api/upload", {
      method: "POST",
      headers: { authorization: `Bearer ${ADMIN}`, "content-type": "image/png" },
      body: png as BodyInit,
    });
    const { id } = (await uploaded.json()) as { id: string };
    expect((await call(`/${id}`)).status).toBe(200);

    const deleted = await call("/admin/delete-share", { ...form({ id }), headers: asAdmin() });
    expect(deleted.status).toBe(303);
    expect((await call(`/${id}`)).status).toBe(404);
  });

  it("ignores a share id that isn't one", async () => {
    const response = await call("/admin/delete-share", {
      ...form({ id: "../../etc/passwd" }),
      headers: asAdmin(),
    });
    expect(response.status).toBe(303);   // handled, nothing deleted
  });
});
