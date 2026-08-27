// Cloudflare Access in front of /admin.
//
// Access authenticates the person at the edge and forwards a signed JWT. The Worker's job is to
// verify that JWT properly, because the header is only trustworthy if we check it: a request
// that reaches the Worker from anywhere other than the Access edge can set any header it likes.
// So: verify the RS256 signature against the team's published keys, and check the audience is
// *this* application — an Access token minted for some other app in the same account must not
// open this dashboard.
//
// The verification is a pure function over an already-fetched JWKS so it can be tested with
// generated keys; only the fetching and caching touch the network.

export interface AccessIdentity {
  email: string;
  /** The Access user id, for logs. */
  subject: string;
}

interface JWK {
  kid: string;
  kty: string;
  n: string;
  e: string;
  alg?: string;
}

export interface JWKS {
  keys: JWK[];
}

function base64urlToBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/")
    .padEnd(value.length + ((4 - (value.length % 4)) % 4), "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function decodeSegment(segment: string): Record<string, unknown> | null {
  try {
    return JSON.parse(new TextDecoder().decode(base64urlToBytes(segment)));
  } catch {
    return null;
  }
}

export interface VerifyOptions {
  /** The Access application's AUD tag. A token for another app must not be accepted. */
  audience: string;
  /** https://<team>.cloudflareaccess.com */
  issuer: string;
  /** Seconds since the epoch; injectable so expiry can be tested. */
  now?: number;
}

/**
 * Verify an Access JWT. Returns the identity it attests to, or null for anything at all wrong.
 * Never throws: a malformed token is simply not an identity.
 */
export async function verifyAccessToken(
  token: string, jwks: JWKS, options: VerifyOptions,
): Promise<AccessIdentity | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [rawHeader, rawPayload, rawSignature] = parts;

  const header = decodeSegment(rawHeader);
  const payload = decodeSegment(rawPayload);
  if (!header || !payload) return null;
  if (header.alg !== "RS256") return null;   // never honour "none", never accept a downgrade

  const kid = typeof header.kid === "string" ? header.kid : "";
  const key = jwks.keys.find((candidate) => candidate.kid === kid);
  if (!key) return null;

  let verified = false;
  try {
    const publicKey = await crypto.subtle.importKey(
      "jwk", { kty: key.kty, n: key.n, e: key.e, alg: "RS256", ext: true },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"],
    );
    verified = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5", publicKey, base64urlToBytes(rawSignature),
      new TextEncoder().encode(`${rawHeader}.${rawPayload}`),
    );
  } catch {
    return null;
  }
  if (!verified) return null;

  const now = options.now ?? Math.floor(Date.now() / 1000);
  const exp = Number(payload.exp);
  const nbf = Number(payload.nbf);
  if (!Number.isFinite(exp) || exp <= now) return null;
  if (Number.isFinite(nbf) && nbf > now + 60) return null;

  if (payload.iss !== options.issuer) return null;

  // aud is a string or an array of them, and must contain this application
  const audience = payload.aud;
  const audiences = Array.isArray(audience) ? audience.map(String) : [String(audience)];
  if (!audiences.includes(options.audience)) return null;

  const email = typeof payload.email === "string" ? payload.email : "";
  if (!email) return null;
  return { email, subject: typeof payload.sub === "string" ? payload.sub : "" };
}

/** Where Access publishes the team's signing keys. */
export function certsURL(teamDomain: string): string {
  return `https://${teamDomain}/cdn-cgi/access/certs`;
}

export function issuerFor(teamDomain: string): string {
  return `https://${teamDomain}`;
}

/** The key id a token names, so a rotation can be noticed without trusting anything in it. */
export function kidOf(token: string): string {
  const header = decodeSegment(token.split(".")[0] ?? "");
  return typeof header?.kid === "string" ? header.kid : "";
}

/**
 * The team's public keys, cached in KV. Access rotates them, so this is a short cache rather
 * than a permanent one, and a fetch failure is never cached.
 *
 * `refresh` skips the cached copy: the caller uses it when a token names a key the cache has
 * never heard of, which is what a rotation looks like from here. Without it a rotation locks
 * the admin out of their own dashboard until the hour is up.
 */
export async function loadJWKS(
  teamDomain: string, cache: KVNamespace, refresh = false,
): Promise<JWKS | null> {
  const key = `access-jwks:${teamDomain}`;
  const cached = refresh ? null : ((await cache.get(key, "json")) as JWKS | null);
  if (cached?.keys?.length) return cached;
  try {
    const response = await fetch(certsURL(teamDomain));
    if (!response.ok) return null;
    const jwks = (await response.json()) as JWKS;
    if (!jwks?.keys?.length) return null;
    await cache.put(key, JSON.stringify(jwks), { expirationTtl: 3600 });
    return jwks;
  } catch {
    return null;
  }
}

/** The Access JWT on a request, from either the header or the cookie Access sets. */
export function accessTokenFrom(request: Request): string {
  const header = request.headers.get("cf-access-jwt-assertion");
  if (header) return header;
  const raw = request.headers.get("cookie") ?? "";
  for (const part of raw.split(";")) {
    const [name, ...rest] = part.trim().split("=");
    if (name === "CF_Authorization") return rest.join("=");
  }
  return "";
}
