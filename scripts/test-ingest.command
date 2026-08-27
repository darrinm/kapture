#!/bin/bash
# Ingest smoke test: take a capture of a text-rich region, keep it (which expedites OCR),
# then confirm the search index picked up its text.
cd "$(dirname "$0")/.."
OUT=/tmp/kapture-ingest; rm -rf "$OUT"; mkdir -p "$OUT"
H=/tmp/shoot-helper
[ -f "$H" ] || { export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; unset SDKROOT; /usr/bin/xcrun swiftc -O scripts/shoot-helper.swift -o "$H" 2>/dev/null; }
DB="$HOME/Library/Application Support/Kapture/library.sqlite"

$H key 53; sleep 0.4
echo "capture a text-rich region"
$H key 21 cmd shift          # cmd-shift-4
sleep 1.5
$H move 200 200; sleep 0.3
$H down 200 200; sleep 0.2
for x in 400 700 1000 1300; do $H dragto $x $((200 + x/4)); sleep 0.1; done
sleep 0.3
$H up 1300 525
sleep 2

# keep the capture (cmd-W on the hovered card) to expedite indexing
$H move 2460 1370; sleep 0.4
$H click 2460 1370; sleep 0.3
$H key 13 cmd; sleep 1.5     # cmd-W keep

{
  echo "waiting for ingest (up to 60s)…"
  for i in $(seq 1 30); do
    N=$(sqlite3 "$DB" "select count(*) from fts_source where length(ocr) > 0" 2>/dev/null)
    [ "${N:-0}" -gt 0 ] && break
    sleep 2
  done
  echo "indexed rows: $(sqlite3 "$DB" "select count(*) from fts_source where length(ocr) > 0")"
  echo "pending jobs: $(sqlite3 "$DB" "select count(*) from ingest_jobs")"
  echo "--- sample text:"
  sqlite3 "$DB" "select substr(replace(ocr, char(10), ' '), 1, 160) from fts_source where length(ocr) > 0 order by rowid desc limit 1"
  echo DONE
} > "$OUT/report.txt" 2>&1
