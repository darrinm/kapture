# Getting the shared library into live use

Every requirement in [`SHARED-LIBRARY.md`](SHARED-LIBRARY.md) is implemented and tested. The
feature cannot currently be switched on, and nothing in it has run against real Cloudflare. This
is the order to fix that.

## Ground rules

**Each stage exits on a demonstration, not a test count.** Four reviews of this branch each found
something already called done, because the tests asked whether a component worked rather than
whether the feature existed. A stage is finished when the thing it promises has been seen
happening, once, by hand.

**Keep everything local until the server has earned trust.** Eviction (F51) is the only mechanism
that makes local data depend on the server: until it runs, every capture is still a file in
`~/Pictures/Kapture` and the worst case is wasted bandwidth. Set the cache ceiling to *keep
everything* for stages 1–5 and do not lower it until stage 6.

**Back up the key before the first upload.** F16 is not a formality: with the key gone the library
is unreadable by everyone including whoever runs the server. The recovery code must exist, be
written down off-machine, and be tested by actually restoring from it (stage 5) before the real
library is ever enabled.

---

## Stage 0 — Fix what is known broken ✅

- `LibraryService.sweepNow` passes the cursor as `opsSinceSnapshot`. They are different
  quantities, so once the cursor passes 10,000 every sweep attempts a snapshot. Track ops since
  the last snapshot, or drop the count and trigger on the log's own `oldestRetained`.

*Exit:* the sweep runs twice against a log with a cursor above 10,000 and claims one snapshot,
not two. **Met** — `sync_state` gained `lastSnapshotSeq` (migration v8), `SyncIdentity` derives
`opsSinceSnapshot` from it, and a test drives exactly that sequence.

## Stage 1 — Make it switchable on ⚠️ built, not yet exercised

The blocker. Nothing outside `KaptureSync` calls `enrol`, `createKey` or `adoptKey`, so the
Settings toggle currently moves the library into `.locked` and stops.

Settings › Shared Library needs:

- **Create a library** — generates the key (F11), shows the recovery code once (F85), requires a
  "I have written this down" confirmation before the first upload. This screen is the one place
  where the F16 warning has to be unmissable.
- **Join a library** — paste the owner token, enrol (F5/F113), show this Mac's fingerprint and
  the waiting-for-approval state (F86: *locked* and *empty* must never look alike).
- **Enter a recovery code** — the only path for a Mac that cannot get the key from iCloud
  Keychain, and the escape when Keychain loses it.
- **Devices** — list, show fingerprints, approve a pending Mac (F125), revoke (F8).

*Exit:* on one Mac, from a clean install, the toggle goes from off to `.ready` and the recovery
code is written on paper.

**Where this actually stands.** `SharedLibraryPane` exists, and the recovery code round-trips in
tests, including that a mistyped code is refused rather than silently adopted and that a Mac
keeps the key it had when one is.

The first version of this note said the pane rendered "all four states". It did, in a
screenshot, but the setup screen was unreachable in the running app: with the toggle on, a Mac
with no credential went straight to `.locked`, and the harness that took the screenshot never
started the service. This was exactly the mistake the ground rules above describe, made in the
same document that names it. A review of the merged branch caught it. `.needsSetup` now exists,
the pane and the service read one function for which screen a Mac is on, and a test starts the
real service on a fresh Mac and asserts it lands on setup.

The exit criterion has still not been met: reaching `.ready` needs a server to enrol against, so
this stage finishes together with stage 3.

## Stage 2 — Make it sync a library rather than a trickle

**Status: built and tested against fakes.** Status and edit publishing was closed by the review
fixes (F148). Seeding and thumbnails are now in the client:

- **Seeding (F62–F66, F72, F73).** `SyncStore.seed` enqueues one op per live capture (trashed
  captures as `trash`) and queues its bytes at priority 1, in one transaction. A creating Mac
  seeds on its first sync. A joining Mac with local captures shows the count in Settings and
  seeds when the person presses "Add them to the library". A Mac with no local captures marks
  itself seeded without asking.
