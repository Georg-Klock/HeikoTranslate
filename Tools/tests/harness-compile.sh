#!/usr/bin/env bash
# Every session harness still type-checks (GitHub #103).
#
# harness-sources-shared.sh asserts the four scripts share one file list;
# this asserts the list is actually *sufficient* — the check that would have
# caught `KeyCheck.swift` (#82) on the day it landed instead of in two
# instalments (#86, then #102 by reading).
#
# Local only, like Tools/tests/targetprobe-smoke.sh and for the same reason:
# it needs swiftc, so it cannot run on the ubuntu l0 job, and putting it on a
# macOS runner is the CI spend #14 and #88 both declined. Run it before
# opening a PR that touches the session's dependency graph. It compiles
# nothing to disk and contacts no network.
#
#   Tools/tests/harness-compile.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v swiftc > /dev/null || {
  echo "!!  no swiftc on PATH — this suite is macOS-local by design (see header)" >&2
  exit 2
}

# shellcheck source=/dev/null
source Tools/session_sources.sh

FAILURES=0

# name : whether it needs the turn-arbitration sources : its own entry point.
# The APP sources are shared (that is the fix); what stays per-harness is
# only its own main.swift, which is what actually differs between them.
check() {
  local name=$1 needs_turn=$2 entry=$3
  local sources=("${SESSION_SOURCES[@]}")
  [ "$needs_turn" = "turn" ] && sources=("${TURN_SOURCES[@]}" "${sources[@]}")

  local out
  if out=$(swiftc -typecheck "${sources[@]}" Tools/l3replay/common.swift "$entry" 2>&1); then
    echo "PASS  $name type-checks"
  else
    echo "FAIL  $name does not type-check:"
    echo "$out" | grep -E "error:" | head -5 | sed 's/^/        /'
    FAILURES=$((FAILURES + 1))
  fi
}

check l3replay   turn    Tools/l3replay/main.swift
check floorprobe session Tools/floorprobe/main.swift
check l2expiry   session Tools/l2expiry/main.swift
check targetprobe session Tools/targetprobe/main.swift

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "==> harness-compile: $FAILURES harness(es) broken — a source is missing from Tools/session_sources.sh"
  exit 1
fi
echo "==> harness-compile: all 4 harnesses type-check"
