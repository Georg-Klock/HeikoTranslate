#!/usr/bin/env bash
# Every harness that compiles the app's session must take its file list from
# Tools/session_sources.sh, not from a private copy (GitHub #103).
#
# The failure this prevents is silent by construction: a new file in the
# session's dependency graph breaks all four harnesses at once, and each one
# stays broken until somebody happens to run it. `KeyCheck.swift` did exactly
# that — #86 fixed the two that were being run, and l2expiry.sh and
# targetprobe.sh stayed broken until #102, found by reading rather than by
# failing.
#
# This is a STRUCTURAL check, deliberately: it asserts the scripts share one
# list, not that the list compiles. Compiling needs swiftc and a macOS
# runner, and the #14/#88 decisions keep that spend out of CI — so this runs
# on the ubuntu l0 job for free, and the compile stays where it already is,
# in whoever runs L3 before a deploy.
set -euo pipefail
cd "$(dirname "$0")/../.."

SHARED="Tools/session_sources.sh"
FAILURES=0

fail() { echo "FAIL  $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS  $1"; }

[ -f "$SHARED" ] || { echo "FAIL  $SHARED is missing — the shared list is the fix"; exit 1; }

# The shared list must actually define both arrays, or sourcing it would
# silently yield empty expansions and every harness would compile nothing.
# shellcheck source=/dev/null
source "$SHARED"
if [ "${#SESSION_SOURCES[@]}" -gt 0 ]; then
  pass "SESSION_SOURCES is non-empty (${#SESSION_SOURCES[@]} files)"
else
  fail "SESSION_SOURCES is empty — every harness would link nothing"
fi
if [ "${#TURN_SOURCES[@]}" -gt 0 ]; then
  pass "TURN_SOURCES is non-empty (${#TURN_SOURCES[@]} files)"
else
  fail "TURN_SOURCES is empty"
fi
if [ "${#REFEREE_SOURCES[@]}" -gt 0 ]; then
  pass "REFEREE_SOURCES is non-empty (${#REFEREE_SOURCES[@]} files)"
else
  fail "REFEREE_SOURCES is empty"
fi

# Every file named in the shared list must exist. A typo here breaks all
# four harnesses at once, which is the whole point of having one list.
for f in "${SESSION_SOURCES[@]}" "${TURN_SOURCES[@]}" "${REFEREE_SOURCES[@]}"; do
  if [ -f "$f" ]; then
    pass "listed source exists: $f"
  else
    fail "listed source does not exist: $f"
  fi
done

# Find every script that builds a binary out of the app's session, by what it
# does rather than by a hard-coded list — a fifth harness added tomorrow is
# caught without editing this file.
#
# A harness is a script that INVOKES swiftc, not one that mentions it: the
# shared list names the same files in prose, and targetprobe-smoke.sh
# describes the compile it delegates. Match a real command line.
#
# No `mapfile` either: macOS ships bash 3.2 and this suite runs locally as
# well as on the ubuntu l0 runner.
HARNESSES=()
HARNESS_COUNT=0
while read -r s; do
  [ "$s" = "$SHARED" ] && continue
  grep -qE '^[[:space:]]*swiftc[[:space:]]' "$s" 2>/dev/null || continue
  HARNESSES+=("$s")
  HARNESS_COUNT=$((HARNESS_COUNT + 1))
done < <(git ls-files 'Tools/*.sh' 'Tools/**/*.sh')

# A plain counter, not ${#HARNESSES[@]}: an empty array under `set -u` is an
# error on bash 3.2 (macOS), and `${#arr[@]:-0}` — the obvious guard — is a
# bad substitution on bash 5 (the ubuntu l0 runner). The counter is correct
# on both, which is the whole point of this suite running in CI.
if [ "$HARNESS_COUNT" -eq 0 ]; then
  # Exit here rather than fall through: iterating an empty array under
  # `set -u` is itself an error on bash 3.2, so continuing would report a
  # shell fault instead of the real problem, which is that the discovery
  # heuristic stopped matching anything.
  echo "FAIL  found no session harnesses at all — this suite would pass vacuously"
  exit 1
fi

for s in "${HARNESSES[@]}"; do
  if grep -q "^source $SHARED\|^\. $SHARED" "$s"; then
    pass "$s sources the shared list"
  else
    fail "$s compiles the session but does not source $SHARED"
  fi

  # A private copy is the regression: naming an app source file literally in
  # the swiftc invocation is how the four lists drifted apart in the first
  # place. The harness's OWN files (Tools/...) are its business.
  if grep -qE '^\s+HeikoTranslate/.*\.swift' "$s"; then
    fail "$s still names HeikoTranslate/ sources inline — use the shared list"
  else
    pass "$s names no app sources inline"
  fi
done

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "==> harness-sources-shared: $FAILURES failure(s) across $HARNESS_COUNT harnesses"
  exit 1
fi
echo "==> harness-sources-shared: all checks pass across $HARNESS_COUNT harnesses"
