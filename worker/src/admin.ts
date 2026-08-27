// The admin dashboard: mint and revoke share tokens, see who is using what, delete shares.
//
// Two deliberate constraints.
//
// It runs without a line of JavaScript — plain forms, POST, and 303 redirects — so the same
// `script-src 'none'` that protects the viewer protects the page that can hand out credentials.
// Nothing on this page can be scripted, injected into, or read by an extension.
//
// And the owner table lives in KV rather than in the TOKENS secret, because a Worker cannot
// write its own secrets: a dashboard that could not mint a token would not be worth having.
import {
  Env, OwnerTable, SECURITY_HEADERS, THEME_CSS, escapeHTML, formatBytes, loadOwners,
  newToken, notFound, ownerForToken, saveOwners, sha256Hex, validOwnerName,
} from "./common";
import { accessTokenFrom, issuerFor, kidOf, loadJWKS, verifyAccessToken } from "./access";

const COOKIE = "kapture_admin";
const SESSION_SECONDS = 12 * 60 * 60;

const ADMIN_CSP =
  "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; " +
  "form-action 'self'; base-uri 'none'; frame-ancestors 'none'; script-src 'none'";

function page(title: string, body: string, status = 200, extraHeaders: HeadersInit = {}): Response {
  return new Response(
    `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHTML(title)}</title>
<style>${THEME_CSS}
main { max-width: 900px; margin: 0 auto; padding: 32px 20px 64px; }
h1 { font-size: 1.6rem; margin: 0 0 4px; }
h2 { font-size: 1rem; margin: 32px 0 8px; color: var(--muted); font-weight: 600;
  text-transform: uppercase; letter-spacing: .04em; }
p.sub { color: var(--muted); margin: 0; }
.header { display: flex; align-items: flex-start; justify-content: space-between;
  gap: 16px; margin-bottom: 8px; }
table { width: 100%; border-collapse: collapse; background: var(--card);
  border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid var(--line); }
th { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }
tr:last-child td { border-bottom: none; }
td.num { text-align: right; font-variant-numeric: tabular-nums; }
form.inline { display: inline; }
button { font: inherit; padding: 5px 11px; border-radius: 7px; border: 1px solid var(--line);
  background: var(--card); color: var(--fg); cursor: pointer; }
button.danger { color: var(--accent); border-color: color-mix(in srgb, var(--accent) 40%, var(--line)); }
button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
input { font: inherit; padding: 7px 10px; border-radius: 7px; border: 1px solid var(--line);
  background: var(--bg); color: var(--fg); min-width: 200px; }
.row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-top: 12px; }
.token { background: var(--card); border: 1px solid var(--accent); border-radius: 10px;
  padding: 16px; margin: 16px 0; }
.token code { display: block; margin-top: 8px; padding: 10px; background: var(--bg);
  border-radius: 7px; font-size: 15px; word-break: break-all; user-select: all; }
.muted { color: var(--muted); }
a { color: inherit; }
</style>
</head><body><main>${body}</main></body></html>`,
    { status, headers: { "content-type": "text/html; charset=utf-8",
                         "content-security-policy": ADMIN_CSP,
                         "cache-control": "no-store",
                         ...SECURITY_HEADERS, ...extraHeaders } },
  );
}

function loginPage(message?: string): Response {
  return page("Kapture admin", `
    <h1>Kapture admin</h1>
    <p class="sub">Sign in with your share token.</p>
    ${message ? `<p class="sub" style="color:var(--accent)">${escapeHTML(message)}</p>` : ""}
    <form method="POST" action="/admin/login">
      <div class="row">
        <input type="password" name="token" placeholder="share token" autocomplete="off" autofocus>
        <button class="primary" type="submit">Sign in</button>
      </div>
    </form>`, message ? 401 : 200);
}

function cookieToken(request: Request): string {
  const raw = request.headers.get("cookie") ?? "";
  for (const part of raw.split(";")) {
    const [name, ...rest] = part.trim().split("=");
    if (name === COOKIE) return decodeURIComponent(rest.join("="));
  }
  return "";
}

