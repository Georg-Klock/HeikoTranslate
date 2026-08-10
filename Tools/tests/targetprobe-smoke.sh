#!/usr/bin/env bash
# Smoke check for the target-probe launcher (GitHub #21): the documented
# command compiles and handles its arguments, without ever contacting the
# live API. Unlike the other L0 scripts this needs swiftc (it compiles the
# real GeminiLiveSession), so it is a local pre-PR check, not a stub game —
# the compile IS the check that the launcher's source list is right.
set -euo pipefail
cd "$(dirname "$0")/../.."

FAILURES=0

# No arguments: usage on stderr, exit 2, and no network was needed — the
# argument check deliberately precedes the API-key load.
set +e
ERR=$(./Tools/targetprobe.sh 2>&1 >/dev/null)
STATUS=$?
set -e
if [[ $STATUS -eq 2 && "$ERR" == *"usage: targetprobe"* ]]; then
  echo "PASS  no arguments: usage and exit 2"
else
  echo "FAIL  no arguments: exit $STATUS, stderr: $ERR"
  FAILURES=$((FAILURES + 1))
fi

if [[ $FAILURES -gt 0 ]]; then
  echo "==> targetprobe-smoke: $FAILURES failure(s)"
  exit 1
fi
echo "==> targetprobe-smoke: all cases pass"
