#!/bin/bash
# Target-language probe launcher (docs/ARCHITECTURE.md, and the usage line in
# Tools/targetprobe/main.swift, both said to run this — the file itself went
# missing in the migration, GitHub #21). Compiles the probe against the REAL
# GeminiLiveSession, same as the other live tools, then asks the live model
# whether it accepts each targetLanguageCode. Evidence first: run this before
# adding any language to the picker.
#
#   Tools/targetprobe.sh fr ko zh
#
# Needs HeikoTranslate/Resources/Secrets.plist and TestAudio/en_short.wav
# (Tools/make_test_audio.sh regenerates the recordings).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
source Tools/session_sources.sh
swiftc -O -o .build/targetprobe \
  "${SESSION_SOURCES[@]}" \
  Tools/l3replay/common.swift \
  Tools/targetprobe/main.swift
exec .build/targetprobe "$@"
