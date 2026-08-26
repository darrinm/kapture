#!/bin/bash
# Visual-review photo shoot. Run from Terminal (has Screen Recording + Accessibility).
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT MACOSX_DEPLOYMENT_TARGET
OUT=/tmp/kapture-shoot
rm -rf "$OUT"; mkdir -p "$OUT"

# Display geometry (2560×1440 points) and the chrome locations derived from it
SW=2560; SH=1440
CX=$((SW / 2)); CY=$((SH / 2))
# bottom-right overlay corner
OV_HOVER_X=$((SW - 100)); OV_HOVER_Y=$((SH - 70))            # inside the corner card
OV_CARD_R="$((SW - 240)),$((SH - 160)),240,160"              # -R: corner card
OV_STACK_R="$((SW - 260)),$((SH - 760)),260,760"             # -R: 5-card stack
OV_CHIP_R="$((SW - 260)),$((SH - 820)),260,820"              # -R: stack + collapse chip
# pin panel (opens at top-right)
PIN_R="$((CX - 50)),20,1340,780"                             # -R: pin panel
PIN_HOVER_X=$((CX + 20)); PIN_HOVER_Y=60                     # pin close-button hover
PIN_HOVER_R="$((CX - 40)),30,420,300"                        # -R: pin hover chrome

/usr/bin/xcrun swiftc -O scripts/shoot-helper.swift -o /tmp/shoot-helper 2>/dev/null
H=/tmp/shoot-helper

echo "S1: selection chrome (crosshair + loupe)"
$H key 21 cmd shift          # cmd-shift-4
sleep 1
$H move $CX $((CY - 20)); sleep 0.2; $H move $((CX + 1)) $((CY - 19)); sleep 0.5
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
$H move $OV_HOVER_X $OV_HOVER_Y; sleep 0.25; $H move $((OV_HOVER_X + 1)) $((OV_HOVER_Y + 1)); sleep 0.6
screencapture -x -R "$OV_CARD_R" "$OUT/03-overlay-hover.png"
$H move $CX $CY; sleep 0.4

echo "S4: overlay stack (5)"
for i in 1 2 3 4; do $H key 20 cmd shift; sleep 0.8; done
sleep 0.6
screencapture -x -R "$OV_STACK_R" "$OUT/04-stack.png"

echo "S5: collapse chip (7 captures)"
$H key 20 cmd shift; sleep 0.8
$H key 20 cmd shift; sleep 1.0
screencapture -x -R "$OV_CHIP_R" "$OUT/05-stack-chip.png"

echo "S6: pin"
$H key 18 cmd shift           # cmd-shift-1 pin from clipboard
sleep 1
screencapture -x -R "$PIN_R" "$OUT/06-pin.png"
$H move $PIN_HOVER_X $PIN_HOVER_Y; sleep 0.25; $H move $((PIN_HOVER_X + 1)) $((PIN_HOVER_Y + 1)); sleep 0.5
screencapture -x -R "$PIN_HOVER_R" "$OUT/07-pin-hover.png"
$H click 1896 400; sleep 0.3
$H key 53; sleep 0.5          # esc closes pin

echo "S7: onboarding ready screen"
defaults delete sh.kapture.app onboardingComplete 2>/dev/null || true
pkill -x Kapture || true; sleep 1
open dist/Kapture.app; sleep 2.5
screencapture -x "$OUT/08-onboarding.png"
sleep 0.3
$H click $CX 810             # Done button
sleep 0.5

echo "DONE" > "$OUT/DONE"
ls -la "$OUT"
