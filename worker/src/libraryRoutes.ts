// HTTP for the shared library (docs/SHARED-LIBRARY.md §5.3).
//
// Every route here is gated twice: the owner must be allowlisted (F118) and the caller must hold
// a device credential (F2, F21). Enrolment is the one exception — it is how a device gets that
// credential — and it takes the owner credential instead.
//
// Device credentials live in the owner's LibraryLog Durable Object, not in the KV owner table.
// KV is eventually consistent, which let a second Mac enrol with no approval inside the
// propagation window and let a revoked credential keep working at other edge locations.

import {
  Env, SECURITY_HEADERS, authorize, bearerToken, json, newToken, sha256Hex,
} from "./common";
import {
  blobKey, libraryEnabled, libraryLogFor, ownerPrefix, snapshotKey, type LibraryLog,
  type OpEnvelope,
} from "./library";
import { quotaFor } from "./quota";

const DEVICE_ID = "[0-9A-HJKMNP-TV-Z]{26}";
const BLINDED_ID = "[0-9A-Z]{1,64}";

// Built once. These were compiled from the two strings above on every request, and two of them
// per `requires` entry — two hundred regex compilations for a full push.
const DEVICE_ID_RE = new RegExp(`^${DEVICE_ID}$`);
const BLINDED_ID_RE = new RegExp(`^${BLINDED_ID}$`);
const APPROVE_RE = new RegExp(`^/api/library/devices/(${DEVICE_ID})/approve$`);
const REVOKE_RE = new RegExp(`^/api/library/devices/(${DEVICE_ID})$`);
const BLOB_RE = new RegExp(
  `^/api/library/blob/(blob|thumb|orig)/(${BLINDED_ID})/(\\d+)/(${DEVICE_ID})$`);
const SNAPSHOT_PUT_RE = /^\/api\/library\/snapshot\/(\d+)$/;
const SNAPSHOT_GET_RE = new RegExp(`^/api/library/snapshot/(\\d+)/(${DEVICE_ID})$`);

/** The shortest trash window the server will sweep against, whatever a client asks for (F45). */
const MIN_TRASH_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

function noContent(): Response {
  return new Response(null, { status: 204, headers: SECURITY_HEADERS });
}

/** A short, readable digest of a credential, shown on both screens during approval (F124). */
async function fingerprint(token: string): Promise<string> {
  const hex = await sha256Hex(token);
  return hex.slice(0, 8).toUpperCase().match(/.{1,4}/g)!.join("-");
}

interface DeviceIdentity { owner: string; deviceID: string; approved: boolean }

/**
 * The device a bearer credential belongs to (F2): its identity, "disabled" when the owner is not
 * on the allowlist (F118), or null.
 *
 * A device credential is `<owner>.<secret>`, so the owner's Durable Object can be asked directly
 * rather than every owner being scanned. Owner names cannot contain a dot (`validOwnerName`), so
 * the first one separates them. The owner token is deliberately not accepted here: it authorizes
 * enrolment and the M5 share routes and nothing else.
 *
 * The allowlist is checked before the Durable Object is called. The owner name comes from an
 * unauthenticated header, and `idFromName` on an arbitrary name would create an object for it.
 */
