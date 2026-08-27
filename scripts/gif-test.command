#!/bin/bash
# GIF-exporter smoke test: convert a movie and report the result (dimensions, duration, size).
#   scripts/gif-test.command [path/to/movie.mp4]
# With no argument it picks the newest recording in the library.
# Drives the app binary's --gif-test mode; bundles first if dist/Kapture.app is missing.
set -e
cd "$(dirname "$0")/.."

MOVIE="$1"
if [ -z "$MOVIE" ]; then
  MOVIE=$(find ~/Pictures/Kapture -name "recording*.mp4" -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1)
fi
[ -n "$MOVIE" ] && [ -f "$MOVIE" ] || { echo "usage: $0 <movie.mp4> (no recordings found)"; exit 1; }

BIN=dist/Kapture.app/Contents/MacOS/Kapture
[ -x "$BIN" ] || bash scripts/bundle.sh

echo "converting: $MOVIE"
"$BIN" --gif-test "$MOVIE"
