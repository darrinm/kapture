# Kapture

A personal macOS capture workspace — screenshots, recordings, and a library that remembers
everything, all on your Mac. Free, local-first, no accounts.

- **Product spec / implementation spec / design mockups:** published as Claude artifacts (links in project notes).
- **Spike validation:** see `../kapture-spikes/README.md` — every load-bearing API claim verified empirically.
- Platform: macOS 14+, Apple silicon. Swift 6, SwiftPM. Not sandboxed; hardened runtime for release.

## Dev

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if xcode-select points elsewhere
swift build && swift test
scripts/bundle.sh && open dist/Kapture.app
```

First run: grant Screen Recording when asked (the app relaunches itself), then ⌘⇧4.

## M0 status

Done: menu bar shell · Carbon hotkeys (⌘⇧3/4 shadowing, ⌥⇧4 previous-area) · frozen-frame
selection (crosshair, magnifier loupe w/ pixel grid + hex, dimensions, ⇧ axis-lock,
⌥ center-out, esc; **space toggles window mode** — hover-highlight, live window capture with
transparent background) · fullscreen (display under cursor) + all-displays composite ·
self-timer (3/5/10s) · library store (file + sidecar + intent journal + SQLite index in App
Support) · clipboard destination · quick-access overlay (hover chrome keep/copy/save, drag-out
w/ close-after-drag, click-to-key ⌘W/⌘C/⌘S) · two-screen onboarding with relaunch-after-grant ·
app icon (gpt-image-2 + squircle mask, `scripts/build-icns.sh`) · MIT license · CI.

M0 remaining: shadowing verify-by-fire in onboarding · design pass.

Architecture and staging follow the implementation spec (v2.1); deviations: SwiftPM-only for
now (no .xcodeproj — `scripts/bundle.sh` assembles the app), KeyboardShortcuts dep deferred
until the Settings UI lands (Carbon direct in the meantime).