async function authorizeDevice(
  request: Request, env: Env,
): Promise<DeviceIdentity | "disabled" | null> {
  const token = bearerToken(request);
  const dot = token.indexOf(".");
  if (dot <= 0) return null;
  const owner = token.slice(0, dot);
  if (!libraryEnabled(env, owner)) return "disabled";
  const found = await libraryLogFor(env, owner).verifyDevice(await sha256Hex(token));
  return found ? { owner, ...found } : null;
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
    if (!DEVICE_ID_RE.test(deviceID)) {
      return json({ error: "deviceID must be a ULID" }, 400);
    }

    const token = `${owner}.${newToken()}`;
    const mark = await fingerprint(token);
    // F5, F113, F114, F117 are checked and written together, inside the Durable Object.
    const outcome = await libraryLogFor(env, owner).enrol({
      deviceID,
      hash: await sha256Hex(token),
      name: (body?.name ?? "Mac").slice(0, 64),
      platform: (body?.platform ?? "macOS").slice(0, 32),
      keyID: (body?.keyID ?? "").trim(),
      fingerprint: mark,
    });
    if ("error" in outcome) {
      return json({ error: "this owner already has a library under a different key",
                    keyID: outcome.keyID }, 409);
    }
    return json({ deviceID, token, approved: outcome.approved, fingerprint: mark },
                outcome.approved ? 200 : 202);
  }

  // ---- everything below needs a device credential (F2, F21) --------------
  const identity = await authorizeDevice(request, env);
  if (identity === "disabled") return json({ error: "not found" }, 404);
  if (!identity) return json({ error: "unauthorized" }, 401);
  // F113: the credential is real, the Mac is not approved yet. 403 is what the client reads as
  // "waiting for approval", so no other route may answer 403 for anything else.
  if (!identity.approved) return json({ error: "awaiting approval" }, 403);
  const { owner, deviceID } = identity;
  const log = libraryLogFor(env, owner);

  // ---- devices (§3.3) ----------------------------------------------------
  if (path === "/api/library/devices" && request.method === "GET") {
    const devices = await log.listDevices();
    return json({
      items: devices.map((device) => ({ ...device, current: device.deviceID === deviceID })),
    });
  }

  const approveMatch = path.match(APPROVE_RE);
  if (approveMatch && request.method === "POST") {
    // F125: an enrolled Mac may approve, as a convenience. F124's dashboard is the mechanism.
    return (await log.approveDevice(approveMatch[1]))
      ? noContent() : json({ error: "not found" }, 404);
  }

  const revokeMatch = path.match(REVOKE_RE);
  if (revokeMatch && request.method === "DELETE") {
    return (await log.revokeDevice(revokeMatch[1]))
      ? noContent() : json({ error: "not found" }, 404);
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

    // F107: an admitted delete removes the capture's bytes, every revision and purpose, and
    // returns their space. Nothing did this before, so stored usage only ever grew. The DO's
    // tombstone (F132) already refuses later writes to the capture, so nothing can land between
    // the admission and this cleanup.
    const admitted = new Set(outcome.assigned.map((a) => a.opID));
    for (const op of ops) {
      if (op.kind === "delete" && admitted.has(op.opID)) {
        await deleteCaptureBytes(env, owner, op.blindedID, log);
      }
    }
    // Objects a fork kept alive past its parent's delete, now used by nothing (F128).
    const { released, ...reply } = outcome;
    if (released && released.length > 0) await deleteObjects(env, owner, released);
    return json(reply, reply.rejected.length > 0 && reply.assigned.length === 0 ? 409 : 200);
  }

  // ---- snapshot (F102) ---------------------------------------------------
  if (path === "/api/library/snapshot" && request.method === "POST") {
    const body = await request.json().catch(() => null) as
      { supportsV?: number; seq?: number } | null;
    const claim = await log.claimSnapshot(deviceID, Number(body?.supportsV ?? 0),
                                          Number(body?.seq ?? 0));
    if (!claim.granted) return json(claim, 409);
    return json(claim);
  }

  const snapshotPut = path.match(SNAPSHOT_PUT_RE);
  if (snapshotPut && request.method === "PUT") {
    const seq = Number(snapshotPut[1]);
    // The completeness gate (F102) is the claim. A PUT that skipped it would publish a "whole
    // library at seq N" from a device the gate never examined — exactly the client F102 exists
    // to stop, since compaction then deletes the ops that snapshot left out.
    if (!(await log.consumeSnapshotClaim(deviceID, seq))) {
      return json({ error: "no granted snapshot claim for this seq" }, 409);
    }
    const bytes = await request.arrayBuffer();
    const key = snapshotKey(owner, seq, deviceID);
    // A snapshot is bytes under `lib/`, so it is charged like any other (F56, F57).
    const quotaError = await quotaFor(env, owner).chargeLibrary(bytes.byteLength);
    if (quotaError) return json({ error: quotaError }, 429);
    await env.BUCKET.put(key, bytes);
    await log.recordSnapshot(seq, key, bytes.byteLength);
    return json({ key, seq, bytes: bytes.byteLength });
  }

  const snapshotGet = path.match(SNAPSHOT_GET_RE);
  if (snapshotGet && request.method === "GET") {
    const object = await env.BUCKET.get(
      snapshotKey(owner, Number(snapshotGet[1]), snapshotGet[2]));
    if (!object) return json({ error: "not found" }, 404);
    return new Response(object.body, { headers: SECURITY_HEADERS });
  }

  // ---- sweep lease (F43) -------------------------------------------------
  if (path === "/api/library/lease/sweep" && request.method === "POST") {
    const lease = await log.acquireSweepLease(deviceID);
    if (!lease.granted) return json(lease, 409);
    // F45/F108: both ends of the comparison are the server's, and so is the window. A client
    // asking for a shorter one would make a capture trashed a minute ago immediately eligible.
    const asked = Number(url.searchParams.get("windowMs"));
    const window = Number.isFinite(asked) ? Math.max(asked, MIN_TRASH_WINDOW_MS) : MIN_TRASH_WINDOW_MS;
    return json({ ...lease, eligible: await log.sweepEligible(window) });
  }

  // ---- blobs (§8) --------------------------------------------------------
  const blobMatch = path.match(BLOB_RE);
  if (blobMatch) return handleBlob(request, env, url, owner, deviceID, blobMatch);

  // ---- storage usage, and the only supported repair for drift (F59, F76) ----
  if (path === "/api/library/usage" && request.method === "GET") {
    if (url.searchParams.get("reconcile") === "1") {
      return json(await quotaFor(env, owner).reconcileStored(owner));
    }
    return json(await quotaFor(env, owner).storedUsage());
  }

  return json({ error: "not found" }, 404);
}

