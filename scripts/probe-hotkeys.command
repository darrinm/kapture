#!/bin/bash
cd "$(dirname "$0")/.."
OUT=/tmp/kapture-probe; rm -rf "$OUT"; mkdir -p "$OUT"
H=/tmp/shoot-helper
$H key 53; sleep 0.5   # clear anything
$H key 23 cmd shift    # cmd-shift-5
sleep 1.5
screencapture -x "$OUT/after-cmd-shift-5.png"
$H key 53; sleep 0.8   # esc
$H key 21 cmd shift    # cmd-shift-4 control probe
sleep 1.5
screencapture -x "$OUT/after-cmd-shift-4.png"
$H key 53; sleep 0.5
echo DONE > "$OUT/done"
