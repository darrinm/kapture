// HTTP for the shared library (docs/SHARED-LIBRARY.md §5.3).
//
// Every route here is gated twice: the owner must be allowlisted (F118) and the caller must hold
// a device credential (F2, F21). Enrolment is the one exception — it is how a device gets that
// credential — and it takes the owner credential instead.

import {
  Device, Env, SECURITY_HEADERS, authorize, authorizeDevice, bearerToken, json, loadOwners,
  newToken, saveOwners, sha256Hex,
} from "./common";
import { libraryEnabled, libraryLogFor, type OpEnvelope } from "./library";
import { quotaFor } from "./quota";

const DEVICE_ID = "[0-9A-HJKMNP-TV-Z]{26}";
const BLINDED_ID = "[0-9A-Z]{1,64}";

function noContent(): Response {
  return new Response(null, { status: 204, headers: SECURITY_HEADERS });
}

/** A short, readable digest of a credential, shown on both screens during approval (F124). */
async function fingerprint(token: string): Promise<string> {
  const hex = await sha256Hex(token);
  return hex.slice(0, 8).toUpperCase().match(/.{1,4}/g)!.join("-");
}

export async function handleLibrary(
  request: Request, env: Env, url: URL,
): Promise<Response | null> {
  const path = url.pathname;
  if (!path.startsWith("/api/library")) return null;

  // ---- enrolment (owner credential) -------------------------------------
  if (path === "/api/library/enroll" && request.method === "POST") {
    const owner = await authorize(request, env);
    if (!owner) return json({ error: "unauthorized" }, 401);
    if (!libraryEnabled(env, owner)) return json({ error: "not found" }, 404);

    const body = await request.json().catch(() => null) as {
      deviceID?: string; name?: string; platform?: string; keyID?: string;
    } | null;
    const deviceID = (body?.deviceID ?? "").trim();
    if (!new RegExp(`^${DEVICE_ID}$`).test(deviceID)) {
      return json({ error: "deviceID must be a ULID" }, 400);
    }

    const owners = await loadOwners(env);
    const record = owners[owner];
    if (!record) return json({ error: "unauthorized" }, 401);
    const devices = record.devices ?? {};      // F74: absent means none, not broken

    // F117: the library's key is fixed by the first enrolment. A device with a different key
    // would write a second, unreadable half of one log.
    const presentedKeyID = (body?.keyID ?? "").trim();
    if (record.keyID && presentedKeyID && presentedKeyID !== record.keyID) {
      return json({ error: "this owner already has a library under a different key",
                    keyID: record.keyID }, 409);
    }

    const token = newToken();
    const mark = await fingerprint(token);
    // F5, F113, F114: silent only for the very first device this owner has ever had.
    const approved = !record.hadDevice;
    const device: Device = {
      hash: await sha256Hex(token),
      name: (body?.name ?? "Mac").slice(0, 64),
      platform: (body?.platform ?? "macOS").slice(0, 32),
      createdAt: new Date().toISOString(),
      approved,
      fingerprint: mark,
    };
    owners[owner] = {
      ...record,
      devices: { ...devices, [deviceID]: device },
      keyID: record.keyID ?? (presentedKeyID || undefined),
      hadDevice: true,
    };
    await saveOwners(env, owners);

    return json({ deviceID, token, approved, fingerprint: mark }, approved ? 200 : 202);
  }

  // ---- everything below needs a device credential (F2, F21) --------------
  const identity = await authorizeDevice(request, env);
  if (!identity) return json({ error: "unauthorized" }, 401);
  if (!libraryEnabled(env, identity.owner)) return json({ error: "not found" }, 404);
  const { owner, deviceID } = identity;
  const log = libraryLogFor(env, owner);

  // ---- devices -----------------------------------------------------------
  if (path === "/api/library/devices" && request.method === "GET") {
    const owners = await loadOwners(env);
    const devices = owners[owner]?.devices ?? {};
    return json({
      items: Object.entries(devices).map(([id, device]) => ({
        deviceID: id, name: device.name, platform: device.platform,
        createdAt: device.createdAt, lastSeenAt: device.lastSeenAt,
        approved: device.approved, fingerprint: device.fingerprint,
        current: id === deviceID,
      })),
    });
  }

  const approveMatch = path.match(new RegExp(`^/api/library/devices/(${DEVICE_ID})/approve$`));
  if (approveMatch && request.method === "POST") {
    // F125: an enrolled Mac may approve, as a convenience. F124's dashboard is the mechanism.
    const owners = await loadOwners(env);
    const record = owners[owner];
    const pending = record?.devices?.[approveMatch[1]];
    if (!record || !pending) return json({ error: "not found" }, 404);
    record.devices![approveMatch[1]] = { ...pending, approved: true };
    await saveOwners(env, owners);
    return noContent();
  }

  const revokeMatch = path.match(new RegExp(`^/api/library/devices/(${DEVICE_ID})$`));
  if (revokeMatch && request.method === "DELETE") {
    const owners = await loadOwners(env);
    const record = owners[owner];
    if (!record?.devices?.[revokeMatch[1]]) return json({ error: "not found" }, 404);
    delete record.devices[revokeMatch[1]];
    await saveOwners(env, owners);       // hadDevice stays true: F114 keeps the gate closed
    return noContent();
  }

  // ---- pull (F26) --------------------------------------------------------
  if (path === "/api/library/changes" && request.method === "GET") {
    const since = Number(url.searchParams.get("since") ?? 0);
    const limit = Number(url.searchParams.get("limit") ?? 500);
    if (!Number.isFinite(since) || since < 0) return json({ error: "bad cursor" }, 400);
    const page = await log.changes(since, Number.isFinite(limit) ? limit : 500);
    await log.noteDevice(deviceID, since);
    return json({
      ops: page.ops.map((op) => ({
        seq: op.seq, opID: op.opID, deviceID: op.deviceID, blindedID: op.blindedID,
        v: op.v, kind: op.kind, observed: op.observed, at: op.at,
        ciphertext: toBase64(op.ciphertext as ArrayBuffer),
      })),
      head: page.head,
      oldestRetained: page.oldestRetained,
    });
  }

  // ---- push (F30) --------------------------------------------------------
  if (path === "/api/library/ops" && request.method === "POST") {
    const body = await request.json().catch(() => null) as { ops?: unknown[] } | null;
    const raw = Array.isArray(body?.ops) ? body!.ops! : null;
    if (!raw) return json({ error: "ops must be an array" }, 400);
    if (raw.length > 100) return json({ error: "at most 100 ops per call" }, 400);

    const ops: OpEnvelope[] = [];
    for (const entry of raw) {
      const parsed = parseEnvelope(entry, deviceID);
      if (!parsed) return json({ error: "malformed op" }, 400);
      ops.push(parsed);
    }
    const outcome = await log.append(owner, ops);
    return json(outcome, outcome.rejected.length > 0 && outcome.assigned.length === 0 ? 409 : 200);
  }

  // ---- snapshot (F102) ---------------------------------------------------
  if (path === "/api/library/snapshot" && request.method === "POST") {
    const body = await request.json().catch(() => null) as
      { supportsV?: number; seq?: number } | null;
    const claim = await log.claimSnapshot(
      deviceID, Number(body?.supportsV ?? 0), Number(body?.seq ?? 0));
    if (!claim.granted) return json(claim, 409);
    return json(claim);
  }

  const snapshotPut = path.match(/^\/api\/library\/snapshot\/(\d+)$/);
  if (snapshotPut && request.method === "PUT") {
    const seq = Number(snapshotPut[1]);
    const bytes = await request.arrayBuffer();
    const key = `lib/${owner}/snap/${seq}/${deviceID}`;
    await env.BUCKET.put(key, bytes);
    await log.recordSnapshot(seq, key, bytes.byteLength);
    return json({ key, seq, bytes: bytes.byteLength });
  }

  const snapshotGet = path.match(/^\/api\/library\/snapshot\/(\d+)\/([0-9A-HJKMNP-TV-Z]{26})$/);
  if (snapshotGet && request.method === "GET") {
    const object = await env.BUCKET.get(`lib/${owner}/snap/${snapshotGet[1]}/${snapshotGet[2]}`);
    if (!object) return json({ error: "not found" }, 404);
    return new Response(object.body, { headers: SECURITY_HEADERS });
  }

  // ---- sweep lease (F43) -------------------------------------------------
  if (path === "/api/library/lease/sweep" && request.method === "POST") {
    const lease = await log.acquireSweepLease(deviceID);
    if (!lease.granted) return json(lease, 409);
    const window = Number(url.searchParams.get("windowMs") ?? 7 * 24 * 60 * 60 * 1000);
    return json({ ...lease, eligible: await log.sweepEligible(window) });
  }

  // ---- blobs (F19, F22, F99, F100) ---------------------------------------
  const blobMatch = path.match(
    new RegExp(`^/api/library/blob/(blob|thumb|orig)/(${BLINDED_ID})/(\\d+)/(${DEVICE_ID})$`));
  if (blobMatch) {
    const [, purpose, blinded, revision, writer] = blobMatch;
    const key = `lib/${owner}/${purpose}/${blinded}/${revision}/${writer}`;

    if (request.method === "GET") {
      const object = await env.BUCKET.get(key);
      if (!object) return json({ error: "not found" }, 404);
      return new Response(object.body, {
        headers: { "cache-control": "public, max-age=31536000, immutable", ...SECURITY_HEADERS },
      });
    }

    if (request.method === "PUT") {
      if (writer !== deviceID) return json({ error: "a device writes only its own blobs" }, 403);
      const body = await request.arrayBuffer();

      // F54, F87: a part of a multipart upload, staged under its own key and joined on
      // completion. Parts are 32 MB because each one is held in memory by this invocation.
      const part = url.searchParams.get("part");
      if (part) {
        const index = Number(part);
        if (!Number.isInteger(index) || index < 1 || index > 10_000) {
          return json({ error: "bad part number" }, 400);
        }
        await env.BUCKET.put(`${key}.part${index}`, body);
        return json({ key, part: index, bytes: body.byteLength });
      }

      const existing = await env.BUCKET.head(key);
      if (existing) {
        // F99: a PUT whose response was lost looks like a collision to the retrying client, and
        // F81 would read that as a fork against itself. Identical bytes are a retry, not a
        // conflict, so answer 200 rather than 409.
        const digest = await sha256Hex(toBase64(body));
        const stored = existing.customMetadata?.digest;
        if (stored && stored === digest) return json({ key, bytes: body.byteLength, retry: true });
        return json({ error: "blob already exists" }, 409);
      }

      const quotaError = await quotaFor(env, owner).chargeLibrary(body.byteLength);
      if (quotaError) return json({ error: quotaError }, 429);

      await env.BUCKET.put(key, body, {
        customMetadata: { digest: await sha256Hex(toBase64(body)) },
      });
      return json({ key, bytes: body.byteLength });
    }

    if (request.method === "POST" && url.searchParams.has("complete")) {
      if (writer !== deviceID) return json({ error: "a device writes only its own blobs" }, 403);
      const parts = Number(url.searchParams.get("complete"));
      if (!Number.isInteger(parts) || parts < 1) return json({ error: "bad part count" }, 400);

      const chunks: Uint8Array[] = [];
      let total = 0;
      for (let index = 1; index <= parts; index++) {
        const staged = await env.BUCKET.get(`${key}.part${index}`);
        if (!staged) return json({ error: `missing part ${index}` }, 409);
        const bytes = new Uint8Array(await staged.arrayBuffer());
        chunks.push(bytes);
        total += bytes.byteLength;
      }
      const quotaError = await quotaFor(env, owner).chargeLibrary(total);
      if (quotaError) return json({ error: quotaError }, 429);

      const joined = new Uint8Array(total);
      let offset = 0;
      for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.byteLength; }
      await env.BUCKET.put(key, joined, {
        customMetadata: { digest: await sha256Hex(toBase64(joined)) },
      });
      for (let index = 1; index <= parts; index++) {
        await env.BUCKET.delete(`${key}.part${index}`);
      }
      return json({ key, bytes: total });
    }

    if (request.method === "DELETE") {
      const head = await env.BUCKET.head(key);
      if (!head) return json({ error: "not found" }, 404);
      await env.BUCKET.delete(key);
      await quotaFor(env, owner).creditLibrary(head.size);
      return noContent();
    }
  }

  // ---- storage usage, and the only supported repair for drift (F59, F76) ----
  if (path === "/api/library/usage" && request.method === "GET") {
    if (url.searchParams.get("reconcile") === "1") {
      return json(await quotaFor(env, owner).reconcileStored(owner));
    }
    return json(await quotaFor(env, owner).storedUsage());
  }

  return json({ error: "not found" }, 404);
}