/**
 * Blob routes (F19, F22, F99, F100, F54, F87), on an already-authenticated device.
 */
async function handleBlob(
  request: Request, env: Env, url: URL, owner: string, deviceID: string,
  match: RegExpMatchArray,
): Promise<Response> {
  const [, purpose, blinded, revision, writer] = match;
  const key = blobKey(owner, purpose, blinded, Number(revision), writer);

  if (request.method === "GET") {
    const object = await env.BUCKET.get(key);
    if (!object) return json({ error: "not found" }, 404);
    return new Response(object.body, {
      headers: { "cache-control": "public, max-age=31536000, immutable", ...SECURITY_HEADERS },
    });
  }

  if (writer !== deviceID) return json({ error: "a device writes only its own blobs" }, 403);

  // F99: an object already at this device's own key is this device's own earlier upload of this
  // revision, so a second write is a retry and succeeds. The key names (capture, revision,
  // writer), a device can write only under its own id, and a revision names one content.
  // Comparing ciphertext digests could never recognize a retry: F13 seals with a fresh random
  // nonce, so re-sealing the same pixels never produces the same bytes, and every retry after
  // a lost response was answered 409 and the capture never reached the log.
  const existing = await env.BUCKET.head(key);

  if (request.method === "PUT" && !url.searchParams.has("uploadId")) {
    if (existing) return json({ key, bytes: existing.size, retry: true });
    const body = await request.arrayBuffer();
    const quotaError = await quotaFor(env, owner).chargeLibrary(body.byteLength);
    if (quotaError) return json({ error: quotaError }, 429);
    await env.BUCKET.put(key, body);
    return json({ key, bytes: body.byteLength });
  }

  // ---- multipart (F54, F87) — R2's own, so no part is ever held here ------
  //
  // The previous version staged parts as objects and joined them in Worker memory, holding about
  // twice the file in a 128 MB isolate: no recording over the threshold could ever complete.

  if (request.method === "POST" && url.searchParams.has("uploads")) {
    if (existing) return json({ key, exists: true });
    const upload = await env.BUCKET.createMultipartUpload(key);
    // A device restarted mid-upload starts over under the same key; the upload it left is
    // aborted and its parts credited, so they are neither stored nor charged twice.
    const replaced = await quotaFor(env, owner).beginMultipart(key, upload.uploadId);
    if (replaced) {
      await env.BUCKET.resumeMultipartUpload(key, replaced).abort().catch(() => {});
    }
    return json({ key, uploadId: upload.uploadId });
  }

  const uploadId = url.searchParams.get("uploadId");
  if (uploadId) {
    const upload = env.BUCKET.resumeMultipartUpload(key, uploadId);

    if (request.method === "PUT") {
      const partNumber = Number(url.searchParams.get("part"));
      if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10_000) {
        return json({ error: "bad part number" }, 400);
      }
      const body = await request.arrayBuffer();
      // Parts occupy storage from the moment they land, so their bytes are charged as they
      // arrive. They are not objects yet; completing the upload counts it once.
      const quotaError = await quotaFor(env, owner)
        .chargePart(key, uploadId, partNumber, body.byteLength);
      if (quotaError) return json({ error: quotaError }, 429);
      const part = await upload.uploadPart(partNumber, body);
      return json({ partNumber: part.partNumber, etag: part.etag });
    }

    if (request.method === "POST" && url.searchParams.has("complete")) {
      const body = await request.json().catch(() => null) as
        { parts?: { partNumber: number; etag: string }[] } | null;
      const parts = body?.parts;
      if (!Array.isArray(parts) || parts.length === 0) {
        return json({ error: "parts must be a non-empty array" }, 400);
      }
      try {
        const object = await upload.complete(parts);
        await quotaFor(env, owner).completeMultipart(key);
        return json({ key, bytes: object.size });
      } catch (error) {
        return json({ error: `could not complete: ${String(error)}` }, 409);
      }
    }
  }

  if (request.method === "DELETE") {
    if (!existing) return json({ error: "not found" }, 404);
    await env.BUCKET.delete(key);
    await quotaFor(env, owner).creditLibrary(existing.size);
    return noContent();
  }

  return json({ error: "not found" }, 404);
}

