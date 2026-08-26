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

Done: menu bar shell · Carbon hotkeys w/ ⌘⇧3/4 shadowing · frozen-frame area selection
(crosshair, dimensions, ⇧ axis-lock, ⌥ center-out, esc) · fullscreen capture (display under
cursor) · library store (file + sidecar + intent journal + SQLite index in App Support) ·
clipboard destination · quick-access overlay (hover chrome: keep/copy/save, drag-out with
close-after-drag) · two-screen onboarding with relaunch-after-grant · MIT license · CI.

M0 remaining: window-mode capture (space toggle, live window via SCContentFilter) ·
all-displays fullscreen composite · magnifier loupe · capture-previous-area · self-timer ·
overlay ⌘-shortcut routing (click-to-key) · shadowing verify-by-fire in onboarding ·
app icon · design pass.

Architecture and staging follow the implementation spec (v2.1); deviations: SwiftPM-only for
now (no .xcodeproj — `scripts/bundle.sh` assembles the app), KeyboardShortcuts dep deferred
until the Settings UI lands (Carbon direct in the meantime).