function parseEnvelope(entry: unknown, deviceID: string): OpEnvelope | null {
  if (typeof entry !== "object" || entry === null) return null;
  const op = entry as Record<string, unknown>;
  const opID = typeof op.opID === "string" ? op.opID : "";
  const blindedID = typeof op.blindedID === "string" ? op.blindedID : "";
  const kind = op.kind;
  if (!opID || !blindedID) return null;
  if (kind !== "upsert" && kind !== "trash" && kind !== "restore" && kind !== "delete") return null;
  if (typeof op.ciphertext !== "string") return null;

  const requires = Array.isArray(op.requires) ? op.requires : [];
  return {
    opID,
    // The writer is the authenticated device, never a client-supplied value: it is a key
    // derivation input (F12), so letting a caller name someone else would misdirect decryption.
    deviceID,
    blindedID,
    v: Number.isFinite(Number(op.v)) ? Number(op.v) : 1,
    kind,
    requires: requires.map((ref) => {
      const entry = ref as Record<string, unknown>;
      return {
        purpose: entry.purpose as "blob" | "thumb" | "orig",
        revision: Number(entry.revision),
        writer: String(entry.writer ?? deviceID),
        capture: typeof entry.capture === "string" ? entry.capture : undefined,
      };
    }),
    observed: Number.isFinite(Number(op.observed)) ? Number(op.observed) : 0,
    ciphertext: fromBase64(op.ciphertext),
  };
}

export function toBase64(buffer: ArrayBuffer | Uint8Array): string {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
