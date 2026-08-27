# Kapture

A screen capture app for macOS: take the shot, triage it in the corner, annotate it, record
your screen, and find any of it again months later by the words that were on screen. Everything
lives on your Mac.

Free, no account, no subscription. It replaced CleanShot X for the person who wrote it.

> **Status: personal project, early.** It is used daily on the author's machines, but there is
> no signed release yet — you build it yourself (see below). Interfaces and file layout can
> still change under you.

## What it does

**Capture** — ⌘⇧4 for an area, ⌘⇧3 for a display, ⌥⇧4 to repeat the last region. The screen
freezes while you drag, with a magnifier that shows pixels and the hex value under the
crosshair. Press space to switch to window mode and click the window you want; it captures with
its shadow and a transparent background. Also: all displays at once, a self-timer, and ⌘⇧2 to
pull the *text* off the screen straight to the clipboard.

**Triage** — each capture lands as a card in the corner instead of littering your desktop.
Keep it (⌘W), copy it (⌘C), save it (⌘S), edit it (⌘E), share it (⌘U), or throw it away (⌘⌫ or
a flick toward the screen edge). Discarding is one gesture, not a dialog, because the common
case is three shots of the same thing and only the best one is worth keeping. Anything
discarded sits in a trash for seven days.

**Annotate** — arrows, boxes, ellipses, lines, freehand, text, step counters, highlighter, and
blur or pixelate for the parts you shouldn't have captured. Crop with the usual aspect ratios.
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

No notarized release exists yet, so: build it.

```sh
git clone https://github.com/darrinm/kapture.git
cd kapture
scripts/bundle.sh
cp -R dist/Kapture.app /Applications/
open /Applications/Kapture.app
```

Requires macOS 14 or later on Apple silicon, and Xcode installed (the command line tools alone
aren't enough — Kapture uses ScreenCaptureKit and the macOS SDK). `bundle.sh` signs the app
with whatever signing identity you have; if you have none it falls back to ad-hoc signing,
which works but makes macOS re-ask for Screen Recording permission after every rebuild.

## Permissions

Kapture asks for as little as it can, as late as it can.

| Permission | When | Why |
| --- | --- | --- |
| Screen Recording | at first launch | required to capture anything at all |
| Microphone | first recording with the mic on | recording your voice |
| Accessibility | optional, offered when relevant | keyboard shortcuts on the hovered card, and drawing keystrokes into a recording |

It is not sandboxed and does not run a background service beyond its own menu bar item. It
makes no network requests unless you turn on AI naming or share something.

## Sharing

Sharing is off until you give Kapture a token. There are no accounts: a link is a long random
id, it never expires, and deleting it is an explicit action.

The server is a single Cloudflare Worker plus an R2 bucket — about 300 lines, in
[`worker/`](worker/). The author runs one at `kapture.sh`; you can deploy your own in a few
minutes and point Kapture at it (Settings › Sharing reads the endpoint from the
`shareEndpoint` default). See [`worker/README.md`](worker/README.md) for the deploy steps and
the security posture: tokens are stored only as hashes, uploads are limited to an allowlist of
image and video types with a daily per-owner quota, and the viewer page runs no JavaScript
under a deny-everything CSP.

## Privacy

Captures are files in a folder you choose (`~/Pictures/Kapture` by default), with a SQLite
index in Application Support. Nothing is uploaded, phoned home, or analyzed remotely by
default.

Exactly two things can send data off the Mac, both opt-in and both visible:

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
