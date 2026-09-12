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
- A web library. §4 rules it out: the server holds ciphertext and cannot render a grid.
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

### D2 — An owner, several devices; no signup

The unit of identity stays the owner name already in the owner table. It gains a set of
per-device credentials (§3). There is no email, no password, and no self-serve signup: on
`kapture.sh` the admin mints an owner as they do today, and a self-hosted deployment does the
same.

This is not an account, but it is close enough that the README must stop saying "Everything
lives on your Mac" without qualification. §12.4 lists the copy changes.

### D3 — Metadata everywhere, thumbnails everywhere, originals on demand

Every Mac holds the full row set and a thumbnail for every capture. Full-resolution stills and
recordings are fetched when opened and cached under a ceiling (§8.3).

Full replication was rejected: a recording library is tens to hundreds of gigabytes and a
laptop should not need all of it. Metadata-only was rejected as an end state, but is the first
shipping stage (§12.1) because it forces identity and conflict resolution to be solved before
any byte moves.

### D4 — Stored bytes are quota'd, and someone pays for them

R2 storage is roughly $0.015/GB-month with no egress charge, so a 100 GB library is about
$1.50/month. The daily transfer quotas that protect against a leaked share token
(`worker/src/quota.ts:4`) do not describe a library, and a first sync at 2 GB/day would take
weeks.

`kapture.sh` gets a default 100 GB stored-byte ceiling per owner, and the cost of running it is
the author's. Self-hosting stays a first-class path — `worker/README.md` already documents it,
and a shared library changes nothing about that.

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
  silently: the client generates a `deviceID`, posts it with the owner credential once, and
  receives a device credential.
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
- **F12** Per-object keys are derived, never reused:
  `HKDF-SHA256(libraryKey, salt = deviceID, info = "kapture/v1/" + purpose + "/" + captureID +
  "/" + revision)`, where `purpose` is `blob`, `thumb`, `orig` or `row`.
- **F13** Encryption is AES-256-GCM with a fresh random 96-bit nonce per object, the nonce
  prefixed to the ciphertext. Deriving by revision (F12) means a re-encrypted revision never
  reuses a key/nonce pair even if the RNG repeats.
- **F14** The key carries a `keyID` — the first 8 bytes of `SHA-256(libraryKey)` — stored with
  every object. A client holding the wrong key reports "this library was made with a different
  key" instead of decryption noise.

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
  deviceID   TEXT NOT NULL,
  blindedID  TEXT NOT NULL,
  ciphertext BLOB NOT NULL,
  bytes      INTEGER NOT NULL,
  at         TEXT NOT NULL
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
```

- **F17** `seq` is assigned by the DO inside the write transaction. It is the total order every
  client replays. Clients never invent one.
- **F18** The DO is the only writer of `seq`. Concurrent pushes from two Macs serialize because
  a Durable Object is single-threaded per instance — the same guarantee `withOperation` gives
  locally.

### 5.2 R2 layout

```
shares/<id>                              M5, unchanged, plaintext
lib/<owner>/blob/<blindedID>/<revision>  encrypted full-resolution bytes
lib/<owner>/thumb/<blindedID>/<revision> encrypted thumbnail
lib/<owner>/orig/<blindedID>/<revision>  encrypted pre-edit original
lib/<owner>/snap/<seq>                   encrypted row-set snapshot
```

- **F19** Blob objects are immutable. A new revision writes a new key and never overwrites one.
  That is what makes a fork (§7.1) recoverable and a cache coherent.
- **F20** Deleting a capture deletes every revision under its `blindedID`. Deletion is issued by
  the sweep lease holder (§7.4), never by the server on a timer.

### 5.3 Routes

```
POST   /api/library/enroll                   owner credential → { deviceID, token }
GET    /api/library/changes?since=&limit=    → { ops[], snapshot?, head }
POST   /api/library/ops                      batch → { assigned: [{opID, seq}], head }
POST   /api/library/snapshot                 → { uploadURL, seq }
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

An op is one encrypted row payload for one capture at one Lamport time. The server stores the
ciphertext and never parses it. Decrypted, an op is:

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

