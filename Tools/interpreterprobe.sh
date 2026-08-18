#!/bin/bash
# Launcher for the #135 latency comparison — the floorprobe.sh pattern:
# compile against the app's real GeminiLiveSession, run.
#
#   Tools/interpreterprobe.sh translate   fr     TestAudio/de_short.wav
#   Tools/interpreterprobe.sh interpreter de fr  TestAudio/de_short.wav
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
mkdir -p .build
source Tools/session_sources.sh
swiftc -O -o .build/interpreterprobe \
  "${SESSION_SOURCES[@]}" \
  Tools/l3replay/common.swift \
  Tools/interpreterprobe/main.swift
exec .build/interpreterprobe "$@"
