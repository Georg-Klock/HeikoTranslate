#!/bin/bash
# L3 replay tests (TESTING.md §L3): compiles the replay runner against the
# REAL app sources — GeminiLiveSession.swift (wire protocol), TurnLogic.swift
# (turn decisions), TurnCoordinator.swift (speech-end and turn-identity gate)
# and FinalizePolicy.swift (whether a finalize waits for a late translation) —
# then replays recorded audio through them against the live API. Sharing these
# policies is what stops the harness drifting from the app's finalize behaviour.
#
#   Tools/l3replay.sh                    # all cases
#   Tools/l3replay.sh TestAudio/en_short.wav de_short   # specific cases
#
# Needs HeikoTranslate/Resources/Secrets.plist (see README) and the
# TestAudio/ recordings (Tools/make_test_audio.sh regenerates them).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
source Tools/session_sources.sh
swiftc -O -o .build/l3replay \
  "${TURN_SOURCES[@]}" "${SESSION_SOURCES[@]}" \
  Tools/l3replay/common.swift \
  Tools/l3replay/main.swift
exec .build/l3replay "$@"
