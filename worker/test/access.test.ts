// The admin dashboard trusts this verifier completely, and the header it reads is forgeable by
// anything that reaches the Worker directly. So the failures matter more than the success:
// a token signed by the wrong key, minted for a different Access application, expired, or
// downgraded to alg:none must all be nobody.
import { describe, it, expect, beforeAll } from "vitest";
import { verifyAccessToken, type JWKS } from "../src/access";

const ISSUER = "https://kapture.cloudflareaccess.com";
const AUD = "aud-tag-for-this-app";

let keyPair: CryptoKeyPair;
let jwks: JWKS;
let otherJwks: JWKS;

function b64url(bytes: Uint8Array | string): string {
  const binary = typeof bytes === "string" ? bytes
    : Array.from(bytes, (b) => String.fromCharCode(b)).join("");
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function jwksFor(pair: CryptoKeyPair, kid: string): Promise<JWKS> {
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
  return { keys: [{ kid, kty: jwk.kty!, n: jwk.n!, e: jwk.e!, alg: "RS256" }] };
}

async function sign(payload: Record<string, unknown>, pair = keyPair,
                    header: Record<string, unknown> = { alg: "RS256", kid: "test-key" }) {
  const data = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(data));
  return `${data}.${b64url(new Uint8Array(signature))}`;
}

const validPayload = (overrides: Record<string, unknown> = {}) => ({
  iss: ISSUER,
  aud: [AUD],
  email: "darrin@massena.com",
  sub: "user-123",
  exp: Math.floor(Date.now() / 1000) + 600,
  ...overrides,
});

beforeAll(async () => {
  const params = { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048,
                   publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };
  keyPair = (await crypto.subtle.generateKey(params, true, ["sign", "verify"])) as CryptoKeyPair;
  const other = (await crypto.subtle.generateKey(params, true, ["sign", "verify"])) as CryptoKeyPair;
  jwks = await jwksFor(keyPair, "test-key");
  otherJwks = await jwksFor(other, "test-key");
});

describe("Access token verification", () => {
  const options = { audience: AUD, issuer: ISSUER };

  it("accepts a properly signed token and reports who it is", async () => {
    const identity = await verifyAccessToken(await sign(validPayload()), jwks, options);
    expect(identity?.email).toBe("darrin@massena.com");
    expect(identity?.subject).toBe("user-123");
  });

  it("rejects a token signed by a key that isn't the team's", async () => {
    const token = await sign(validPayload());
    expect(await verifyAccessToken(token, otherJwks, options)).toBeNull();
  });

  /// The one that matters most: Access mints tokens for every application in an account, and
  /// another app's token must not open this one.
  it("rejects a token minted for a different application", async () => {
    const token = await sign(validPayload({ aud: ["some-other-app"] }));
    expect(await verifyAccessToken(token, jwks, options)).toBeNull();
  });

  it("rejects an expired token", async () => {
    const token = await sign(validPayload({ exp: Math.floor(Date.now() / 1000) - 5 }));
    expect(await verifyAccessToken(token, jwks, options)).toBeNull();
  });

  it("rejects a token from another team", async () => {
    const token = await sign(validPayload({ iss: "https://someone-else.cloudflareaccess.com" }));
    expect(await verifyAccessToken(token, jwks, options)).toBeNull();
  });

  it("refuses an unsigned token dressed up as one", async () => {
    const header = b64url(JSON.stringify({ alg: "none", kid: "test-key" }));
    const payload = b64url(JSON.stringify(validPayload()));
    expect(await verifyAccessToken(`${header}.${payload}.`, jwks, options)).toBeNull();
  });

  it("refuses a token whose payload was edited after signing", async () => {
    const token = await sign(validPayload());
    const [h, , s] = token.split(".");
    const swapped = b64url(JSON.stringify(validPayload({ email: "attacker@example.com" })));
    expect(await verifyAccessToken(`${h}.${swapped}.${s}`, jwks, options)).toBeNull();
  });

  it("refuses a token whose key id names nothing we know", async () => {
    const token = await sign(validPayload(), keyPair, { alg: "RS256", kid: "unknown" });
    expect(await verifyAccessToken(token, jwks, options)).toBeNull();
  });

  it("refuses rubbish without throwing", async () => {
    for (const junk of ["", "a.b", "....", "not-a-token", "a.b.c"]) {
      expect(await verifyAccessToken(junk, jwks, options)).toBeNull();
    }
  });

  it("refuses a token with no email to attribute it to", async () => {
    const token = await sign(validPayload({ email: undefined }));
    expect(await verifyAccessToken(token, jwks, options)).toBeNull();
  });
});