- **F23** `blobs` names the revision available for each purpose. A client that sees a revision it
  lacks marks the capture `blobState = remote` and fetches on demand (§8.2).
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
  snapshot instead, applies it wholesale, and continues from its `seq`. This is also how a new
  Mac bootstraps (G3).
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
- **F32** Blobs upload before the op that names them. An op naming a revision the server does not
  hold is rejected with 409, because another Mac would otherwise pull a row pointing at nothing.

### 6.4 Compaction

- **F33** A client that pulls to `head` and finds more than 10,000 ops since the newest snapshot
  uploads a fresh encrypted snapshot of its full row set at that `seq`.
- **F34** The server retains the two newest snapshots and every op after the older of them.
  Everything before that is deleted.

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
- **F82** A fork re-keys its blobs. The losing device's `PUT` to
  `blob/<blindedID>/<revision>` is refused with a 409 by F22, which is the same collision seen
  at the blob layer. That device then uploads under the forked capture's own `blindedID` (F15)
  and pushes the fork row. The fork stays local until that upload succeeds, so no row ever names
  bytes the server does not hold (F32).
- **F36** A fork is never silent. The library window shows both, badged, with the device name and
  time that produced each.
- **F37** Pixels are never discarded to resolve a conflict. The editor already preserves pre-edit
  bytes under `.originals/`, so both sides stay reversible.

### 7.2 Status

- **F38** `status` resolves by §7 ordering, with one exception: `trashed` from any device beats a
  concurrent `kept`. An accidental keep is a nuisance; an unintended delete is data loss.
- **F39** A `restore` carries a strictly greater `lamport` than the `trash` it undoes, by
  construction (F29), so a restore always wins over the trash it follows.
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
blob_cache:    captureID TEXT, purpose TEXT, revision INTEGER,
               bytes INTEGER, lastOpenedAt DATETIME
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
  op (F27), then seeds its own rows (F62). The result is the union of both libraries. ULIDs do
  not collide, so no id reconciliation is required.
- **F71** A merge does not deduplicate. Two Macs that captured the same screen hold two captures
  with two ids, and they stay two. `contentHash` (F61) identifies identical bytes, but identical
  bytes are not necessarily a duplicate — the same screenshot taken deliberately twice is two
  captures — and collapsing a pair would discard one row's annotations, name and share link.
  §14 Q6 tracks a user-driven duplicate finder.
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

### 11.6 Downgrade and disabling

- **F79** `v7-shared-library` is additive: new tables, and new columns that are nullable or
  defaulted. A build predating it opens the database, ignores what it does not know, and keeps
  working, because `Database.migrate()` does not set `eraseDatabaseOnSchemaChange` — the only
  condition under which GRDB erases a database that holds an unregistered migration. Not setting
  it is therefore a requirement rather than an accident. `hasBeenSuperseded(_:)` is available if
  a downgraded build should say so out loud.
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

The README's "Free, no account, no subscription", "Everything lives on your Mac", and the Privacy
section's "Two things can send your content off the Mac" all become false the moment this ships
enabled. They are edited in the same release, not after it. The Privacy section gains the shared
library as a third opt-in path and states D1 and §13 plainly.

---

## 13. Security review

**What the server operator learns anyway.** Owner name. Device ids, names and platforms. How many
captures exist, when each op was pushed, which device pushed it, and how large each ciphertext
is. Blob sizes leak capture sizes, which distinguishes a screenshot from a recording. Op timing
leaks working hours. This is the residue of D1. It is not fixable in v1, and it is stated rather
than hidden.

**What the server operator does not learn.** Capture contents, names, recognized text, source
app, window titles, file paths, or creation times (F15 blinds the ULID).

**A stolen unlocked Mac** holds the library key and its cache: everything. That is true today for
local captures, and worse here because it also reaches the rest of the library. F8 revokes the
device's server access. It cannot revoke what the Mac already holds, and the Settings copy says
so.

**A leaked device credential** reads and writes the log and blobs but decrypts nothing. It can
push garbage ops and burn quota. F8 is the response; F56's daily counters bound the damage.

**A malicious server** can withhold ops, replay old ones, or delete blobs. It cannot forge a row,
because it cannot produce valid GCM ciphertext. Ordering attacks are detectable but not prevented
in v1; §14 Q2 tracks signing the log.

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
