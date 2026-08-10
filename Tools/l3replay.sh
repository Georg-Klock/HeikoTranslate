#!/bin/bash
# L3 replay tests (TESTING.md §L3): compiles the replay runner against the
# REAL app sources — GeminiLiveSession.swift (wire protocol), TurnLogic.swift
# (turn decisions) and FinalizePolicy.swift (whether a finalize waits for a
# late translation) — then replays recorded audio through them against the
# live API. Sharing FinalizePolicy is what stops the harness drifting from the
# app's finalize behaviour the way it silently had (GitHub #21).
#
#   Tools/l3replay.sh                    # all cases
#   Tools/l3replay.sh TestAudio/en_short.wav de_short   # specific cases
#
# Needs HeikoTranslate/Resources/Secrets.plist (see README) and the
# TestAudio/ recordings (Tools/make_test_audio.sh regenerates them).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -O -o .build/l3replay \
  HeikoTranslate/Models/TurnLogic.swift \
  HeikoTranslate/Models/FillerWords.swift \
  HeikoTranslate/Models/FinalizePolicy.swift \
  HeikoTranslate/Models/SpeechEndPolicy.swift \
  HeikoTranslate/Services/GeminiLiveSession.swift \
  Tools/l3replay/common.swift \
  Tools/l3replay/main.swift
exec .build/l3replay "$@"
