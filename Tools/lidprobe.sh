#!/bin/bash
# Phase 0 measurement for GitHub #135: an independent on-device language
# witness. Runs the labelled TestAudio corpus through TWO on-device speech
# recognizers — one per side of the pair — and prints every candidate
# discriminator, so the rule is chosen from a table rather than fitted to the
# first two points (the #32 lesson).
#
#   Tools/lidprobe.sh                                   # labelled corpus, de↔es
#   Tools/lidprobe.sh de en                             # labelled corpus, another pair
#   Tools/lidprobe.sh de es TestAudio/de_short.wav=de   # specific fixtures
#
# Needs no API key and no network: everything is on-device. Costs nothing,
# which is the point — it is the cheap gate in front of the expensive phases.
#
# Nothing here touches the app. `RefereeEvidence` is compiled from the app's
# own sources through the shared list, so this harness measures the code the
# app would run, not a copy of it (#103).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
source Tools/session_sources.sh

# The usage description is linked into __TEXT,__info_plist — the supported
# way to give a CLI one — and the binary is ad-hoc signed so the section is
# covered by a signature.
#
# KNOWN BLOCKER, measured 2026-08-17 (macOS 15): this is still not enough for
# TCC, which terminates the process on any authorization request. Verified in
# four configurations — plain CLI, signed CLI, .app bundle, signed .app
# bundle — sandboxed and not. The probe therefore reads the authorization
# status and refuses rather than asking, so the failure is a sentence instead
# of a SIGABRT. Phase 0's corpus measurement belongs on iOS; see #135 and the
# note at the top of Tools/lidprobe/main.swift.
#
# The compile still earns its keep every run: it type-checks RefereeEvidence
# against the app's real sources through the shared list, which is what keeps
# this experiment from rotting as main moves (#103).
PLIST=Tools/lidprobe/Info.plist

swiftc -O -o .build/lidprobe \
  "${TURN_SOURCES[@]}" \
  "${REFEREE_SOURCES[@]}" \
  Tools/lidprobe/main.swift \
  -framework Speech -framework AVFoundation \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST"
codesign -f -s - .build/lidprobe >/dev/null 2>&1 || true

if [ "$#" -ge 3 ]; then
  exec .build/lidprobe "$@"
fi

home="${1:-de}"
partner="${2:-es}"

# The labelled corpus. Truth is what was SPOKEN, which for these fixtures is
# a property of how make_test_audio.sh generated them. The two de_song_lead
# files are German that OPENS in English (#32) — labelled German, because
# that is the turn's language and the side it must land on.
CORPUS=(
  "TestAudio/de_short.wav=de"
  "TestAudio/de_after_en.wav=de"
  "TestAudio/de_after_es.wav=de"
  "TestAudio/de_song_lead.wav=de"
  "TestAudio/de_song_lead_long.wav=de"
)
case "$partner" in
  en) CORPUS+=("TestAudio/en_short.wav=en" "TestAudio/en_long.wav=en") ;;
  es) CORPUS+=("TestAudio/es_short.wav=es") ;;
esac

# silence.wav and noise.wav carry no speech and no truth label: they are the
# false-positive check. A referee that names a language for either of them is
# inventing testimony, which is worse than staying quiet.
CORPUS+=("TestAudio/silence.wav" "TestAudio/noise.wav")

exec .build/lidprobe "$home" "$partner" "${CORPUS[@]}"
