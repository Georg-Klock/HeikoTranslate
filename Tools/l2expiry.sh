#!/bin/bash
# L2.6 probe (TESTING.md): hold a real Gemini Live session open until the
# server ends it (~10-20 min), assert the end surfaces as .closed (the
# reconnect trigger), then verify a fresh session translates immediately
# after. Compiles against the app's REAL GeminiLiveSession.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -O -o .build/l2expiry \
  HeikoTranslate/Models/KeyCheck.swift \
  HeikoTranslate/Services/GeminiLiveSession.swift \
  Tools/l3replay/common.swift \
  Tools/l2expiry/main.swift
exec .build/l2expiry "$@"
