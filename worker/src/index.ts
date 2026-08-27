// kapture.sh — share links for Kapture captures.
//
// Design constraints from the spec's security review (§9):
//  · tokens are stored HASHED and compared in constant time; the header is never logged
//  · x-filename is sanitized on the way in AND escaped at every render site (it reaches HTML,
//    OG tags and Content-Disposition — the injection path a reviewer found in the first draft)
//  · the viewer is server-rendered with no JS and a deny-everything CSP; the raw endpoint is
//    nosniff + sandboxed, and only an allowlist of media types can be stored at all
//  · per-token daily quotas, because a leaked token is otherwise an unbounded R2 bill
//  · links are permanent: there is no expiry, and deletion is an explicit owner action

export interface Env {
  BUCKET: R2Bucket;
  QUOTAS: KVNamespace;
  /** JSON: { "<owner>": "<sha256 hex of token>" } */
  TOKENS: string;
  /** owner allowed to delete anything */
  ADMIN_OWNER: string;
  /** GitHub releases base for /download and /appcast.xml */
  RELEASES_BASE: string;
}

const MAX_SINGLE_UPLOAD = 95 * 1024 * 1024; // Workers' request body ceiling is 100MB
const DAILY_BYTES_PER_OWNER = 2 * 1024 * 1024 * 1024;
const DAILY_OBJECTS_PER_OWNER = 500;

const ALLOWED_TYPES = new Map([
  ["image/png", "png"],
  ["image/jpeg", "jpg"],
  ["image/webp", "webp"],
  ["image/gif", "gif"],
  ["video/mp4", "mp4"],
  ["video/quicktime", "mov"],
]);

const ID_ALPHABET = "123456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ"; // base58

function newID(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => ID_ALPHABET[b % ID_ALPHABET.length]).join("");
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Constant-time compare over equal-length hex digests. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Bearer token → owner name, or null. Never logs the token. */
async function authorize(request: Request, env: Env): Promise<string | null> {
  const header = request.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!token) return null;
  let table: Record<string, string>;
  try {
    table = JSON.parse(env.TOKENS);
  } catch {
    return null;
  }
  const presented = await sha256Hex(token);
  for (const [owner, hash] of Object.entries(table)) {
    if (timingSafeEqual(presented, hash)) return owner;
  }
  return null;
}

/**
 * Filenames are attacker-controlled: keep a conservative charset and a sane length.
 * An allowlist, not a denylist: the denylist this replaced carried literal control bytes
 * in the source (which made the whole file read as binary to grep) and still had to
 * enumerate every dangerous character. Letters, digits, space and . _ ( ) - survive.
 */
function sanitizeFilename(raw: string | null, fallbackExt: string): string {
  const cleaned = (raw ?? "")
    .normalize("NFC")
    .replace(/[^A-Za-z0-9 ._()-]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 128);
  return cleaned || `capture.${fallbackExt}`;
}

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!,
  );
}

const SECURITY_HEADERS: Record<string, string> = {
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
};

const VIEWER_CSP =
  "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; " +
  "script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

