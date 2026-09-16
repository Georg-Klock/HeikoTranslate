#!/bin/bash
# Phase 0 measurement for GitHub #135: an independent on-device language
# witness. Runs the TestAudio corpus through TWO on-device SpeechTranscribers —
# de-DE and the partner's locale — and prints every candidate score from #135
# §3, with each score's two populations and whether a gap separates them.
#
#   Tools/lidprobe.sh                             # the whole corpus
#   Tools/lidprobe.sh TestAudio/de_short.wav      # specific fixtures
#   Tools/lidprobe.sh --assets-only               # locale support, installs
#   Tools/lidprobe.sh --no-install …              # never download a model
#   Tools/lidprobe.sh --request-sf-authorization  # the TCC control (main.swift)
#
# Needs macOS 26 (SpeechTranscriber). No API key, no audio leaves the machine,
# nothing is played: fixtures are read from disk into the analyzer. The first
# run may download Apple's speech models for missing locales, which it times.
#
# What this measures is the approach on the MAC's models, not the phone's.
# The same framework ships on both, but the assets are per platform, so a
# result here is evidence to take to a device, not a device result.
#
# RefereeEvidence is compiled from the app's own sources through the shared
# list, so the harness measures the code the app would run (#103).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
source Tools/session_sources.sh

swiftc -O -o .build/lidprobe \
  "${TURN_SOURCES[@]}" \
  "${REFEREE_SOURCES[@]}" \
  Tools/lidprobe/main.swift \
  -framework Speech -framework AVFoundation

# Named fixtures, or a mode that reads none: pass straight through.
for arg in "$@"; do
  case "$arg" in
    *.wav|--assets-only|--request-sf-authorization) exec .build/lidprobe "$@" ;;
  esac
done

# The whole corpus. Truth comes from each file's name prefix; main.swift skips
# (and lists) any fixture whose language is not in the app's set, and reports
# silence.wav and noise.wav as the false-positive check.
exec .build/lidprobe "$@" TestAudio/*.wav