/** Every stored revision of a capture, in every purpose, and the space it held (F20, F107). */
async function deleteCaptureBytes(env: Env, owner: string, blindedID: string,
                                  log: DurableObjectStub<LibraryLog>): Promise<void> {
  // F128: a fork keeps its bytes under the capture it forked from, so those objects are left
  // for as long as a fork uses them. Deleting the whole prefix deleted the fork's content.
  const kept = new Set(await log.retainForDelete(blindedID));
  let bytes = 0;
  let objects = 0;
  for (const purpose of ["blob", "thumb", "orig"]) {
    let cursor: string | undefined;
    do {
      const listed = await env.BUCKET.list({
        prefix: `${ownerPrefix(owner)}${purpose}/${blindedID}/`, cursor,
      });
      const doomed = listed.objects.filter((object) => !kept.has(object.key));
      for (const object of doomed) { bytes += object.size; objects += 1; }
      if (doomed.length > 0) await env.BUCKET.delete(doomed.map((object) => object.key));
      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);
  }
  if (objects > 0) await quotaFor(env, owner).creditLibrary(bytes, objects);
}

/** Delete these objects and return their space. */
async function deleteObjects(env: Env, owner: string, keys: string[]): Promise<void> {
  let bytes = 0;
  let objects = 0;
  for (const key of keys) {
    const head = await env.BUCKET.head(key);
    if (!head) continue;
    bytes += head.size;
    objects += 1;
  }
  await env.BUCKET.delete(keys);
  if (objects > 0) await quotaFor(env, owner).creditLibrary(bytes, objects);
}

function parseEnvelope(entry: unknown, deviceID: string): OpEnvelope | null {
  if (typeof entry !== "object" || entry === null) return null;
  const op = entry as Record<string, unknown>;
  const opID = typeof op.opID === "string" ? op.opID : "";
  const blindedID = typeof op.blindedID === "string" ? op.blindedID : "";
  const kind = op.kind;
  if (!opID || !blindedID) return null;
  if (!BLINDED_ID_RE.test(blindedID)) return null;
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
    // Every field here is interpolated into an R2 key, so each is validated against the same
    // shapes the routes use rather than cast and trusted. An op is attacker-controlled if a
    // device credential leaks (§13).
    requires: requires.flatMap((ref) => {
      const entry = ref as Record<string, unknown>;
      const purpose = entry.purpose;
      if (purpose !== "blob" && purpose !== "thumb" && purpose !== "orig") return [];
      const revision = Number(entry.revision);
      if (!Number.isSafeInteger(revision) || revision < 0) return [];
      const writer = String(entry.writer ?? deviceID);
      if (!DEVICE_ID_RE.test(writer)) return [];
      const capture = entry.capture === undefined ? undefined : String(entry.capture);
      if (capture !== undefined && !BLINDED_ID_RE.test(capture)) return [];
      return [{ purpose, revision, writer, capture }];
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
