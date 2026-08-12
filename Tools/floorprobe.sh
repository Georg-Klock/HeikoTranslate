#!/bin/bash
# Launcher for the #29 measurement's live driver — the targetprobe.sh
# pattern: compile against the app's real GeminiLiveSession, run.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
mkdir -p .build
swiftc -O -o .build/floorprobe \
  HeikoTranslate/Services/GeminiLiveSession.swift \
  Tools/l3replay/common.swift \
  Tools/floorprobe/main.swift
exec .build/floorprobe "$@"
