#!/bin/bash
# The app sources every standalone harness compiles (GitHub #103), sourced
# the way build_number.sh and secrets_preflight.sh are.
#
# Four scripts build a `swiftc` binary out of the app's own files —
# l3replay.sh, floorprobe.sh, l2expiry.sh, targetprobe.sh — and each used to
# carry its own hand-written copy of the list. Nothing type-checked those
# copies, so a new file in the session's dependency graph broke all four at
# once and stayed broken in whichever ones nobody happened to run.
#
# That is not hypothetical. `KeyCheck.swift` arrived with #82; #86 fixed the
# two harnesses that were being run, and l2expiry.sh and targetprobe.sh
# stayed broken until #102 — found by reading, not by failing. targetprobe.sh
# is the tool TESTING.md cites for the #30 partner-only evidence, so the next
# language question would have opened with a build error.
#
# One list, four users. Adding a file to the session's graph is now one edit.
#
# Both arrays are read by the scripts that SOURCE this file, which shellcheck
# cannot see from here — so it calls them unused, and the lint job runs at
# warning severity. Scoped to this file rather than silenced per-line:
# everything here is, by design, defined for somebody else to use.
# shellcheck disable=SC2034

# The session and what it needs to link: the wire protocol plus the key
# heuristic it consults on an unexplained close.
SESSION_SOURCES=(
  HeikoTranslate/Models/KeyCheck.swift
  HeikoTranslate/Services/GeminiLiveSession.swift
)

# Turn arbitration. Only l3replay.sh needs these — it exercises the turn
# decisions as well as the wire protocol, which is the point of L3 (#21).
# The probes drive a single session and never arbitrate, so they link a
# smaller binary.
TURN_SOURCES=(
  HeikoTranslate/Models/TurnLogic.swift
  HeikoTranslate/Models/FillerWords.swift
  HeikoTranslate/Models/FinalizePolicy.swift
  HeikoTranslate/Models/SpeechEndPolicy.swift
)