- **Thumbnails (F47, F67).** `Thumbnailer` makes a 512px JPEG, using the frame at one second for
  recordings. The upload drain uploads it after the bytes, so new captures and seeded ones take
  the same path. Each sync fetches missing thumbnails, and the grid draws a capture with no
  local file from its synced thumbnail.

Tests: `SeedingAndThumbnailTests.swift` (11 tests) runs seeding, gating, upload order, thumbnail
upload and thumbnail fetch through `LibraryService` and `SyncStore`. The recording test uses a
Motion JPEG movie, because the hardware H.264 encoder fails after a few frames in a
command-line test process.

*Exit:* enable on a Mac with an existing library; every capture appears in the outbox, drains,
and `/api/library/usage` reports bytes in the right order of magnitude. This needs the deployed
Worker, so it is checked in stage 4.

## Stage 3 — Deploy the Worker

1. `wrangler deploy` with the `v2-library-log` Durable Object migration.
2. Leave `LIBRARY_OWNERS` unset and confirm every `/api/library/*` route 404s (F118). This is the
   default-off behaviour and it is worth seeing rather than assuming.
3. Set `LIBRARY_OWNERS` to a **throwaway** owner and exercise the routes by hand against real R2:
   enrol, push an op, pull it back, PUT and GET a blob, take the sweep lease.
4. Document the routes, `LIBRARY_OWNERS` and the DO migration in `worker/README.md`, which
   currently mentions none of it.

*Exit:* a curl transcript showing an op round-tripping through real R2 and a real Durable Object.

## Stage 4 — One Mac, a copy of the library

Point a Mac at a **copy** of `~/Pictures/Kapture`, not the real one.

Watch for what Miniflare cannot tell you: R2 conditional-put semantics under F22/F99, Durable
Object SQLite behaviour as the op table grows, the multipart path at a real recording's size
(nothing has ever moved a file over 90 MB), and whether the stored-byte counter matches what R2
actually holds — `/api/library/usage?reconcile=1` answers that directly.

*Exit:* the copy is fully seeded, `reconcile=1` agrees with the counter, and a >90 MB recording
has uploaded and downloaded intact.

## Stage 5 — Two Macs

Enrol the second Mac, approve it from the first, and walk the cases the spec argues about:

- Convergence: a capture taken on A appears on B, searchable, with its thumbnail.
- Fetch on demand: opening a `remote` capture on B pulls the bytes (F48).
- **A deliberate conflict.** Edit the same capture on both while B is offline. Confirm the fork
  appears on both Macs with *the same id* (F140) and neither edit is lost.
- **A deliberate restore race.** Trash on A, restore on B, then let A sweep. The delete must be
  refused (F106).
- **Recovery.** Wipe the key from a Mac's Keychain and restore the library from the written-down
  recovery code. If this does not work, stop — nothing after it is safe.

*Exit:* all five observed, including the two that are supposed to fail safely.

## Stage 6 — The real library

Only now point a Mac at the real `~/Pictures/Kapture`. Seed it, let it settle, then enable
eviction by lowering the cache ceiling on the *second* Mac first — never on the Mac holding the
only copy.

Watch for a week: `lastError` on both Macs, stored bytes against the 100 GB ceiling, and whether
the outbox ever stops draining.

---

## Deliberately not in this plan

- **Compaction (F34).** Only `forgetOpsForTest` exists, so the log grows without bound. Nothing
  breaks until the op table is large, and it is easier to implement once there is real data to
  size it against.
- **Library-grid badges** for `remote` and forked captures (F36, F48). Cosmetic until stage 5
  produces a fork.
- **Admin device-approval UI** (F124). The API works; the dashboard does not show it. Stage 1's
  in-app approval covers the two-Mac case.
- **Disable-with-download (F80).** Unimplemented, and the ground rule about keeping everything
  local is what stands in for it until it exists.
- **Any non-Mac client.** Foreclosed by D1 and re-confirmed (§14 Q9).

## Backing out

Stages 0–3 touch nothing a Mac depends on. From stage 4 on, the way back is the same at every
point: turn the toggle off. Local files are never removed by disabling, and while the cache
ceiling stays at *keep everything* the library on disk is exactly what it would have been had the
feature never been enabled. That property is worth more than any of the code in this branch, and
it is the reason eviction comes last.
