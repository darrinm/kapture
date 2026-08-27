# Security

## Reporting

Please report security issues privately: open a [private vulnerability
report](https://github.com/darrinm/kapture/security/advisories/new) on this repository, or
email darrin@massena.com. Please don't open a public issue for anything exploitable.

This is a personal project maintained in spare time. You will get an acknowledgement, and a fix
if the issue is real, but no bounty and no SLA.

## What's in scope

- **The share backend** (`worker/`) — the code running at kapture.sh and in anyone's own
  deployment. Auth bypass, reading another owner's uploads, escaping the viewer's CSP,
  injection through a filename, or anything that turns a share link into script execution on
  the kapture.sh origin.
- **The app** — anything that leaks capture contents somewhere the user didn't ask for, mishandles
  the Keychain-stored API tokens, or lets a downloaded update run unverified.

Out of scope: the app is deliberately unsandboxed and holds Screen Recording permission, so
"a local process with your privileges can read your captures" is the design, not a
vulnerability. Same for "the share link is unguessable but public" — that is what a share link
is.

## Design notes worth knowing before you look

- Share tokens are stored server-side only as SHA-256 hashes and compared in constant time. The
  plaintext token exists in the client's Keychain and nowhere else.
- A share link carries no authorization of its own; it is a capability. Anyone with the link
  can fetch the file. Deleting the share is the only revocation.
- Filenames arrive from the client in a header. They are allowlist-sanitized on the way in and
  escaped again at every point they are rendered.
- Uploads are limited to an allowlist of image and video content types, capped at 95 MB, and
  metered by a daily per-owner quota so a leaked token costs a day rather than an account.
- The viewer page runs no JavaScript, under `default-src 'none'`. The raw endpoint is served
  `nosniff` and sandboxed, so a file that lies about its type still cannot execute in the
  kapture.sh origin.
- Updates are verified twice: an EdDSA signature checked by Sparkle against the public key in
  `Info.plist`, and macOS's own Developer ID signature and notarization checks. A build with no
  public key configured disables updates entirely rather than accepting an unsigned one.
