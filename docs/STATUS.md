# Build status

Milestone-by-milestone history. The [README](../README.md) describes what Kapture does today;
this file records how it got there and what is still open in each area.

## M0 status

Done: menu bar shell · Carbon hotkeys (⌘⇧3/4 shadowing, ⌥⇧4 previous-area) · frozen-frame
selection (crosshair, magnifier loupe w/ pixel grid + hex, dimensions, ⇧ axis-lock,
⌥ center-out, esc; **space toggles window mode** — hover-highlight, live window capture with
transparent background) · fullscreen (display under cursor) + all-displays composite ·
self-timer (3/5/10s) · library store (file + sidecar + intent journal + SQLite index in App
Support) · clipboard destination · quick-access overlay (hover chrome keep/copy/save, drag-out
w/ close-after-drag, click-to-key ⌘W/⌘C/⌘S) · two-screen onboarding with relaunch-after-grant ·
app icon (gpt-image-2 + squircle mask, `scripts/build-icns.sh`) · MIT license · CI.

M0: complete (verify-by-fire ships as ShortcutConflictWatch — notices the apps holding ⌘⇧3/4/5 and explains why a press didn't reach Kapture).

## M1 status (It triages)

Done: journaled trash (.trash/ + tombstones, 7-day sweep every 6h, sweep-safe restore) ·
discard gestures (hover trash, ⌘⌫, swipe-toward-edge; swipe-down hides all) · Restore Last
Discarded · +n stack collapse past 5 · Quick Look (space) · right-click menu · pins (drag,
opacity scroll, nudge, lock/click-through, hover ×, ⌘⇧1 from clipboard) · capture→corner
flight animation · Settings window (General/Overlay: clipboard, sounds, launch-at-login,
export location, overlay position/size, auto-close w/ save-and-close) · hover-shortcut
event-tap tier (Accessibility JIT, tap re-enable, click-to-key floor) · uninstall flow ·
design pass v1 (scripted photo shoot in scripts/shoot.command).

M1 remaining: After-Capture action list UI (destinations model exists) · rotate/flip &
scale-Retina on right-click (needs editor plumbing, lands with M2).

## M2 status (It annotates)

Done: annotation editor (arrow, rectangle, ellipse, line, freehand, text, counter, highlighter,
blur, pixelate) with canvas zoom (pinch / ⌘+ / ⌘− / ⌘0 fit / ⌘1 actual size), layer selection, control-point editing, per-layer recolor and width, undo
per gesture · crop (draggable from inside, resizable from any edge or corner, clamped to the
image, aspect-ratio presets, in-editor apply that stays undoable) · per-tool options bar ·
originals preserved in `.originals/` so every destructive edit is reversible.

## M3 status (It records)

Done: screen recording of an area, window or display (ScreenCaptureKit + AVAssetWriter) with
system audio and microphone · pause/resume, with the menu-bar timer holding while paused ·
click and keystroke visualization drawn into the movie · trimmer · GIF export as a new capture ·
menu-bar red dot that stops on click rather than opening a menu.

## M4 status (It remembers)

Done: library window with a Photos-style borderless grid · FTS5 search over recognized text,
with app, kind and date-range filters · on-device OCR ingest (Vision) and Capture Text (⌘⇧2) ·
automatic naming, defaulting on only when an Anthropic key is present — the on-device heuristic
ships off because its names were verifiably worse than a timestamp · filename templates ·
rename in-use guard so a rename can never move a file out from under a drag, save panel or
upload.

## M5 status (It shares)

Done: share to kapture.sh — ⌘U on an overlay card or Share Link in the library uploads the
capture and copies a permanent, unguessable link. Re-sharing an unedited capture copies the
existing link; editing marks it out of date; deleting revokes it. The token lives in the
Keychain (Settings › Sharing). In-app updates via Sparkle, with the appcast and DMG served from
GitHub releases.

- Backend: [`../worker/README.md`](../worker/README.md) — a single Cloudflare Worker + R2, no
  accounts, hashed tokens, a no-JavaScript viewer under a deny-everything CSP.
- Releases: [`RELEASING.md`](RELEASING.md) — tag, and CI signs, notarizes, staples and publishes.

The Worker is deployed on kapture.sh and verified end to end from the app.

M5 remaining: no release has been cut yet — that needs a Developer ID certificate and the
notarization secrets listed in [`RELEASING.md`](RELEASING.md), so `/download` and the appcast
still 404.

Architecture and staging follow the implementation spec (v2.1); deviations: SwiftPM-only for
now (no .xcodeproj — `scripts/bundle.sh` assembles the app), KeyboardShortcuts dep deferred
until the Settings UI lands (Carbon direct in the meantime).