/** True when this deployment is behind Cloudflare Access. */
function accessConfigured(env: Env): boolean {
  return Boolean(env.ACCESS_TEAM_DOMAIN && env.ACCESS_AUD);
}

/**
 * Who is asking, or null.
 *
 * With Access configured, identity comes from the verified Access JWT and nothing else — the
 * share token stops being an admin credential, which is the point of moving to Access: pasting
 * your token into another Mac no longer hands over the dashboard.
 *
 * Without it, the admin signs in with their share token as before.
 */
async function adminIdentity(request: Request, env: Env): Promise<string | null> {
  if (accessConfigured(env)) {
    const token = accessTokenFrom(request);
    if (!token) return null;
    let jwks = await loadJWKS(env.ACCESS_TEAM_DOMAIN!, env.QUOTAS);
    // A key id the cache has never heard of is what a rotation looks like from here, so fetch
    // once past the cache rather than turning the admin away for the rest of the hour.
    const kid = kidOf(token);
    if (jwks && kid && !jwks.keys.some((candidate) => candidate.kid === kid)) {
      jwks = (await loadJWKS(env.ACCESS_TEAM_DOMAIN!, env.QUOTAS, true)) ?? jwks;
    }
    if (!jwks) return null;
    const identity = await verifyAccessToken(token, jwks, {
      audience: env.ACCESS_AUD!,
      issuer: issuerFor(env.ACCESS_TEAM_DOMAIN!),
    });
    if (!identity) return null;
    if (env.ADMIN_EMAIL && identity.email.toLowerCase() !== env.ADMIN_EMAIL.toLowerCase()) {
      return null;
    }
    return identity.email;
  }
  const header = request.headers.get("authorization") ?? "";
  const bearer = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  const owner = await ownerForToken(bearer || cookieToken(request), env);
  return owner && owner === env.ADMIN_OWNER ? owner : null;
}

/**
 * A cross-site POST cannot carry the cookie (SameSite=Strict), but checking the origin as well
 * costs one line and closes the gap if that ever loosens.
 */
function sameOrigin(request: Request, url: URL): boolean {
  const origin = request.headers.get("origin");
  return !origin || origin === url.origin;
}

function redirect(to: string, extraHeaders: HeadersInit = {}): Response {
  return new Response(null, {
    status: 303,
    headers: { location: to, "cache-control": "no-store", ...SECURITY_HEADERS, ...extraHeaders },
  });
}

interface ShareRow {
  id: string;
  owner: string;
  filename: string;
  bytes: number;
  uploadedAt: string;
}

/** Every share in the bucket. Admin-only and occasional, so a full paged scan is fine here. */
async function allShares(env: Env): Promise<ShareRow[]> {
  const rows: ShareRow[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < 20; page++) {
    const listed = await env.BUCKET.list({
      prefix: "shares/", limit: 1000, cursor, include: ["customMetadata"],
    });
    for (const object of listed.objects) {
      rows.push({
        id: object.key.slice("shares/".length),
        owner: object.customMetadata?.owner ?? "—",
        filename: object.customMetadata?.filename ?? "",
        bytes: object.size,
        uploadedAt: object.customMetadata?.uploadedAt ?? object.uploaded.toISOString(),
      });
    }
    if (!listed.truncated) break;
    cursor = listed.cursor;
  }
  return rows.sort((a, b) => (a.uploadedAt < b.uploadedAt ? 1 : -1));
}

async function usageToday(env: Env, owner: string): Promise<{ bytes: number; objects: number }> {
  const day = new Date().toISOString().slice(0, 10);
  const used = (await env.QUOTAS.get(`quota:${owner}:${day}`, "json")) as
    { bytes: number; objects: number } | null;
  return { bytes: Number(used?.bytes) || 0, objects: Number(used?.objects) || 0 };
}

interface DashboardView {
  /** Shown once, immediately after minting. */
  minted?: { owner: string; token: string };
  /** The Access identity, when Access is what let them in. */
  signedInAs?: string;
  /** Why the last action did nothing. Silence on a page that hands out credentials is worse. */
  notice?: string;
  /**
   * The table just written, rather than one read back. KV is only eventually consistent, so a
   * read straight after a put can still answer with the old value — and a page that shows a
   * freshly minted token above a list that does not contain its owner reads as a failure.
   */
  owners?: OwnerTable;
}