function viewerHTML(id: string, filename: string, contentType: string, origin: string): string {
  const safeName = escapeHTML(filename);
  const url = `${origin}/${id}/raw`;
  const media = contentType.startsWith("video/")
    ? `<video src="${url}" controls playsinline preload="metadata"></video>`
    : `<img src="${url}" alt="${safeName}">`;
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${safeName}</title>
<meta property="og:title" content="${safeName}">
<meta property="og:type" content="${contentType.startsWith("video/") ? "video.other" : "image"}">
<meta property="og:image" content="${url}">
<meta name="twitter:card" content="summary_large_image">
<style>
:root { color-scheme: light dark; --bg:#f6f7f9; --fg:#191c21; --muted:#79818b; --line:#dbdee3; }
@media (prefers-color-scheme: dark) { :root { --bg:#15171b; --fg:#e9eaec; --muted:#7c838c; --line:#2c3036; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg); min-height:100vh; display:flex;
  flex-direction:column; font:15px/1.5 -apple-system, "Segoe UI", sans-serif; }
main { flex:1; display:grid; place-items:center; padding:24px; }
img, video { max-width:100%; max-height:82vh; border-radius:10px;
  box-shadow:0 12px 40px rgba(0,0,0,.18); background:#000; }
footer { display:flex; gap:16px; align-items:center; justify-content:space-between;
  padding:12px 20px; border-top:1px solid var(--line); font-size:13px; }
.name { color:var(--muted); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
a { color:inherit; }
</style>
</head><body>
<main>${media}</main>
<footer><span class="name">${safeName}</span><a href="${url}" download="${safeName}">Download</a></footer>
</body></html>`;
}

/** Per-owner daily counters. A leaked token can cost a day's quota, not the account. */
async function checkQuota(env: Env, owner: string, bytes: number): Promise<string | null> {
  const day = new Date().toISOString().slice(0, 10);
  const key = `quota:${owner}:${day}`;
  const current = (await env.QUOTAS.get(key, "json")) as { bytes: number; objects: number } | null;
  const used = current ?? { bytes: 0, objects: 0 };
  if (used.bytes + bytes > DAILY_BYTES_PER_OWNER) return "daily byte quota reached";
  if (used.objects + 1 > DAILY_OBJECTS_PER_OWNER) return "daily object quota reached";
  await env.QUOTAS.put(
    key,
    JSON.stringify({ bytes: used.bytes + bytes, objects: used.objects + 1 }),
    { expirationTtl: 60 * 60 * 30 },
  );
  return null;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...SECURITY_HEADERS },
  });
}

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const origin = url.origin;

    // ---- upload -----------------------------------------------------------
    if (path === "/api/upload" && request.method === "POST") {
      const owner = await authorize(request, env);
      if (!owner) return json({ error: "unauthorized" }, 401);

      const contentType = (request.headers.get("content-type") ?? "").split(";")[0].trim();
      const ext = ALLOWED_TYPES.get(contentType);
      if (!ext) return json({ error: `unsupported content-type: ${contentType}` }, 415);

      const declared = Number(request.headers.get("content-length") ?? "0");
      if (declared > MAX_SINGLE_UPLOAD) {
        return json({ error: "too large for a single upload", maxBytes: MAX_SINGLE_UPLOAD }, 413);
      }
      const quotaError = await checkQuota(env, owner, declared);
      if (quotaError) return json({ error: quotaError }, 429);

      const filename = sanitizeFilename(request.headers.get("x-filename"), ext);
      const body = await request.arrayBuffer();
      if (body.byteLength > MAX_SINGLE_UPLOAD) {
        return json({ error: "too large for a single upload" }, 413);
      }

      // create-only put; regenerate on the (vanishingly unlikely) collision
      let id = newID();
      for (let attempt = 0; attempt < 4; attempt++) {
        const existing = await env.BUCKET.head(`shares/${id}`);
        if (!existing) break;
        id = newID();
      }
      await env.BUCKET.put(`shares/${id}`, body, {
        httpMetadata: { contentType },
        customMetadata: { owner, filename, uploadedAt: new Date().toISOString() },
      });
      return json({ id, url: `${origin}/${id}` });
    }

    // ---- list (own uploads only; owner comes from the token, never a param) ----
    if (path === "/api/list" && request.method === "GET") {
      const owner = await authorize(request, env);
      if (!owner) return json({ error: "unauthorized" }, 401);
      // customMetadata is omitted from list results unless asked for — without this the
      // owner filter below sees undefined for every object and nobody lists anything
      const listed = await env.BUCKET.list({
        prefix: "shares/",
        limit: 1000,
        include: ["customMetadata"],
      });
      const mine = listed.objects
        .filter((o) => o.customMetadata?.owner === owner)
        .map((o) => ({
          id: o.key.slice("shares/".length),
          filename: o.customMetadata?.filename ?? "",
          bytes: o.size,
          uploadedAt: o.customMetadata?.uploadedAt ?? o.uploaded.toISOString(),
        }));
      return json({ items: mine });
    }

    // ---- delete (owner or admin) -----------------------------------------
    const deleteMatch = path.match(/^\/api\/([A-Za-z0-9]{4,16})$/);
    if (deleteMatch && request.method === "DELETE") {
      const owner = await authorize(request, env);
      if (!owner) return json({ error: "unauthorized" }, 401);
      const key = `shares/${deleteMatch[1]}`;
      const head = await env.BUCKET.head(key);
      if (!head) return json({ error: "not found" }, 404);
      if (head.customMetadata?.owner !== owner && owner !== env.ADMIN_OWNER) {
        return json({ error: "not yours" }, 403);
      }
      await env.BUCKET.delete(key);
      return new Response(null, { status: 204, headers: SECURITY_HEADERS });
    }

    // ---- updates: redirect, never proxy (integrity stays with GitHub) -----
    if (path === "/download") {
      return Response.redirect(`${env.RELEASES_BASE}/latest/download/Kapture.dmg`, 302);
    }
    if (path === "/appcast.xml") {
      const upstream = await fetch(`${env.RELEASES_BASE}/latest/download/appcast.xml`);
      return new Response(upstream.body, {
        status: upstream.status,
        headers: { "content-type": "application/xml", ...SECURITY_HEADERS },
      });
    }

    // ---- raw asset --------------------------------------------------------
    const rawMatch = path.match(/^\/([A-Za-z0-9]{4,16})\/raw$/);
    if (rawMatch && (request.method === "GET" || request.method === "HEAD")) {
      const object = await env.BUCKET.get(`shares/${rawMatch[1]}`);
      if (!object) return new Response("Not found", { status: 404, headers: SECURITY_HEADERS });
      const filename = object.customMetadata?.filename ?? "capture";
      return new Response(object.body, {
        headers: {
          "content-type": object.httpMetadata?.contentType ?? "application/octet-stream",
          "content-disposition": `inline; filename*=UTF-8''${encodeURIComponent(filename)}`,
          "cache-control": "public, max-age=31536000, immutable",
          "content-security-policy": "default-src 'none'; sandbox",
          ...SECURITY_HEADERS,
        },
      });
    }

    // ---- viewer -----------------------------------------------------------
    const viewMatch = path.match(/^\/([A-Za-z0-9]{4,16})$/);
    if (viewMatch && request.method === "GET") {
      const head = await env.BUCKET.head(`shares/${viewMatch[1]}`);
      if (!head) return new Response("Not found", { status: 404, headers: SECURITY_HEADERS });
      const html = viewerHTML(
        viewMatch[1],
        head.customMetadata?.filename ?? "capture",
        head.httpMetadata?.contentType ?? "application/octet-stream",
        origin,
      );
      return new Response(html, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "content-security-policy": VIEWER_CSP,
          "cache-control": "public, max-age=300",
          ...SECURITY_HEADERS,
        },
      });
    }

    // ---- landing ----------------------------------------------------------
    if (path === "/") {
      return new Response(LANDING, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "content-security-policy": VIEWER_CSP,
          ...SECURITY_HEADERS,
        },
      });
    }

    return new Response("Not found", { status: 404, headers: SECURITY_HEADERS });
  },
} satisfies ExportedHandler<Env>;

const LANDING = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Kapture</title>
<style>
:root { color-scheme: light dark; --bg:#f6f7f9; --fg:#191c21; --muted:#79818b; --accent:#c7423a; }
@media (prefers-color-scheme: dark) { :root { --bg:#15171b; --fg:#e9eaec; --muted:#7c838c; --accent:#e2756d; } }
body { margin:0; min-height:100vh; display:grid; place-items:center; background:var(--bg); color:var(--fg);
  font:16px/1.6 -apple-system, "Segoe UI", sans-serif; text-align:center; padding:24px; }
h1 { font-size:2.6rem; margin:0 0 .3em; letter-spacing:-.02em; }
h1 span { color:var(--accent); }
p { color:var(--muted); max-width:34ch; margin:0 auto 1.6em; }
a.btn { display:inline-block; background:var(--accent); color:#fff; text-decoration:none;
  padding:.7em 1.5em; border-radius:10px; font-weight:600; }
</style></head>
<body><div>
<h1>Kapture<span>.</span></h1>
<p>Screenshots, recordings, and a library that remembers everything — all on your Mac.</p>
<a class="btn" href="/download">Download for macOS</a>
</div></body></html>`;
