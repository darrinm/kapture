#!/bin/bash
# End-to-end recording test. Run from Terminal (Screen Recording + Accessibility grants).
cd "$(dirname "$0")/.."
OUT=/tmp/kapture-rectest
rm -rf "$OUT"; mkdir -p "$OUT"
H=/tmp/shoot-helper
[ -f "$H" ] || { export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; unset SDKROOT; /usr/bin/xcrun swiftc -O scripts/shoot-helper.swift -o "$H" 2>/dev/null; }

# clear any stuck selection chrome from previous runs
$H key 53; sleep 0.5; $H key 53; sleep 0.5

LIB=~/Pictures/Kapture
BEFORE=$(find "$LIB" -name "recording*.mp4" 2>/dev/null | wc -l)
MARK=$(mktemp)

echo "start recording: cmd-shift-5 + drag"
$H key 23 cmd shift            # cmd-shift-5
sleep 2                        # generous cold-path settle
$H move 780 380; sleep 0.2; $H move 800 400; sleep 0.4
$H down 800 400; sleep 0.3
for x in 850 900 950 1000 1050 1100 1150 1200; do $H dragto $x $((400 + (x-800)/2)); sleep 0.12; done
screencapture -x "$OUT/mid-drag.png"
sleep 0.4
$H up 1200 600
sleep 2.5
screencapture -x "$OUT/after-up.png"
# proof of recording: the writer's temp file exists
TEMPMP4=$(find /var/folders -name "kapture-recording-*.mp4" -newer "$MARK" 2>/dev/null | head -1)
echo "temp-mp4-during: ${TEMPMP4:-NONE}" > "$OUT/report.txt"
screencapture -x "$OUT/during-full.png" 2>/dev/null
afplay /System/Library/Sounds/Submarine.aiff &
sleep 4
echo "stop recording"
$H key 23 cmd shift
sleep 5                        # finalize + store + overlay

{
  AFTER=$(find "$LIB" -name "recording*.mp4" 2>/dev/null | wc -l)
  echo "recordings before=$BEFORE after=$AFTER"
  NEWEST=$(find "$LIB" -name "recording*.mp4" -newer "$MARK" 2>/dev/null | head -1)
  echo "newest=$NEWEST"
  if [ -n "$NEWEST" ]; then
    ls -la "$NEWEST"
    mdls -name kMDItemDurationSeconds -name kMDItemPixelWidth -name kMDItemPixelHeight -name kMDItemAudioBitRate "$NEWEST"
    echo "--- sidecar:"; cat "${NEWEST%.mp4}.kapture" 2>/dev/null
    echo "--- db row:"
    sqlite3 "$HOME/Library/Application Support/Kapture/library.sqlite" \
      "select kind,status,width,height,round(durationS,1),relPath from captures order by createdAt desc limit 1"
  else
    echo "esc-cleanup (no recording started)"
    $H key 53
  fi
  echo DONE
} >> "$OUT/report.txt" 2>&1