async function dashboard(env: Env, view: DashboardView = {}): Promise<Response> {
  const { minted, signedInAs, notice } = view;
  const owners = view.owners ?? await loadOwners(env);
  const shares = await allShares(env);
  const perOwner = new Map<string, { count: number; bytes: number }>();
  for (const share of shares) {
    const entry = perOwner.get(share.owner) ?? { count: 0, bytes: 0 };
    entry.count += 1;
    entry.bytes += share.bytes;
    perOwner.set(share.owner, entry);
  }

  const rows = await Promise.all(Object.entries(owners).map(async ([name, record]) => {
    const used = await usageToday(env, name);
    const stored = perOwner.get(name) ?? { count: 0, bytes: 0 };
    const isAdmin = name === env.ADMIN_OWNER;
    return `<tr>
      <td>${escapeHTML(name)}${isAdmin ? ' <span class="muted">· admin</span>' : ""}</td>
      <td class="muted">${escapeHTML(record.createdAt ? record.createdAt.slice(0, 10) : "—")}</td>
      <td class="num">${stored.count}</td>
      <td class="num">${formatBytes(stored.bytes)}</td>
      <td class="num muted">${used.objects} / ${formatBytes(used.bytes)}</td>
      <td>${isAdmin ? '<span class="muted">—</span>' : `
        <form class="inline" method="POST" action="/admin/revoke">
          <input type="hidden" name="owner" value="${escapeHTML(name)}">
          <button class="danger" type="submit">Revoke</button>
        </form>`}</td>
    </tr>`;
  }));

  const shareRows = shares.slice(0, 200).map((share) => `<tr>
      <td><a href="/${escapeHTML(share.id)}">${escapeHTML(share.id)}</a></td>
      <td>${escapeHTML(share.owner)}</td>
      <td class="muted">${escapeHTML(share.filename)}</td>
      <td class="num">${formatBytes(share.bytes)}</td>
      <td class="muted">${escapeHTML(share.uploadedAt.slice(0, 16).replace("T", " "))}</td>
      <td>
        <form class="inline" method="POST" action="/admin/delete-share">
          <input type="hidden" name="id" value="${escapeHTML(share.id)}">
          <button class="danger" type="submit">Delete</button>
        </form>
      </td>
    </tr>`).join("");

  const total = shares.reduce((sum, s) => sum + s.bytes, 0);

  return page("Kapture admin", `
    <div class="header">
      <div>
        <h1>Kapture admin</h1>
        <p class="sub">${shares.length} share${shares.length === 1 ? "" : "s"} ·
          ${formatBytes(total)} stored</p>
      </div>
      ${accessConfigured(env)
        ? `<p class="sub">${escapeHTML(signedInAs ?? "")}</p>`
        : `<form method="POST" action="/admin/logout">
        <button type="submit">Sign out</button>
      </form>`}
    </div>

    ${notice ? `<p class="sub" style="color:var(--accent);margin-top:16px">${escapeHTML(notice)}</p>` : ""}

    ${minted ? `<div class="token">
      <strong>Token for ${escapeHTML(minted.owner)}</strong>
      <p class="muted" style="margin:6px 0 0">Copy it now — it is not stored and cannot be shown again.
      They paste it into Kapture: Settings › Sharing.</p>
      <code>${escapeHTML(minted.token)}</code>
    </div>` : ""}

    <h2>People</h2>
    <table>
      <tr><th>Owner</th><th>Added</th><th>Shares</th><th>Stored</th><th>Today</th><th></th></tr>
      ${rows.join("")}
    </table>
    <form method="POST" action="/admin/mint">
      <div class="row">
        <input name="owner" placeholder="new person's name" autocomplete="off">
        <button class="primary" type="submit">Mint a token</button>
      </div>
    </form>

    <h2>Shares</h2>
    ${shares.length === 0
      ? '<p class="muted">Nothing shared yet.</p>'
      : `<table>
      <tr><th>Link</th><th>Owner</th><th>File</th><th>Size</th><th>Uploaded</th><th></th></tr>
      ${shareRows}
    </table>${shares.length > 200 ? '<p class="muted">Showing the 200 most recent.</p>' : ""}`}
  `);
}

