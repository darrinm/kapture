# Kapture

A screen capture app for macOS: take the shot, triage it in the corner, annotate it, record
your screen, and find any of it again months later by the words that were on screen. Everything
lives on your Mac.

Free, no account, no subscription. It replaced CleanShot X for the person who wrote it.

> **Status: personal project, early.** It is used daily on the author's machines and the
> releases are signed and notarized, but this is one person's tool, not a product. Interfaces
> and file layout can still change under you.

## What it does

**Capture** — ⌘⇧4 for an area, ⌘⇧3 for a display, ⌥⇧4 to repeat the last region. The screen
freezes while you drag, with a magnifier that shows pixels and the hex value under the
crosshair. Press space to switch to window mode and click the window you want; it captures the live window
with its rounded corners and a transparent background. Also: all displays at once, a self-timer, and ⌘⇧2 to
pull the *text* off the screen straight to the clipboard.

**Triage** — each capture lands as a card in the corner instead of littering your desktop.
Keep it (⌘W), copy it (⌘C), save it (⌘S), edit it (⌘E), share it (⌘U), or throw it away (⌘⌫ or
a flick toward the screen edge). Discarding is one gesture, not a dialog, because the common
case is three shots of the same thing and only the best one is worth keeping. Anything
discarded sits in a trash for seven days.

**Annotate** — arrows, boxes, ellipses, lines, freehand, text, step counters, a highlighter, and
blur or pixelate for the parts that shouldn't leave your machine. Crop with the usual aspect
ratios. Pinch or ⌘+/⌘− to zoom, ⌘0 to fit, ⌘1 for actual size.

A redaction covers what is under it and takes it out of the search index too — blur a password
and it stops being findable in your library, not just in the file.
Every layer stays editable and every edit is undoable; the untouched original is always kept
aside, so a crop is never permanent.

**Record** — an area, a window, or a whole display to MP4, with system audio and your
microphone. Pause and resume mid-take. Clicks and keystrokes can be drawn into the movie. Trim
the ends afterwards, or export the whole thing as a GIF.

**Remember** — every capture is read on-device and its text indexed, so you can search your
library for the error message you screenshotted in March. Filter by app, kind or date. With
your own Anthropic API key, captures also get named by what's actually in them instead of
`Screenshot 2026-03-14 at 11.42.13`.

**Pin** — float any capture on top of everything while you work from it.

**Share** — ⌘U uploads a capture and copies a link. See [Sharing](#sharing) — it's optional,
off until you configure it, and you can run the server yourself.

## Install

Download the latest DMG from [kapture.sh/download](https://kapture.sh/download) — or from
[Releases](https://github.com/darrinm/kapture/releases) — and drag Kapture to Applications. It
is signed with a Developer ID and notarized, so it opens without a Gatekeeper detour. After
that it updates itself.

Requires macOS 14 or later on Apple silicon.

To build it yourself instead:

```sh
git clone https://github.com/darrinm/kapture.git
cd kapture
scripts/bundle.sh
cp -R dist/Kapture.app /Applications/
open /Applications/Kapture.app
```

That needs Xcode (the command line tools alone aren't enough — Kapture uses ScreenCaptureKit
and the macOS SDK). `bundle.sh` signs with whatever identity you have; with none it falls back
to ad-hoc signing, which works but makes macOS re-ask for Screen Recording permission after
every rebuild, and leaves the updater switched off.

## Permissions

Kapture asks for as little as it can, as late as it can.

| Permission | When | Why |
| --- | --- | --- |
| Screen Recording | at first launch | required to capture anything at all |
| Microphone | first recording with the mic on | recording your voice |
| Accessibility | optional, offered when relevant | keyboard shortcuts on the hovered card, and drawing keystrokes into a recording |

It is not sandboxed and does not run a background service beyond its own menu bar item. Left
alone it talks to the network for one thing only: checking once a day whether a new version has
been released (Sparkle, against kapture.sh/appcast.xml). Everything else — AI naming, sharing —
happens only when you ask for it.

## Sharing

Sharing is off until you give Kapture a token. There are no accounts: a link is a long random
id, it never expires, and deleting it is an explicit action.

You give it that token once. It is stored in iCloud Keychain, so your other Macs pick it up on
their own and there is nothing to paste into the second one — the same goes for the Anthropic key
used for naming. Nothing about them leaves the Keychain: iCloud Keychain is end-to-end encrypted,
and the server only ever holds a hash of the token. If you would rather a Mac not have them,
signing that Mac out of iCloud Keychain is what stops it.

The server is a Cloudflare Worker with R2 storage, KV for credentials, and Durable Objects
for atomic upload quotas, in [`worker/`](worker/). The author runs one at `kapture.sh`; you can deploy your own in a few
minutes and point Kapture at it (Settings › Sharing reads the endpoint from the
`shareEndpoint` default). See [`worker/README.md`](worker/README.md) for the deploy steps and
the security posture: tokens are stored only as hashes, uploads are limited to an allowlist of
image and video types with a daily per-owner quota, and the viewer page runs no JavaScript
under a deny-everything CSP.

## Privacy

Captures are files in a folder you choose (`~/Pictures/Kapture` by default), with a SQLite
index in Application Support. Nothing is uploaded, phoned home, or analyzed remotely by
default.

The updater asks kapture.sh once a day whether there is a newer version; that request carries
nothing about you or your captures, and Settings can turn it off.

Two things can send your *content* off the Mac, both opt-in and both visible:

- **AI naming**, if you add an Anthropic API key: the capture image and its recognized text go
  to the Anthropic API to produce a filename. Without a key, naming happens on-device.
- **Sharing**, when you press ⌘U: that capture is uploaded to the endpoint you configured.

Text recognition, search indexing, and everything else happens locally. Both API keys live in
the Keychain, never in preferences.

## Development

```sh
scripts/bundle.sh          # build + assemble + sign Kapture.app
scripts/test.sh            # swift test
cd worker && npm test      # the share backend, against a real Workers runtime
```

Warnings are errors in this project — `bundle.sh` builds with `-warnings-as-errors`, and CI
does too. Both scripts unset an inherited `SDKROOT` first; if your shell exports one pointing
at a different SDK than your Xcode, the Swift build fails with "this SDK is not supported by
the compiler."

Layout: `KaptureCore` (library, database, sharing) · `KaptureCapture` (ScreenCaptureKit) ·
`KaptureEditor` (annotation) · `KaptureRecording` · `KaptureIntelligence` (OCR, naming) ·
`KaptureDesign` (tokens) · `Kapture` (the app) · `worker` (the share backend).

Releases are cut by tagging — see [`docs/RELEASING.md`](docs/RELEASING.md). Milestone-by-
milestone history is in [`docs/STATUS.md`](docs/STATUS.md).

## Contributing

This is a personal project shared in the hope it's useful, not a product with a roadmap owed to
anyone. Issues describing a bug you hit are welcome. Please open an issue before a pull
request — an unsolicited large PR will probably sit unmerged, and that's a waste of your
evening. See [CONTRIBUTING.md](CONTRIBUTING.md).

Security issues: please don't file them publicly — [SECURITY.md](SECURITY.md).

## Built with

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite, MIT
- [Sparkle](https://github.com/sparkle-project/Sparkle) — in-app updates, MIT

Full license texts: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). They ship inside the app
bundle too, in `Contents/Resources`.

## License

MIT — see [LICENSE](LICENSE).
