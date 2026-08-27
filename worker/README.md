# kapture.sh — share backend

A single Cloudflare Worker plus an R2 bucket. It stores a capture, hands back a
permanent unguessable link, and serves a no-JavaScript viewer for it. There are
no accounts: a share is authorized by a bearer token that the app holds, and the
link itself is the only capability a recipient needs.

```
POST /api/upload      authorization: Bearer <token>, content-type: image/png…,
                      x-filename: <name>   → { id, url }
GET  /api/list        → the caller's own shares (owner comes from the token)
DELETE /api/:id       → remove a share (owner, or ADMIN_OWNER)
GET  /:id             → viewer page
GET  /:id/raw         → the bytes, sandboxed + immutable
GET  /download        → 302 to the latest GitHub release asset
GET  /appcast.xml     → Sparkle feed
```

## Running your own

Nothing here is specific to kapture.sh except three values. Fork, then:

1. In `wrangler.jsonc`, set `routes` to your own domain (or delete it and use the
   `*.workers.dev` URL wrangler gives you), `ADMIN_OWNER` to your own owner name, and
   `RELEASES_BASE` to your fork's releases.
2. Follow **Deploy** below — the `kv namespace create` step prints the id that replaces the one
   in `wrangler.jsonc`.
3. Point Kapture at it:
   `defaults write sh.kapture.app shareEndpoint https://your-domain.example`, then paste your
   token into Settings › Sharing. The endpoint must be https — Kapture ignores anything else
   rather than send a bearer token in the clear.

Your deployment is entirely separate: your own bucket, your own tokens, your own quotas.

## Develop

```sh
npm install
npm test          # 12 vitest-pool-workers tests, no network
npm run typecheck
npm run dev
```

## Deploy (one-time setup)

Wrangler needs credentials that can write Workers, KV, R2 and the kapture.sh
zone. The simplest path is an interactive login, which supersedes any
`CF_API_TOKEN`/`CLOUDFLARE_API_TOKEN` already in the environment:

```sh
unset CF_API_TOKEN CLOUDFLARE_API_TOKEN
npx wrangler login
```

An API token works too, if it carries *Workers Scripts: Edit*, *Workers KV
Storage: Edit*, *Workers R2 Storage: Edit* and *Zone: Edit* for kapture.sh.

Then:

```sh
npx wrangler r2 bucket create kapture-shares
npx wrangler kv namespace create QUOTAS      # paste the id into wrangler.jsonc
node scripts/mint-token.mjs darrin           # prints the token + its hash
npx wrangler secret put TOKENS               # {"darrin":"<hash>","friend":"<hash>"}
npx wrangler deploy
```

This is already done for kapture.sh. Adding a friend afterwards is the dashboard's job, below —
`TOKENS` only seeds the first deployment.

## The dashboard

`https://kapture.sh/admin` — behind Cloudflare Access, so signing in is an identity rather than
a pasted string. The Access application allows one email address and sends a one-time PIN.

It lists everyone who has a token, what they have stored, and what they have used today; mints
a token for a new person (shown once, never stored); revokes one; and deletes individual
shares. It runs without any JavaScript — plain forms under the same `script-src 'none'` policy as the
viewer.

Access stops anonymous requests at the edge, but the Worker verifies the JWT itself rather than
trusting the header, because anything reaching the Worker by another route could set that header
freely: RS256 signature against the team's published keys, issuer must be the team, and the
audience must be *this* application — Access mints tokens for every app in an account.

Configured by three vars in `wrangler.jsonc`: `ACCESS_TEAM_DOMAIN`, `ACCESS_AUD` (the
application's AUD tag, under Additional settings → AUD tag) and `ADMIN_EMAIL`. Remove the first
two and the dashboard falls back to signing in with the admin's share token, which is how it
worked before and how a fork with no Zero Trust plan can still use it.

**Where the owner table lives.** A Worker cannot write its own secrets, so the live table is a
KV entry, not the `TOKENS` secret. On a deployment that has never written one, the secret is
read once to seed it and ignored afterwards — which means that after the first mint or revoke,
editing `TOKENS` does nothing. Manage people through the dashboard from then on.

Revoking stops new uploads. It does **not** retract links the person already made: a share link
is a capability, and the id is the authorization. Delete their shares as well if that matters.

## Giving the token to Kapture

Paste it into Settings › Sharing, or hand it to the app on stdin:

```sh
printf %s "$TOKEN" | /Applications/Kapture.app/Contents/MacOS/Kapture --set-share-token
```

Either way *the app* writes the Keychain item. An item created by another tool (`security
add-generic-password`, say) carries an ACL that doesn't include Kapture, and every read then
blocks on a permission dialog.

To check the whole path without touching the UI:

```sh
Kapture.app/Contents/MacOS/Kapture --share-test some.png --delete
```

Each owner gets their own daily quota (2 GB, 500 objects), so a leaked token costs a day rather
than the account, and one person cannot exhaust another's.

## Design notes

- **Links are permanent.** No expiry, because a link pasted into a thread that
  dies six months later is worse than an R2 bill measured in cents. Deletion is
  an explicit owner action.
- **The viewer runs no JavaScript** and is served under a deny-everything CSP.
  `/:id/raw` is `nosniff` + `sandbox`, so even a file that lies about its type
  cannot execute in the kapture.sh origin.
- **Filenames are attacker-controlled** (they come from the client in a header),
  so they are allowlist-sanitized on the way in and escaped again at every
  render site: title, og:title, img alt, footer, Content-Disposition.
- **Updates are not proxied.** `/download` and the Sparkle appcast redirect to
  GitHub release assets, so the Worker never serves large immutable binaries.