/** Handles anything under /admin. Returns null when the path isn't ours. */
export async function handleAdmin(request: Request, env: Env, url: URL): Promise<Response | null> {
  const path = url.pathname;
  if (path !== "/admin" && !path.startsWith("/admin/")) return null;

  // Before any POST is acted on, including sign-in and sign-out: those two change who the
  // browser is, which is exactly what a cross-site form is for.
  if (request.method === "POST" && !sameOrigin(request, url)) {
    return new Response("Cross-origin form post refused", { status: 403, headers: SECURITY_HEADERS });
  }

  // With Access in front, its own sign-in page is the only one; ours would be a second,
  // weaker door into the same room.
  if (accessConfigured(env) && (path === "/admin/login" || path === "/admin/logout")) {
    return redirect("/admin");
  }

  if (path === "/admin/login" && request.method === "POST") {
    const form = await request.formData();
    const token = String(form.get("token") ?? "");
    const owner = await ownerForToken(token, env);
    if (!owner || owner !== env.ADMIN_OWNER) return loginPage("That token is not the admin's.");
    return redirect("/admin", {
      "set-cookie": `${COOKIE}=${encodeURIComponent(token)}; Path=/admin; Max-Age=${SESSION_SECONDS}; ` +
        "HttpOnly; Secure; SameSite=Strict",
    });
  }

  if (path === "/admin/logout" && request.method === "POST") {
    return redirect("/admin", {
      "set-cookie": `${COOKIE}=; Path=/admin; Max-Age=0; HttpOnly; Secure; SameSite=Strict`,
    });
  }

  const admin = await adminIdentity(request, env);
  if (!admin) {
    if (accessConfigured(env)) {
      // Access should have stopped this request at the edge; reaching here means the app is
      // misconfigured or someone found a way around it. Say nothing useful.
      return new Response("Forbidden", { status: 403, headers: SECURITY_HEADERS });
    }
    return path === "/admin" ? loginPage() : loginPage("Sign in first.");
  }

  if (path === "/admin" && request.method === "GET") return dashboard(env, { signedInAs: admin });

  if (path === "/admin/mint" && request.method === "POST") {
    const form = await request.formData();
    const owner = String(form.get("owner") ?? "").trim();
    // Both refusals say so. A form that reloads unchanged is indistinguishable from one that
    // worked, and the thing it hands out is a credential.
    if (!validOwnerName(owner)) {
      return dashboard(env, { signedInAs: admin, notice: "A name is letters and digits, then " +
        "letters, digits, - or _ — up to 32 characters, no spaces." });
    }
    const owners: OwnerTable = await loadOwners(env);
    if (owners[owner]) {   // never re-mint silently
      return dashboard(env, { signedInAs: admin, owners,
        notice: `${owner} already has a token. Revoke it first if they need a new one.` });
    }
    const token = newToken();
    owners[owner] = { hash: await sha256Hex(token), createdAt: new Date().toISOString() };
    await saveOwners(env, owners);
    return dashboard(env, { minted: { owner, token }, signedInAs: admin, owners });
  }

  if (path === "/admin/revoke" && request.method === "POST") {
    const form = await request.formData();
    const owner = String(form.get("owner") ?? "");
    const owners = await loadOwners(env);
    // the admin cannot revoke themselves out of the dashboard
    if (owners[owner] && owner !== env.ADMIN_OWNER) {
      delete owners[owner];
      await saveOwners(env, owners);
    }
    return redirect("/admin");
  }

  if (path === "/admin/delete-share" && request.method === "POST") {
    const form = await request.formData();
    const id = String(form.get("id") ?? "");
    if (/^[A-Za-z0-9]{4,16}$/.test(id)) await env.BUCKET.delete(`shares/${id}`);
    return redirect("/admin");
  }

  return notFound();
}
