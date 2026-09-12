# Kapture shared library (spec v1)

One library per person, shared by every Mac that person signs in on. Captures taken on the
laptop are searchable from the desktop; a capture annotated on either is annotated on both.

**Status: proposal. None of this is implemented.** It describes M6, after
[M5](STATUS.md#m5-status-it-shares). Code comments cite it the way they cite the v2.1
implementation spec — `shared-library §7.1 F35`.

Requirements are numbered `F1`…; decisions are numbered `D1`…. Unnumbered text is context, not
a commitment. A requirement number is a stable identifier assigned when the requirement is
written, so numbers run in order of addition rather than in document order. They are never
reused and never renumbered.

---

## 1. Scope

### 1.1 What exists today

The library is files under a root (`~/Pictures/Kapture` by default) plus a `.kapture` JSON
sidecar beside each one. Those are the durable truth. A SQLite index in Application Support is
derived and rebuildable. One process owns a root: `Library(exclusive:)` takes an `flock` on
`<root>/.lock` (`Sources/KaptureCore/Library.swift:54`), and file operations are serialized
through `withOperation` and made durable by `op_journal`.

Nothing crosses machines except two Keychain items. The share token and the Anthropic key live
in iCloud Keychain, so a second Mac picks them up without a paste. `kapture.sh` already maps a
bearer token to an owner name (`worker/src/common.ts:41`) and already keeps per-owner
transactional state in a Durable Object (`worker/src/quota.ts`).

### 1.2 Goals

- **G1** Every capture is visible and searchable from every Mac, including captures whose bytes
  are not on that Mac.
- **G2** An edit, rename, discard or restore on one Mac reaches the others.
- **G3** A new Mac reaches a complete library without copying a disk.
- **G4** The server cannot read a capture, its recognized text, or its name.
- **G5** Losing a Mac does not lose captures.
- **G6** Off by default. A library that is never enabled behaves exactly as it does today,
  including the `flock` and the local sweep.

### 1.3 Non-goals

- Real-time collaboration. Two Macs editing one capture within seconds of each other is rare
  and is handled by forking (§7.1), not by merging.
- Sharing a library between two people. "Same user" means one owner, several devices.
- A web library, and any client that is not a Mac. D1 rules both out and was re-confirmed on
  that understanding (§14 Q9): the server holds ciphertext and cannot render a grid, and a
  browser or a phone cannot hold a key that lives in the Mac's iCloud Keychain. This is a
  permanent consequence of a decision taken twice, not a thing to revisit per milestone.
- Syncing Settings, hotkeys, or window positions.
- Replacing share links (M5). Those stay a separate, deliberate publish action on plaintext
  bytes.

---

## 2. Decisions

Four forks decide everything downstream. This spec takes all four.

### D1 — The server holds ciphertext

The client encrypts every byte and every metadata field before upload. The key lives in iCloud
Keychain and never leaves it, which is how the share token already reaches a second Mac.

Taken because the README's privacy claim is currently literal, and a cloud copy of a capture
history is the feature most able to make it false. The cost is real and is accepted: no
server-side thumbnailing, no server-side search, no web viewer for library items, no
cross-user deduplication. §4 specifies the scheme and §13 states what the server still learns.

D2 later narrowed the deployment to a single owner, which changed what this decision defends
against: the operator and the only user became the same person. It was re-examined on that basis
and **kept** (§14 Q9). The threat it answers now is the infrastructure rather than the operator —
Cloudflare, a compromised Cloudflare account, a misconfigured bucket, a subpoena served on the
provider rather than on the person. A capture library is a record of everything its owner has
looked at, which is worth protecting from the place it is stored even when that place is the
owner's own account.

What this costs is accepted a second time, with the price now known rather than estimated: the
derivation in F12 and F95, the envelope split in F97 and F98, key recovery in F85, the locked
state in F86, the `keyID` pinning in F117, and a browser or phone client forever (§1.3). Several
of those were where the first review found blocking errors, and keeping D1 means keeping that
complexity and testing it properly rather than hoping it is right.

### D2 — One owner, several devices

The unit of identity stays the owner name already in the owner table. It gains a set of
per-device credentials (§3). There is no email, no password, and no signup, self-serve or
otherwise.

On `kapture.sh` the library feature is enabled for exactly one owner: the author's. Nobody else
gets cloud storage on that deployment, because the author pays for the bytes and is not running
a storage business. The devices in §3 are that one person's several Macs, which is the entire
scope of "shared by all same-user clients".

- **F118** The Worker enables the library routes for owners on an explicit allowlist, empty by
  default. An owner not on it keeps the M5 share routes and receives 404 from every route in
  §5.3. A deployment that never sets the allowlist serves no libraries, which is the correct
  behaviour for a fork someone deploys without reading this far.

Anyone else who wants the feature runs their own Worker and pays their own R2 bill.
`worker/README.md` already documents deploying one, and nothing in this spec changes that path.

### D3 — Metadata everywhere, thumbnails everywhere, originals on demand

Every Mac holds the full row set and a thumbnail for every capture. Full-resolution stills and
recordings are fetched when opened and cached under a ceiling (§8.3).

Full replication was rejected: a recording library is tens to hundreds of gigabytes and a
laptop should not need all of it. Metadata-only was rejected as an end state, but is the first
shipping stage (§12.1) because it forces identity and conflict resolution to be solved before
any byte moves.

### D4 — The author pays, so the author is the only tenant

R2 storage is roughly $0.015/GB-month with no egress charge, so a 100 GB library is about
$1.50/month. That is affordable for one person and is the reason D2 stops at one owner: the cost
scales with use, and a feature whose marginal cost grows per user is a business, which this
project is not.

The daily transfer quotas that protect against a leaked share token (`worker/src/quota.ts:4`) do
not describe a library, and a first sync at 2 GB/day would take weeks, so §9 replaces them for
library traffic. With one tenant the stored ceiling stops being a product limit and becomes a
personal guardrail: it exists to make a runaway sync fail loudly instead of arriving as a bill.

---

## 3. Identity

### 3.1 Owners and devices

- **F1** The owner table gains a device list. `Owner` becomes
  `{ hash, createdAt, note?, devices: Record<deviceID, Device> }` where
  `Device = { hash, name, platform, createdAt, lastSeenAt }`. The owner `hash` stays, and keeps
  authorizing the M5 share routes unchanged.
- **F2** A device credential authorizes the library routes. The owner credential does not. A
  device credential does not authorize the admin dashboard.
- **F3** `deviceID` is a ULID generated on first enable and stored in the local database, not in
  the Keychain. Two Macs restoring the same Keychain must not become the same device.
- **F4** A device name defaults to the Mac's `localizedName` and is editable in
  Settings › Library. It is sent to the server in plaintext, because revocation needs a list a
  person can read.

### 3.2 Enrolment

- **F5** Enabling the library on a Mac that already has the library key in its Keychain enrols
  silently **only when the owner has no devices yet**. That is the first Mac, creating the
  library. Every later enrolment is approved (F113) before it receives a device credential.
- **F113** Once an owner has one device, enrolling another requires approval from an already
  enrolled device or from the admin dashboard, and the approval names the new device. Silent
  enrolment on a still-valid owner token would undo every revocation: a stolen Mac holds the
  owner token too — iCloud Keychain put it there (§1.1) — so after F8 revokes its device
  credential it could generate a fresh `deviceID` and enrol again. Revoking a device has to mean
  the device cannot come back, or it means nothing.
- **F114** Revoking the last device of an owner does not re-open silent enrolment. The gate is
  "this owner has ever had a device", not "has one now".
- **F124** Approval happens in the admin dashboard, behind Cloudflare Access. A pending
  enrolment is listed there with the device name and a short fingerprint of its credential, and
  the enrolling Mac shows the same fingerprint, so the person approving can see they are
  approving the Mac in front of them. The dashboard is the mechanism because it needs no
  transport that does not already exist: there is no push channel (F28, §14 Q1), and requiring
  an enrolled Mac to be awake and polling would make enrolment depend on a device that may be
  the one that was lost. Under D2 the owner runs the deployment, so the dashboard is always
  theirs to reach.
- **F125** An enrolled Mac may also approve a pending enrolment when it notices one on its next
  poll. That is a convenience and never the only path.
- **F6** Enabling on a Mac with no library key requires the owner token pasted in
  Settings › Library, exactly as the share token is pasted today.
- **F7** A device credential is stored in the local Keychain, not the iCloud Keychain. It is
  per-Mac by definition.
- **F85** The library key has a recovery code: the 256-bit key in Crockford base32 with a
  checksum, shown once when the library is created and re-displayable in Settings on any Mac
  that holds the key. It is the only way into a library from a Mac that cannot get the key from
  iCloud Keychain, and the only backup if iCloud Keychain loses it.
- **F86** An owner token does not carry the library key, so F6's path enrols a device that can
  decrypt nothing. Such a Mac shows the library as **locked** and applies no ops until the
  recovery code is entered. It must not show an empty library: empty and locked are
  indistinguishable to a worried person, and one of them means their captures are gone.

### 3.3 Revocation

- **F8** The admin dashboard lists devices per owner and revokes one. A revoked device's
  credential stops working immediately; its cached local files are untouched, because the server
  cannot reach them and must not pretend otherwise.
- **F9** Revoking a device does not rotate the library key. A revoked device that kept its
  Keychain can still decrypt what it already holds. Re-keying is out of scope for v1; §14 Q3
  tracks it.
- **F10** Revoking the owner credential revokes every device under it.

---

## 4. Encryption

### 4.1 Keys

- **F11** The library key is 256 bits from `SecRandomCopyBytes`, generated once, stored in
  iCloud Keychain with `kSecAttrSynchronizable` beside the share token
  (`Sources/KaptureCore/Keychain.swift`). It is never sent anywhere.
- **F12** Per-object keys are derived from values the reader already has before it decrypts
  anything: `HKDF-SHA256(libraryKey, salt = keyID, info = "kapture/v1/" + purpose + "/" +
  scope + "/" + writer)`, where `writer` is the `deviceID` that produced the object and `scope`
  is fixed per purpose:

  | purpose | scope | where the reader gets it |
  | --- | --- | --- |
  | `row` | `opID` | the plaintext envelope (F97) |
  | `blob`, `thumb`, `orig` | `<owningBlindedID>/<revision>` | the blob's own key path (§5.2), named by `requires` (F98) |
  | `snap` | the snapshot's `seq` | the snapshot's key path (§5.2) |

- **F126** `revision` is not an input for `row`, and `blindedID` is not one either. A row's
  revision lives inside the payload, so deriving from it repeats the F95 mistake one layer
  down: the reader would need the plaintext to find the key to the plaintext. `opID` is unique
  per op, is in the envelope, and identifies exactly one ciphertext, which is everything the
  derivation needs. A rename that re-encrypts a row at an unchanged revision gets a distinct key
  for free, because it is a distinct op.
- **F95** The derivation must never depend on a value carried inside the ciphertext. Deriving
  from `captureID` cannot work: a device receiving an unfamiliar capture holds only the
  `blindedID`, and F15 is an HMAC, which does not invert. `blindedID` is what every holder of
  the library key can compute and every reader already has, so it is what the derivation uses.
- **F96** The salt is the `keyID` (F14), not a `deviceID`. A per-device salt would make an
  object decryptable only by a reader that knew which device wrote it, which is not always
  recoverable — a row re-pushed by a second device (F68) names blobs a first device encrypted.
  `writer` stays in `info` so two devices writing the same logical object derive different keys.
- **F13** Encryption is AES-256-GCM with a fresh random 96-bit nonce per object, the nonce
  prefixed to the ciphertext. Two objects may share a derived key — a rename re-encrypts a row
  at an unchanged revision — so uniqueness rests on the nonce, not on the derivation. At 96 bits
  and this volume the repetition risk is negligible, and F13 is the only thing standing between
  the scheme and a nonce-reuse failure: it is not an incidental detail.
- **F14** The key carries a `keyID` — the first 8 bytes of `SHA-256(libraryKey)` — stored with
  every object. A client holding the wrong key reports "this library was made with a different
  key" instead of decryption noise.
- **F117** The owner's `keyID` is fixed by the first enrolment and recorded by the DO. A device
  presenting a different `keyID` is refused, and told the owner already has a library under
  another key; entering the recovery code (F85) is how it joins. Two Macs enabling before iCloud
  Keychain converges would otherwise each generate a key under F11 and write two unreadable
  halves of one log. The `keyID` is a hash, so recording it tells the server nothing it could use
  and costs none of D1.

### 4.2 Blinded identifiers

A ULID encodes its creation time in the first ten characters. Using capture ids as R2 keys
would hand the server a timeline.

- **F15** The server addresses a capture by
  `blindedID = base32(HMAC-SHA256(libraryKey, captureID))[0..25]`. The client keeps the mapping;
  the server never sees a raw capture id.
- **F16** Ops and blobs are keyed by `blindedID`. A client that loses the key loses the mapping,
  and the library is unrecoverable by anyone, the operator included. This is an intended property
  of D1. The recovery code (F85) is the only mitigation, and Settings must say both things before
  the first byte is uploaded.

### 4.3 What is encrypted

Everything with content in it: the row payload (name, `relPath`, `sourceApp`, `windowTitle`,
`summary`, OCR text, sidecar JSON, layer stacks), thumbnails, stills, recordings, and
`.originals/` files.

Not encrypted, because the server needs them to function: owner name, device id and name,
sequence numbers, blinded capture ids, ciphertext lengths, and op timestamps. §13 states what
that leaks.

---

## 5. Server data model

### 5.1 The `LibraryLog` Durable Object

One instance per owner, addressed by `idFromName(owner)` — the pattern `quotaFor` already uses
(`worker/src/quota.ts:49`). SQLite storage.

```sql
CREATE TABLE ops (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  opID       TEXT NOT NULL UNIQUE,   -- client ULID, for idempotent retry
  deviceID   TEXT NOT NULL,          -- the writer, and part of the key derivation (F12)
  blindedID  TEXT NOT NULL,
  v          INTEGER NOT NULL,       -- payload version, so the server can police F100
  requires   TEXT NOT NULL,          -- JSON [{purpose, revision, writer}], for F32
  observed   INTEGER NOT NULL,       -- the seq this device had applied when it wrote the op
  ciphertext BLOB NOT NULL,
  bytes      INTEGER NOT NULL,
  at         TEXT NOT NULL           -- assigned by the DO, never by a client (F103)
);
CREATE INDEX ops_by_capture ON ops(blindedID, seq);

CREATE TABLE snapshots (
  seq   INTEGER PRIMARY KEY,         -- the op seq this snapshot includes through
  key   TEXT NOT NULL,               -- R2 key of the encrypted snapshot
  bytes INTEGER NOT NULL,
  at    TEXT NOT NULL
);

CREATE TABLE devices (
  deviceID   TEXT PRIMARY KEY,
  cursor     INTEGER NOT NULL,       -- last seq this device acknowledged
  lastSeenAt TEXT NOT NULL
);

CREATE TABLE leases (
  name   TEXT PRIMARY KEY,           -- "sweep"
  holder TEXT NOT NULL,              -- deviceID
  until  TEXT NOT NULL
);

-- State that must outlive compaction, because a rule depends on it (F133, F134, F136).
CREATE TABLE tombstones (                  -- F132: a delete is final at admission
  blindedID TEXT PRIMARY KEY,
  seq       INTEGER NOT NULL,
  expires   INTEGER NOT NULL
);
CREATE TABLE trash_marks (                 -- F134: the authoritative trash time
  blindedID TEXT PRIMARY KEY,
  at        INTEGER NOT NULL
);
CREATE TABLE log_meta (                    -- F136: a high-water mark, never recomputed
  key   TEXT PRIMARY KEY,
  value INTEGER NOT NULL
);
```

- **F17** `seq` is assigned by the DO inside the write transaction. It is the total order every
  client replays. Clients never invent one.
- **F18** The DO is the only writer of `seq`. Concurrent pushes from two Macs serialize because
  a Durable Object is single-threaded per instance — the same guarantee `withOperation` gives
  locally.

### 5.2 R2 layout

```
shares/<id>                                       M5, unchanged, plaintext
lib/<owner>/blob/<blindedID>/<revision>/<writer>  encrypted full-resolution bytes
lib/<owner>/thumb/<blindedID>/<revision>/<writer> encrypted thumbnail
lib/<owner>/orig/<blindedID>/<revision>/<writer>  encrypted pre-edit original
lib/<owner>/snap/<seq>/<writer>                   encrypted row-set snapshot
```

- **F100** The writing `deviceID` is part of every blob key. Two devices that edit the same
  capture concurrently therefore write two different keys, and neither upload fails. Without the
  writer in the path, both would target one key, the second would take a 409, and upload order —
  which is network timing — would decide a question §7.1 settles by log order. The two answers
  disagree whenever the device that uploads first is not the device that wins the log, which is
  ordinary rather than rare.

- **F19** Blob objects are immutable. A new revision writes a new key and never overwrites one.
  That is what makes a fork (§7.1) recoverable and a cache coherent.
- **F20** Deleting a capture deletes every revision under its `blindedID`. Deletion is issued by
  the sweep lease holder (§7.4), never by the server on a timer.

### 5.3 Routes

```
POST   /api/library/enroll                   owner credential → { deviceID, token }
GET    /api/library/changes?since=&limit=    → { ops[], snapshot?, head }
POST   /api/library/ops                      batch → { assigned: [{opID, seq}], head }
POST   /api/library/snapshot   { supportsV }  → { uploadURL, seq } | 409 if behind (F102)
GET    /api/library/blob/:blindedID/:rev     → ciphertext
PUT    /api/library/blob/:blindedID/:rev     → stores ciphertext, charges quota
POST   /api/library/multipart/…              → R2 multipart, §8.4
POST   /api/library/lease/sweep              → { granted, until } | 409
GET    /api/library/devices                  → the owner's device list
DELETE /api/library/devices/:deviceID        → revoke
```

- **F21** Every library route requires a device credential (F2) and rejects the owner credential
  except `enroll`.
- **F22** `PUT /blob` is create-only. An existing key returns 409, never an overwrite.

---

## 6. The sync protocol

### 6.1 Operations

An op has two parts: a plaintext **envelope** the server acts on, and an encrypted **payload** it
never parses.

- **F97** The envelope is exactly the non-ciphertext columns of §5.1: `opID`, `deviceID`,
  `blindedID`, `v`, `kind`, `requires`, `observed`. Nothing may be put there that is not already
  implied by the R2 layout or needed by a rule the server enforces, and every server-side rule
  must be expressible over the envelope alone. A requirement the server cannot check from the
  envelope is not a requirement, it is a wish.
- **F127** `kind` is in the envelope because three rules need it and none of them can read the
  payload: F106 rejects only a `delete`, F43 gates only a `delete` on the lease, and F108 dates
  eligibility from a `trash`. Applied to every op those checks would refuse ordinary writes;
  applied selectively they need exactly this field. It tells the server that a capture was
  trashed and when, which §13 records as part of what the operator learns.
- **F98** `requires` lists the blob revisions this op names, as
  `{purpose, revision, writer, capture}`, where `capture` is the `blindedID` the bytes are
  filed under and defaults to the op's own. It leaks nothing: the server already sees every blob
  key it stores (§5.2), so the list is a restatement of what is in front of it. It is what makes
  F32 enforceable.
- **F128** `capture` exists so a fork can name bytes filed under the capture it forked from.
  F35 gives the fork a fresh ULID and therefore a fresh `blindedID`, while F82 promises it
  re-uploads nothing — and without this field its dependency would resolve to a key nobody ever
  wrote, so F32 would refuse the fork forever. The same field carries into F12: the key derives
  from the blob's owning capture, so substituting the fork's `blindedID` would derive a key that
  decrypts nothing.

Decrypted, the payload is:

```json
{
  "captureID": "01J…",
  "lamport": 412,
  "deviceID": "01J…",
  "kind": "upsert | trash | restore | delete",
  "row": { "…CaptureRecord, less the device-local fields of F83…" },
  "name": "what the file is called, without a path",
  "sidecar": { "…": "…" },
  "ocr": "recognized text",
  "blobs": { "blob": 3, "thumb": 3, "orig": 1 }
}
```

- **F23** `blobs` names, for each purpose, the `{revision, writer, capture}` triple that locates
  the bytes — the same shape as a `requires` entry (F98). A client that sees a revision it lacks
  marks the capture `blobState = remote` and fetches on demand (§8.2).
- **F129** The triple lives in the row payload, not only in the envelope, because the payload is
  what a snapshot carries. F100 put the writer in the key path and F84 excludes `blob_cache`
  from what syncs, so a row recording only a revision would leave a bootstrapping client unable
  to build the R2 path or derive the key (F12) once compaction had removed the envelopes that
  once named it. A row must be sufficient on its own to reach its own bytes.
- **F24** An op is a whole row, not a field delta. Rows are small, the conflict rules (§7) are
  stated per field anyway, and a whole row makes snapshotting trivial.
- **F83** `relPath` is device-local and is never carried in an op. Each Mac has its own root,
  its own shard directories and its own history of filename collisions, so one capture
  legitimately sits at a different path on each. The op carries the capture's `name`; the
  receiving device derives its own path through `availableURL`
  (`Sources/KaptureCore/Library.swift:160`). This is also what keeps the `UNIQUE` constraint on
  `captures.relPath` (`Sources/KaptureCore/Database.swift:29`) satisfiable when a remote row
  arrives at a path this Mac has already used.
- **F84** The device-local fields are `relPath`, `fastID` (F60), `blobState`, `thumbRevision`
  and everything in `blob_cache`. They are excluded from the op payload and from snapshots, and
  each device computes its own.

### 6.2 Pull

- **F25** A client stores `cursor` — the highest `seq` it has applied — in `sync_state`.
- **F26** `GET /api/library/changes?since=<cursor>` returns ops in `seq` order, at most 500 per
  page, plus `head`. The client applies a page in one local transaction and advances `cursor`
  only when that transaction commits.
- **F27** A client whose `cursor` is older than the oldest retained op receives the newest
  snapshot instead, applies it, and continues from its `seq`. This is also how a new Mac
  bootstraps (G3).
- **F110** A snapshot is merged into the local row set, never substituted for it. A local row the
  snapshot does not mention is kept and seeded (F62) **only if the log has never acknowledged
  it**. Replacing the row set wholesale would destroy exactly the rows F70's merge exists to
  preserve; seeding indiscriminately resurrects the dead.
- **F130** Every row records whether the log has acknowledged it — set when its op is assigned a
  `seq` (F30) and carried in `sync_outbox`'s absence rather than in the payload. A row the log
  once knew, missing from a snapshot at a later `seq`, was deleted while this device was away:
  it is removed locally, not pushed back. A row the log has never seen is genuinely local and is
  seeded.
- **F131** Without F130 a deletion is undone by legal operations. A capture trashed and swept on
  one Mac, with its `delete` compacted away under F34, is simply absent from the snapshot an
  offline Mac later receives; F32 accepts the reseeded row because a metadata-only capture
  requires no blobs, and the capture returns from the dead with nothing having gone wrong
  anywhere.
- **F111** A device with a non-empty outbox pushes before it snapshots. A snapshot claims to be
  the library at seq N, so it may not contain local state the log has never seen.
- **F28** Pull runs on enable, on app foreground, every 5 minutes while running, and on demand.
  There is no push channel in v1; §14 Q1 tracks it.

### 6.3 Push

- **F29** Every local mutation that changes a row writes an op into a local `sync_outbox` table
  in the same transaction that writes the row. The outbox is the local durability boundary, the
  way `op_journal` is for file operations.
- **F30** `POST /api/library/ops` sends the outbox oldest-first, at most 100 per call. The server
  assigns `seq` and returns the mapping. Ops leave the outbox only after the server acknowledges
  them.
- **F31** `opID` is a client-generated ULID and is unique on the server (§5.1), so a batch
  retried after a lost response is idempotent.
- **F32** Blobs upload before the op that names them. The server checks every entry in the
  envelope's `requires` (F98) against R2 and rejects the op with 409 if any is absent, because
  another Mac would otherwise pull a row pointing at nothing. The check is on the envelope, not
  the payload: the server cannot read the payload's `blobs` map, and a rule stated over
  ciphertext would be unenforceable.
- **F99** A `PUT /blob` whose key exists is idempotent when the bytes match. The server compares
  the stored object's ciphertext digest with the one the client presents and answers 200, not
  409, when they agree. Without this, a PUT whose response was lost looks to the retrying client
  like a collision, and F81 would read that as a fork against itself.

### 6.4 Compaction

- **F33** A client that pulls to `head` and finds more than 10,000 ops since the newest snapshot
  uploads a fresh encrypted snapshot of its full row set at that `seq`.
- **F102** Only a complete client may snapshot. A device that skipped any op (F78) or that holds
  a non-empty outbox must not publish one, and the server refuses a snapshot from a device whose
  declared payload version is below the highest `v` in the log (F97). An incomplete snapshot
  followed by F34's deletion is silent, permanent data loss: an old client that cannot read a new
  capture would otherwise write a row set omitting it, and compaction would then delete the only
  op that carried it. A snapshot asserts "this is the whole library at seq N", and a device that
  cannot read the whole library cannot assert it.
- **F136** The highest payload version ever written is stored by the DO, not computed from the
  ops that happen to survive. Deriving it with `MAX(v)` over the op table lets compaction lower
  it: the surviving ops could all be `v1` while a compacted `v2` op is still represented in a
  snapshot, and F102's gate would then admit a `v1`-only client to write the library back down.
  A high-water mark only rises.
- **F34** The server retains the two newest snapshots and every op after the older of them.
  Everything before that is deleted.
- **F103** `opID` deduplication (F31) outlives compaction. The server keeps every `opID` for 30
  days regardless of whether its op has been compacted away, so a retry arriving after
  compaction is still recognized rather than applied twice.

---

## 7. Conflicts

Every capture row carries `(lamport, deviceID)`. A client sets `lamport = max(seen) + 1` on every
local mutation. Comparison is `lamport` first, `deviceID` lexicographically as the tie-break.
That gives a total order without clock sync.

### 7.1 Content

`markContentReplaced()` (`Sources/KaptureCore/CaptureRecord.swift:83`) already bumps
`contentRevision` and invalidates the hash, the share link, the summary and `aiState` together.
It becomes the sync rule.

- **F81** A fork is detected by revision collision, not by the §7 ordering. Two ops naming the
  same `(captureID, contentRevision)` with different `contentHash` are concurrent by
  construction, because revision N+1 always descends from N. The `(lamport, deviceID)` order
  then decides which of the two keeps the original id. Ordering alone cannot tell a fork from a
  sequential edit — it linearizes, which is its purpose — so resolving content by order alone
  would discard an annotation.
- **F35** Two devices that replace the content of one capture from the same parent revision
  **fork**. The loser by §7 ordering becomes a new capture row with a new ULID,
  `forkedFrom = <original id>`, and the same `createdAt`.
- **F82** The log is the only authority on which side forks. Both devices upload successfully,
  to keys that differ by writer (F100), and both ops reach the log; F81 detects the collision and
  the §7 ordering names the loser. The loser then pushes a fork row whose `blobs` map points at
  the bytes it already uploaded. No re-upload happens, and nothing is decided by which PUT landed
  first.
- **F101** A 409 from `PUT /blob` therefore no longer means a fork. After F99 and F100 it means
  only that this device already wrote these exact bytes, which is a retry, not a conflict. A
  client must not infer anything about forks from a blob response.
- **F36** A fork is never silent. The library window shows both, badged, with the device name and
  time that produced each.
- **F37** Pixels are never discarded to resolve a conflict. The editor already preserves pre-edit
  bytes under `.originals/`, so both sides stay reversible.

### 7.2 Status

- **F38** `status` resolves by §7 ordering, with one exception: `trashed` beats `kept` when the
  two are **concurrent** — equal `lamport`, neither having seen the other. An accidental keep is
  a nuisance; an unintended delete is data loss, so a genuine tie breaks toward the recoverable
  outcome.
- **F137** "Concurrent" is load-bearing in F38 and was missing from its first statement. A write
  with a strictly greater `lamport` decides on its own, whatever its status. Making `trashed`
  absorbing instead means F39's restore can never win: the capture is re-trashed on the next
  sync, on every Mac, forever. Implementing §7 surfaced this immediately.
- **F39** A `restore` carries a strictly greater `lamport` than the `trash` it undoes, by
  construction (F29), so a restore always wins over the trash it follows.
- **F109** A `restore` names the `seq` of the trash it undoes, in the envelope's `observed`. A
  larger `lamport` alone cannot distinguish a restore that saw a particular trash from one
  answering an earlier trash it happened to observe, and F38 makes that distinction decisive:
  without it, a stale restore can outrank a trash it never saw and resurrect a capture the person
  deliberately discarded afterwards.
- **F40** `sweeping` is local and never leaves the device. It describes a file operation in
  progress, not a state of the library.

### 7.3 Naming

- **F41** `aiState` and the name resolve together, as one unit. A row whose `acceptsName` is false
  (`Sources/KaptureCore/CaptureRecord.swift:30`) pins the name against every device's namer, not
  only its own.
- **F42** A device must not run AI naming on a capture whose row it received from another device
  with `aiState` already at `named:api` or `named:local`.
- **F94** OCR and naming run only on the device that captured the item. A device holding a row
  with `aiState = none` and no local blob leaves it alone rather than pulling bytes back to index
  them; otherwise every Mac downloads every capture to re-derive the same text. A capture whose
  Mac never finishes stays unindexed, which search shows, and any Mac can be asked to index it
  explicitly from the library window.

### 7.4 Deletion and the sweep

The 7-day trash sweep runs every 6 hours in each process
(`Sources/KaptureCore/Library.swift:442`). Two Macs running it against one logical library will
delete bytes the other just restored.

- **F43** A device must hold the `sweep` lease to issue a `delete` op or to delete a remote blob.
  The DO grants the lease for 30 minutes and it is not renewable within one pass.
- **F44** A device without the lease sweeps **its own local cache only**, evicting bytes it can
  re-fetch. It never deletes a row, a remote blob, or an `.originals/` file.
- **F45** The lease holder may delete a capture only after pulling to `head`. A row trashed more
  than 7 days ago by log time is eligible; a local `trashedAt` is not authoritative.
- **F106** A `delete` op names in its envelope the `observed` seq at which the holder last saw
  that capture as trash, and the DO rejects it if any op for that `blindedID` has landed since.
  Pulling to `head` is not sufficient on its own: a restore pushed between the holder's pull and
  its delete satisfies every other precondition in §7.4, and the lease excludes other sweepers,
  not other writers. The delete has to be conditional on the log rather than on a snapshot of it
  the holder took a moment ago.
- **F107** Blob deletion follows the accepted `delete` op. Bytes are removed only after the DO
  has admitted the op, never in anticipation of it, so a rejected delete leaves the capture
  whole.
- **F132** An admitted `delete` leaves a tombstone, and the DO refuses every later op naming that
  `blindedID`. F106 checks the log only at the moment of admission, and F107 removes bytes after
  it: in between, another Mac can upload a new revision from a stale copy and push an upsert that
  F32 accepts, and F20's prefix delete then removes bytes the log had just acknowledged. The
  writing device may afterwards evict its own copy under F52, so the capture is gone from
  everywhere while every step was legal. The tombstone closes the window by making the delete
  final at admission rather than at cleanup.
- **F133** A tombstone is checked against `blindedID`, which is in the envelope, so the DO can
  enforce it without reading anything. Tombstones are retained for as long as `seen_ops` (F103),
  which outlives compaction for the same reason.
- **F134** The DO keeps the server time of the most recent `trash` per capture, in its own
  storage rather than only in the op. F108 dates eligibility from that timestamp and F45 forbids
  trusting a local `trashedAt`, but F34 deletes old ops — so a capture trashed and left alone for
  seven days can have its own trash op compacted away, leaving no admissible evidence that it is
  eligible and no way to ever sweep it. The mark is cleared by a `restore` or a `delete`.
- **F123** A rejected delete is not retried within the same sweep pass. The holder abandons that
  capture, finishes the rest of the pass, and re-evaluates it next time with a fresh `observed`.
  Retrying immediately against a capture that is actively receiving ops would spin, and the
  rule the DO enforces is "any op since", which it must be: the DO cannot read a payload and so
  cannot tell a restore from a thumbnail re-push (F68). Starvation is bounded in practice
  because a capture eligible for sweep has been trash for seven days and backfill touches each
  capture once, but the bound is a property of the workload, not of the rule.
- **F108** Both ends of the 7-day window are server time. The eligible instant is the DO's `at`
  on the trash op (§5.1), and "now" is the DO's clock; no client timestamp enters the comparison.
  "Log time" otherwise names no particular clock, and a Mac with a skewed one would sweep early.
- **F46** `scanOriginalReferents` (`Sources/KaptureCore/Library.swift:552`) answers only for
  locally known rows. Under sync it runs over the full synced row set, and only under the lease.

---

## 8. Blobs

### 8.1 Eager

- **F47** A thumbnail is generated at capture time — long edge 512px, JPEG quality 0.7, target
  under 60 KB — encrypted and uploaded with the op. A 10,000-capture library is therefore about
  600 MB of thumbnails on every Mac, which is acceptable.

### 8.2 On demand

- **F48** `captures` gains `blobState ∈ {local, remote, fetching, missing}`. `remote` renders the
  thumbnail and fetches full bytes when the capture is opened, exported, shared, annotated or
  trimmed.
- **F49** A failed fetch leaves `blobState = remote` and surfaces a retry, never a silent empty
  editor.
- **F50** `missing` means the server has no such revision. It is reachable only through data loss
  or a partial delete, and it is shown as such.

### 8.3 Local cache

- **F51** Settings › Library sets a cache ceiling, default 20 GB, with "keep everything" as an
  option.
- **F52** Eviction is least-recently-opened. It never evicts a capture whose bytes the server has
  not acknowledged (F30), or one referenced by an unsynced `.originals/` entry.
- **F53** A capture created on this Mac is pinned local until its blob upload is acknowledged.

### 8.4 Large files

- **F54** Above 90 MB the client uses R2 multipart upload through the Worker, in parts sized by
  F87. `MAX_SINGLE_UPLOAD` (`worker/src/index.ts:21`) stays as it is for the M5 share route.
- **F87** Parts are 32 MB. Each part passes through a Worker invocation that holds it in memory,
  and a Worker has a 128 MB ceiling; a larger part plus request and response overhead leaves too
  little headroom to rely on.
- **F88** Uploading straight to R2 with presigned URLs was considered and rejected for v1. It
  takes the Worker out of the byte path, but it puts time-scoped S3-compatible credentials on the
  client and moves the transfer off the path that charges quota (F56). §14 Q7 keeps it as the
  answer if 32 MB parts prove too slow.
- **F55** A multipart upload interrupted by quit or network loss resumes from its recorded part
  list. The upload id is stored in `sync_outbox` beside the op that waits on it.

---

## 9. Quotas

- **F56** `QuotaCounter` gains `storedBytes` and `storedObjects`, charged on blob PUT and
  credited on delete, alongside the existing daily counters — which stay, because they bound the
  damage from a leaked credential.
- **F57** Default ceiling on `kapture.sh`: 100 GB stored per owner. Daily ceilings rise to 50 GB
  and 20,000 objects so a first sync completes in one night rather than one month.
- **F58** Crossing the stored ceiling fails uploads with a message naming the ceiling. The client
  keeps the capture local with `blobState = local` and retries. It never deletes to make room and
  never silently stops syncing.
- **F59** The admin dashboard shows stored bytes per owner and per device.

---

## 10. Client changes

### 10.1 Schema (migration `v7-shared-library`)

```
captures:    + lamport INTEGER NOT NULL DEFAULT 0
             + deviceID TEXT
             + forkedFrom TEXT
             + blobState TEXT NOT NULL DEFAULT 'local'
             + thumbRevision INTEGER

sync_state:    deviceID TEXT, cursor INTEGER, keyID TEXT, enabledAt DATETIME
sync_outbox:   opID TEXT PRIMARY KEY, captureID TEXT, payload BLOB,
               blobsPending TEXT, attempts INTEGER, nextAttemptAt DATETIME,
               lastError TEXT
blob_cache:    captureID TEXT, purpose TEXT, revision INTEGER, writer TEXT,
               bytes INTEGER, lastOpenedAt DATETIME
skipped_ops:   seq INTEGER PRIMARY KEY, v INTEGER, kind TEXT, noticedAt DATETIME
```

`sync_outbox` carries the same retry columns `op_journal` gained in `v6-recovery-backoff`
(`attempts`, `nextAttemptAt`, `lastError`; `ingest_jobs` spells the third `notBefore`) and uses
`recoveryBackoff` (`Sources/KaptureCore/LibraryRecovery.swift:139`) rather than a second
schedule.

### 10.2 Assumptions that stop holding

The `flock` (`Sources/KaptureCore/Library.swift:54`) stays, and stays correct: one process per
*root*. What stops holding is that one process owns the *library*. Each of these is re-derived
before it runs under sync:

- `recoverPendingOperations` (`Sources/KaptureCore/LibraryRecovery.swift:145`) replays this Mac's
  journal. Correct as-is, and it must not be extended to reason about remote rows.
- `cleanOrphanedStages` (`Sources/KaptureCore/LibraryRecovery.swift:250`) — staging is local.
  Correct as-is.
- `scanOriginalReferents` — F46.
- `sweepTrash` — F43, F44.
- The `.pending` startup sweep is local and correct as-is, but must not delete a file an outbox
  entry still names.

### 10.3 `fastID`

`fastID` is `size:mtimeNs:inode` (`Sources/KaptureCore/Library.swift:181`). Inode is meaningless
on another machine.

- **F60** `fastID` is a local drift detector. It must never be sent to the server, stored in an
  op, or compared across devices. The comment calling it "primary identity" is scoped to one Mac,
  and is corrected as part of this work.
- **F61** Identity across devices is `id` (ULID). Content equality across devices is
  `contentHash` (SHA-256), which becomes mandatory before a blob upload rather than lazy.

### 10.4 UI

- Settings › Library: enable, owner token, device name, device list with revoke, cache ceiling,
  storage used, last sync time, and the key-loss warning (F16).
- Library window: a badge for `remote` captures, a fork badge (F36), and a sync status line that
  names the failure when there is one.
- Settings › Sharing is untouched.

### 10.5 Where the code goes, and how it is tested

- **F89** Sync lives in a new `KaptureSync` target, depending on `KaptureCore`. Core depends on
  GRDB alone today (`Package.swift`); sync adds CryptoKit and `URLSession`, and putting those
  inside Core would make the library layer impossible to test without a network stack.
- **F90** The merge is a pure function from `(local rows, incoming ops)` to
  `(new rows, outbox ops, blob work)`. It refers to no `URLSession`, no GRDB and no filesystem.
  Transport and persistence call it; they are not inside it.
- **F91** The conflict rules are tested by driving two simulated devices through interleaved op
  streams, covering both orders of every pair of concurrent edits, a fork and its blob re-key
  (F81, F82), and every skew case in §11.5. §7 is the part of this spec most likely to be wrong
  and the part hardest to exercise on two real Macs, which is what F90 exists to make possible.
  `KaptureSyncTests` sits beside the existing `Tests/KaptureCoreTests`; the Worker routes are
  tested where the quota and access tests already run, against a real Workers runtime.
- **F92** CryptoKit supplies both primitives — `AES.GCM` for F13, `HKDF` for F12. No
  third-party crypto dependency is added.
- **F93** M6 targets macOS 26 Tahoe and does not carry compatibility with anything older.
  `Package.swift:6` and the README's requirement line both still say macOS 14; they move with
  this work, not after it.

---

## 11. Migration

Everything above describes the end state. This section describes reaching it from a Mac that
already holds a library and a deployment that already serves M5.

### 11.1 Seeding the log

- **F62** Seeding is an ordinary outbox fill, not a second protocol. Enabling the library writes
  one `upsert` op per live capture into `sync_outbox` in a single transaction, and the push loop
  (F30) drains it. There is no separate endpoint and no separate failure mode.
- **F63** Seeding is resumable because the outbox is durable. An interrupted seed continues on
  the next launch, and F31's `opID` uniqueness means a row enqueued twice is stored once.
- **F64** Trashed captures seed with their `trashedAt`, so the sweep (F45) sees a complete
  picture. Captures in `sweeping` do not seed: F40 keeps that state local to the device.
- **F65** Rows first, blobs newest-first. Metadata for 10,000 captures is a few megabytes and
  goes up in minutes; blobs take hours, and the captures wanted on the second Mac are the recent
  ones.
- **F66** A seed that exhausts quota (F58) stops and leaves the library coherent rather than
  truncated. F32 means an op names only blob revisions the server already holds, so the other Mac
  sees a row with no blob and a placeholder, never a row pointing at nothing.

### 11.2 Thumbnail backfill

- **F67** Every capture made before M6 has no thumbnail, because F47 generates one at capture
  time. Backfill runs through the existing ingest queue at the lowest priority, newest-first, and
  does not block seeding.
- **F68** A row may be pushed before its thumbnail exists. Its `blobs` map (F23) omits `thumb`
  until the thumbnail uploads, at which point the row is re-pushed as an `upsert` with
  `lamport + 1`. A seeded library is searchable immediately and gains thumbnails over the
  following hours.
- **F69** The cost is one extra op per pre-M6 capture. Compaction (F33) absorbs it.

### 11.3 Merging two existing libraries

Two Macs each used for a year, then both enabled, is the normal case. It is not the
empty-client bootstrap of F27.

- **F70** A Mac with local captures enrolling into a non-empty log applies the snapshot and every
  op (F27, F110), then seeds its own rows (F62). The result is the union of both libraries.
  Independently generated ULIDs do not collide, so captures taken on each Mac need no id
  reconciliation.
- **F112** Shared ids are possible anyway, and are handled rather than assumed away. Copying a
  library folder to a second Mac, or restoring one backup onto two, gives both the same capture
  ids with no randomness involved; after independent use those ids carry divergent histories.
  Where one id arrives with two lineages, the rule is F81's, generalized: compare `contentHash`
  at the highest revision both sides hold, and if they differ, the lower by §7 ordering forks
  with a fresh ULID. Equal revisions are the F81 case; unequal ones are this case, and neither
  may be resolved by taking the higher revision, which would discard the other lineage.
- **F71** A merge does not deduplicate. Two Macs that captured the same screen hold two captures
  with two ids, and they stay two. `contentHash` (F61) identifies identical bytes, but identical
  bytes are not necessarily a duplicate — the same screenshot taken deliberately twice is two
  captures — and collapsing a pair would discard one row's annotations, name and share link.
  §14 Q6 tracks a user-driven duplicate finder.
- **F138** Every row carries `parentHash`: the `contentHash` the revision was derived from, nil
  for an original. F112 cannot be implemented without it. A divergent lineage and an ordinary
  sequential edit present the identical signature — a higher revision with a different hash — so
  a rule keyed on that alone forks every edit in the library. The parent is the evidence: a row
  whose parent is not the other side's content did not descend from it.
- **F139** Absent a `parentHash` on either side, the answer is "not divergent". A false fork
  splits a capture nobody edited twice; a missed one still converges on the higher revision.
  Where the evidence is ambiguous — a multi-step descendant whose intermediate revisions this
  Mac never saw — the merge keeps both sides rather than dropping one, which is F37 applied to a
  case it did not anticipate.
- **F72** A merge is confirmed before it happens. Settings states how many local captures are
  about to be added to the library, and nothing is pushed until the person agrees. Adding 4,000
  captures to a shared library is not obviously what someone enabling a checkbox intended.
- **F73** An empty Mac joining a non-empty log is the F27 bootstrap. It is not a merge and needs
  no confirmation.

### 11.4 Server-side shape changes

- **F74** `loadOwners` reads an owner record written before M6 as having `devices: {}`,
  respecting the presence check at `worker/src/common.ts:97`. Such an owner keeps working on the
  M5 share routes and must enrol (F5, F6) before any library route answers.
- **F75** `QuotaCounter` needs no carry-forward for the stored counters. The `lib/` prefix does
  not exist before M6, so every owner's stored bytes are genuinely zero on the deployment day.
  The daily counters and their existing legacy migration (`worker/src/quota.ts:16`) are
  untouched.
- **F76** Stored counters drift when a delete or a multipart upload fails partway. The admin
  dashboard recomputes an owner's stored bytes by listing `lib/<owner>/`, and that is the only
  supported repair.

### 11.5 Version skew

Two Macs on different Kapture versions share one log, and the older one will pull ops the newer
one wrote. The server never parses an op (§5.1, §6.1), so this is entirely a client concern and
a payload change needs no Worker deploy.

- **F77** An op payload carries `v`, and a client ignores fields it does not recognize rather
  than failing the row. This extends the stance `AIState`'s decoder already takes
  (`Sources/KaptureCore/CaptureRecord.swift:22`), for the same reason: a row written by a newer
  build must degrade, not make a capture vanish.
- **F78** An op whose `kind` or `v` a client cannot apply advances the cursor anyway. The capture
  is flagged in the library as needing a newer Kapture, and its row is left unmodified. Holding
  the cursor back would let one Mac on an old version stall behind a newer one indefinitely,
  which is worse than one stale row.
- **F104** A skipped op is recorded in a local `skipped_ops` table with its `seq`, and every
  entry is re-fetched and applied when the client's supported payload version rises. Advancing
  the cursor past an op discards it otherwise: it sits behind the cursor forever, and upgrading
  never goes back for it.
- **F135** Replay is triggered by any widening of what the client can apply, not by the payload
  version alone. A client records a capability generation covering both the versions and the
  `kind`s it understands, and replays `skipped_ops` whenever that generation changes. F78 skips
  an op for an unsupported `kind` *or* an unsupported `v`, so a release that adds a `kind`
  without bumping `v` would otherwise leave the op behind a cursor that has already passed it,
  with the capture stale and restricted by F105 forever.
- **F122** A client whose `skipped_ops` name a `seq` the server no longer retains re-bootstraps
  from the newest snapshot (F27) instead of trusting its cursor, then clears those entries.
  F34 may have compacted the op away while the client sat at an old version, and F27's fallback
  only fires for a cursor *behind* the retained window — an upgraded client's cursor is at head,
  so without this it would silently keep the stale row it skipped and never correct it. F102
  guarantees the snapshot contains the capture, because only a complete client could have
  written it.
- **F105** A client must not edit, trash, sweep, or snapshot a capture whose ops it has skipped,
  and must not rewrite a row it only partly understands. When it does write a row it received,
  it preserves every field it does not recognize and sends them back unchanged. A whole-row op
  (F24) written by a client that silently dropped unknown fields would erase a newer client's
  work on the next push.

### 11.6 Downgrade and disabling

- **F79** `v7-shared-library` is additive: new tables, and new columns that are nullable or
  defaulted. A build predating it opens the database without erasing it, because
  `Database.migrate()` does not set `eraseDatabaseOnSchemaChange` — the only condition under
  which GRDB erases a database holding an unregistered migration. Not setting it is a
  requirement, not an accident.
- **F115** Opening is not the same as operating, and F79 claims only the former. A pre-sync build
  writes rows without an outbox entry (F29) and without advancing `lamport`, and its trash sweep
  deletes rows and `.originals/` files with no regard for the lease (F44). Those edits are
  invisible to the log and those deletions are unrecoverable from it. Downgrading a Mac whose
  library is synced is therefore **not supported**, and the spec says so rather than implying
  that a readable schema makes it safe.
- **F116** A build that finds a `v7` database with `hasBeenSuperseded(_:)` false but a version
  marker newer than its own runs a reconciliation scan before syncing: rows whose file content no
  longer matches their recorded `contentHash` are re-seeded as local edits with a fresh
  `lamport`, and rows whose files are gone are reported rather than propagated as deletions. This
  is best-effort recovery from an unsupported state, not a supported round trip. It cannot
  recover an `.originals/` file a downgraded sweep removed.
- **F80** Disabling the library stops push and pull and keeps every local file. It does not
  delete the remote library and does not silently fetch what is missing: captures that were
  `remote` become unavailable on that Mac and the UI says so. Settings offers to download
  everything first, which can take hours and is therefore offered rather than imposed. §14 Q5
  asks whether it should be the default.

---

## 12. Staging

### 12.1 M6a — metadata only

Rows, sidecars, OCR text and share links sync. No blobs. A capture whose bytes are on another Mac
shows a placeholder card naming that device, and opening it explains why it cannot open.

Delivers G1 in part, and forces §3, §4, §6 and §7 to be finished before any byte moves.

Acceptance: two Macs, 500 captures each. After sync both search all 1,000. Annotating on A and
renaming on B produces exactly one fork and one pinned name, with no lost row. Killing the app
mid-push loses nothing and duplicates nothing.

### 12.2 M6b — blobs

Thumbnails eager, originals on demand, cache with eviction, multipart upload.

Acceptance: a 4 GB recording library syncs to a second Mac with a 1 GB cache ceiling; every
capture opens; the cache stays under the ceiling; no capture becomes unrecoverable from the
server.

### 12.3 M6c — lifecycle

Sweep lease, delete, stored-byte quota, device revocation, snapshot compaction.

Acceptance: a trashed capture disappears from both Macs after 7 days and from R2 with it. A
revoked device is refused within one request. A log of 50,000 ops compacts, and a third Mac
bootstraps from the snapshot.

### 12.4 Copy changes

D2 keeps most of the README true. "Free, no account, no subscription" survives, because nobody
is offered an account or charged anything. "Everything lives on your Mac" survives for every user
of the public build, because F118 leaves the routes off for them.

What still changes:

- **F119** The Privacy section gains the shared library as a third opt-in path, alongside AI
  naming and sharing, and says plainly that it is off, that it requires a server the person runs
  themselves, and that enabling it uploads the library. "Two things can send your content off the
  Mac" becomes three.
- **F120** The feature is described as self-hosted, not as a service. No README text may imply
  that `kapture.sh` will store anyone else's library, because F118 means it will not, and an
  implied offer is worse than no feature.
- **F121** Settings › Library states which endpoint it will upload to before it is enabled, the
  way Settings › Sharing already does for the share endpoint.

---

## 13. Security review

Under D2 the operator and the only user are the same person, so this section is read against the
infrastructure rather than against a host with users to spy on. "The operator" below means
whoever ends up holding the storage: Cloudflare, anyone who compromises that account, and anyone
who serves it with a subpoena.

**What the operator learns anyway.** Owner name. Device ids, names and platforms. How many
captures exist, when each op was pushed, which device pushed it, and how large each ciphertext
is. Blob sizes leak capture sizes, which distinguishes a screenshot from a recording. Op timing
leaks working hours. From `kind` (F127) it also learns that a particular capture was trashed,
restored or deleted, and when — the price of F106 and F108 being enforceable at all. This is the
residue of D1. It is not fixable in v1, and it is stated rather than hidden.

**What the operator does not learn.** Capture contents, names, recognized text, source
app, window titles, file paths, or creation times (F15 blinds the ULID).

**A stolen unlocked Mac** holds the library key, the owner token and its cache: everything. That
is true today for local captures, and worse here because it also reaches the rest of the library.
F8 revokes the device credential and F113 stops the Mac enrolling a fresh one, which together end
its access to *future* library data. Neither revokes what the Mac already holds, and neither
re-encrypts the library — F9 leaves the key in the thief's Keychain, so every byte already
downloaded stays readable. The Settings copy says all of this.

**A leaked device credential** reads and writes the log and blobs but decrypts nothing. It can
push garbage ops and burn quota. F8 is the response; F56's daily counters bound the damage.

**A malicious server** can withhold ops, replay old ones, reorder them, or delete blobs. It
cannot forge a row, because it cannot produce valid GCM ciphertext. Ordering attacks are
**neither prevented nor detected** in v1: nothing authenticates `seq`, and a client has no way to
tell a withheld op from one that was never written. Claiming detection would need the per-device
signatures §14 Q2 tracks. The earlier draft of this section claimed detection; it was wrong.

**Injection paths.** Decrypted rows reach the local database, filenames and the library grid. A
row is attacker-controlled if a device credential leaks. No op carries a path (F83), so the
exposed value is `name`: it is sanitized to a single path component before it is used to build
one, and a name containing a separator or a parent reference is rejected and the op
quarantined. Paths that do arrive — the `original` inside a synced sidecar — keep going through
`checkedOriginalURL` (`Sources/KaptureCore/LibraryRecovery.swift:424`), which already refuses
anything escaping the root.

---

## 14. Open questions

- **Q1** Push delivery. v1 polls every 5 minutes (F28). A WebSocket to the `LibraryLog` DO would
  make an edit on one Mac appear on another within a second. Worth doing, not worth blocking on.
- **Q2** Signing the log. A per-device Ed25519 key would make withheld and reordered ops
  detectable, and would make revocation meaningful against a server that keeps serving a revoked
  device's ops.
- **Q3** Re-keying. F9 accepts that a revoked device can still decrypt what it holds. Rotating the
  library key means re-encrypting every object, which is a full re-upload.
- **Q4** Does the local root stay the truth when sync is on, or does the log? This spec keeps
  files as truth and treats the log as a second derived copy. The alternative — log as truth,
  files as a cache — makes eviction simpler and makes "where did my file go" much worse.
- **Q5** F80 makes the full download an offer at disable time. Should it instead be the default,
  with opting out the deliberate act? It is the honest order, and it can take a day.
- **Q6** A duplicate finder. F71 keeps a merge from collapsing identical captures, which is the
  safe choice and leaves real duplicates behind. A tool that lists same-`contentHash` pairs and
  lets a person merge or delete them is the user-driven version. Worth building only if merges
  turn out to produce many.
- **Q7** Presigned upload straight to R2, rejected for v1 by F88. If 32 MB parts through a
  Worker prove too slow for a library of recordings, this is the way out, and the question
  becomes whether scoped temporary credentials on the client are acceptable under D1.
- **Q8** *Resolved by D2.* F113 requires an existing device to approve a new one, which would
  strand someone whose only Mac was stolen. With one owner who also runs the deployment, the
  admin dashboard behind Cloudflare Access is always available as the escape, and it is reached
  from any browser rather than from a Mac. The recovery code stays a decryption key and does not
  become a credential.
- **Q9** *Resolved: D1 is kept.* Asked because D2 removed the users that D1 was written to
  protect, leaving operator and user as one person. Re-taken deliberately against the
  infrastructure threat instead — see D1 for the justification that now applies and the cost
  accepted with it. The consequences are no longer open questions: no web library, no phone
  client, and the encryption machinery in §4 and §6.1 stays and gets tested rather than trimmed.

---

## 15. Review history

The first draft was reviewed adversarially before implementation. Five findings were blocking and
are recorded here because each was a rule that read as reasonable and could not work:

1. Row keys were derived from `captureID`, which is only inside the ciphertext the key opens
   (F95). Fixed by deriving from `blindedID`.
2. F32 required the server to reject ops naming missing blobs, over a `blobs` map the server
   cannot read (F98). Fixed by putting the dependency list in the plaintext envelope.
3. Fork ownership was settled by log order in F35 and by upload order in F82, which disagree
   whenever the first uploader is not the log winner (F100). Fixed by putting the writer in the
   blob key so uploads never race.
4. An old client could skip an op it could not parse, then publish a snapshot omitting that
   capture, and compaction would delete the only copy (F102). Fixed by refusing snapshots from
   incomplete clients.
5. A sweep could delete a capture restored between its head pull and its delete (F106). Fixed by
   making the delete conditional on the log.

Three further findings — snapshot application order, re-enrolment after revocation, and the
downgrade claim — are addressed by F110, F113 and F115. Two claims in §13 were overstated and
have been corrected rather than defended.

A second pass reviewed those fixes, because a fix written in one sitting is the least-examined
text in a spec. It found seven more, and they are recorded for the same reason:

6. F12 still derived a row key from `revision`, which is inside the payload — the first
   finding's mistake one layer down (F126). Rows now derive from `opID`.
7. `kind` was needed by three server-side rules and was not in the envelope (F127). The
   implementation had already added it; the spec had not.
8. A fork could not name the bytes F82 promised it would not re-upload, because its new
   `blindedID` addressed a key nobody wrote (F128). This was created by the fix for finding 3.
9. Merging a snapshot resurrected captures deleted while a device was offline (F130, F131).
10. Snapshots lost the blob writer that F100 had just made part of the key path (F129).
11. An admitted delete did not fence later writes, so F20's cleanup destroyed acknowledged
    bytes (F132).
12. Compaction could erase the trash timestamp F108 dates eligibility from, leaving a capture
    permanently unsweepable (F134).

Findings 6, 8 and 10 are all D1's shape: a value the reader needs, placed where the reader
cannot reach it. That is the standing cost of the encryption decision (§14 Q9), and it is the
reason a third review pass is expected rather than optional.
