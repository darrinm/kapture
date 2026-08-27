// Pieces the public routes and the admin dashboard both need. Kept apart so neither file has to
// import the other, and so there is exactly one definition of how a token is checked.

export interface Env {
  BUCKET: R2Bucket;
  QUOTAS: KVNamespace;
  /**
   * Seed only: JSON of `{ "<owner>": "<sha256 hex of token>" }`.
   *
   * The live table lives in KV, because a Worker cannot write its own secrets and the admin
   * dashboard has to be able to mint and revoke. This value is read once, to populate KV on a
   * deployment that has never had an owner written, and ignored thereafter.
   */
  TOKENS: string;
  /** The one owner allowed to delete anyone's share and to use the dashboard. */
  ADMIN_OWNER: string;
  /** GitHub releases base for /download and /appcast.xml */
  RELEASES_BASE: string;
}

export interface Owner {
  /** sha256 hex of the bearer token. The token itself is shown once, at mint time, and never stored. */
  hash: string;
  createdAt: string;
  note?: string;
}

export type OwnerTable = Record<string, Owner>;

const OWNERS_KEY = "owners";

export const SECURITY_HEADERS: Record<string, string> = {
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
};

/** One palette for every page this Worker serves. */
export const THEME_CSS = `
:root { color-scheme: light dark; --bg:#f6f7f9; --fg:#191c21; --muted:#79818b;
  --line:#dbdee3; --accent:#c7423a; --card:#ffffff; }
@media (prefers-color-scheme: dark) { :root { --bg:#15171b; --fg:#e9eaec; --muted:#7c838c;
  --line:#2c3036; --accent:#e2756d; --card:#1c1f24; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg);
  font:15px/1.6 -apple-system, "Segoe UI", sans-serif; }
`;

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Constant-time compare over equal-length hex digests. */
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!,
  );
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...SECURITY_HEADERS },
  });
}

export function notFound(): Response {
  return new Response("Not found", { status: 404, headers: SECURITY_HEADERS });
}

/**
 * The owner table, from KV — falling back to the TOKENS secret on a deployment that has never
 * written one, so an existing install keeps working without a migration step.
 */
export async function loadOwners(env: Env): Promise<OwnerTable> {
  const stored = (await env.QUOTAS.get(OWNERS_KEY, "json")) as OwnerTable | null;
  if (stored && Object.keys(stored).length > 0) return stored;
  return seedFromSecret(env);
}

export async function saveOwners(env: Env, owners: OwnerTable): Promise<void> {
  await env.QUOTAS.put(OWNERS_KEY, JSON.stringify(owners));
}

/** The legacy secret, read as `{owner: hash}` and given the shape the table uses now. */
function seedFromSecret(env: Env): OwnerTable {
  let raw: Record<string, string>;
  try {
    raw = JSON.parse(env.TOKENS ?? "{}");
  } catch {
    return {};
  }
  const table: OwnerTable = {};
  for (const [owner, hash] of Object.entries(raw)) {
    if (typeof hash === "string" && hash.length === 64) {
      table[owner] = { hash, createdAt: "", note: "from the TOKENS secret" };
    }
  }
  return table;
}

/** Bearer token → owner name, or null. Never logs the token. */
export async function ownerForToken(token: string, env: Env): Promise<string | null> {
  if (!token) return null;
  const presented = await sha256Hex(token);
  const owners = await loadOwners(env);
  for (const [owner, record] of Object.entries(owners)) {
    if (timingSafeEqual(presented, record.hash)) return owner;
  }
  return null;
}

/** The owner named by an Authorization header, or null. */
export async function authorize(request: Request, env: Env): Promise<string | null> {
  const header = request.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  return ownerForToken(token, env);
}

/** Owner names are used in URLs, HTML and KV keys, so keep them boring. */
export function validOwnerName(name: string): boolean {
  return /^[a-z0-9][a-z0-9_-]{0,31}$/i.test(name);
}

export function newToken(): string {
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  // base64url, so it survives a copy-paste through anything
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

export function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${bytes} B`;
}
