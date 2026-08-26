#!/bin/bash
# Visual-review photo shoot. Run from Terminal (has Screen Recording + Accessibility).
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT MACOSX_DEPLOYMENT_TARGET
OUT=/tmp/kapture-shoot
rm -rf "$OUT"; mkdir -p "$OUT"

/usr/bin/xcrun swiftc -O scripts/shoot-helper.swift -o /tmp/shoot-helper 2>/dev/null
H=/tmp/shoot-helper

echo "S1: selection chrome (crosshair + loupe)"
$H key 21 cmd shift          # cmd-shift-4
sleep 1
$H move 1280 700; sleep 0.2; $H move 1281 701; sleep 0.5
screencapture -x "$OUT/01-chrome.png"
$H key 53; sleep 0.7          # esc

echo "S2: drag state (rubber band + dimensions)"
$H key 21 cmd shift
sleep 1
$H move 900 400; sleep 0.3
$H down 900 400; sleep 0.15
for x in 1000 1100 1200 1300 1400 1500; do $H dragto $x $((400 + (x-900)*2/3)); sleep 0.05; done
sleep 0.4
screencapture -x "$OUT/02-drag.png"
$H up 1500 800
sleep 1.3                     # capture completes; overlay appears

echo "S3: overlay hover chrome"
$H move 2460 1370; sleep 0.25; $H move 2461 1371; sleep 0.6
screencapture -x -R 2320,1280,240,160 "$OUT/03-overlay-hover.png"
$H move 1280 720; sleep 0.4

echo "S4: overlay stack (5)"
for i in 1 2 3 4; do $H key 20 cmd shift; sleep 0.8; done
sleep 0.6
screencapture -x -R 2300,680,260,760 "$OUT/04-stack.png"

echo "S5: collapse chip (7 captures)"
$H key 20 cmd shift; sleep 0.8
$H key 20 cmd shift; sleep 1.0
screencapture -x -R 2300,620,260,820 "$OUT/05-stack-chip.png"

echo "S6: pin"
$H key 18 cmd shift           # cmd-shift-1 pin from clipboard
sleep 1
screencapture -x -R 1230,20,1340,780 "$OUT/06-pin.png"
$H move 1300 60; sleep 0.25; $H move 1301 61; sleep 0.5
screencapture -x -R 1240,30,420,300 "$OUT/07-pin-hover.png"
$H click 1896 400; sleep 0.3
$H key 53; sleep 0.5          # esc closes pin

echo "S7: onboarding ready screen"
defaults delete sh.kapture.app onboardingComplete 2>/dev/null || true
pkill -x Kapture || true; sleep 1
open dist/Kapture.app; sleep 2.5
screencapture -x "$OUT/08-onboarding.png"
sleep 0.3
$H click 1280 810             # Done button
sleep 0.5

echo "DONE" > "$OUT/DONE"
ls -la "$OUT"
