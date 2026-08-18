#!/bin/bash
# L3 replay through interpreter mode (#135) — the l3replay.sh pattern:
# compile against the app's real GeminiLiveSession, run.
#
#   Tools/l3interpreter.sh                 # the default order
#   Tools/l3interpreter.sh de_song_lead    # named cases
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
mkdir -p .build
source Tools/session_sources.sh
swiftc -O -o .build/l3interpreter \
  "${SESSION_SOURCES[@]}" \
  "${TURN_SOURCES[@]}" \
  Tools/l3replay/common.swift \
  Tools/l3interpreter/main.swift
exec .build/l3interpreter "$@"
