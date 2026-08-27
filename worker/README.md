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

This is already done for kapture.sh: the Worker is deployed on the custom domain, with the
`kapture-shares` bucket and the `QUOTAS` namespace whose id is in `wrangler.jsonc`. Adding a
friend means minting one more token and re-putting `TOKENS` with both entries — the secret is
the whole map, so a put that lists only the new owner would revoke everyone else.

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

`TOKENS` is a JSON map of owner → sha256 hex of that owner's bearer token. Only
the hash is ever stored server-side, so a leaked deployment reveals no token.
Adding a friend means minting another token and re-putting the secret; removing
one means dropping their entry. Each owner gets a daily quota (2 GB, 500
objects) so a leaked token costs a day, not the account.

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
