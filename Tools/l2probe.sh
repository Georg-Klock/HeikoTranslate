#!/bin/bash
# One-shot L2 probe on the WIRE PATH THE APP SHIPS: synthesize a sentence,
# stream it through the real GeminiLiveSession, print the translation.
#
#   Tools/l2probe.sh de "Where is the train station?"
#   Tools/l2probe.sh de "Wo ist der Bahnhof?" Anna     # optional voice
#
# Exists because Tools/livetest.py — the Python twin — went silent
# server-side while GeminiLiveSession kept working (GitHub #76): a probe
# that tests a path the app does not ship stops being evidence about the
# app. livetest.py remains for protocol experiments; THIS is the health
# check.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

TARGET="${1:-}"; TEXT="${2:-}"; VOICE="${3:-Samantha}"
[[ -n "$TARGET" && -n "$TEXT" ]] || { echo "usage: l2probe.sh <target-code> \"<sentence>\" [voice]" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
say -v "$VOICE" -o "$TMP/s.aiff" "$TEXT"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/s.aiff" "$TMP/s.wav"

if OUT=$(./Tools/floorprobe.sh "$TMP/s.wav" "$TARGET"); then
  echo "${OUT#FLOORPROBE-OUT: }"
  echo "==> L2 OK (${TARGET}, via GeminiLiveSession)"
else
  echo "$OUT" >&2
  echo "==> L2 FAILED" >&2
  exit 1
fi
