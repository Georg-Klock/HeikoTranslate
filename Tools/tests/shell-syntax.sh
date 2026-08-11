#!/usr/bin/env bash
# `bash -n` over every tracked shell script (GitHub #3). deploy.sh and
# release.sh COMMIT to this repository, and nothing so much as parsed them
# before running — a quoting typo would have been found by the release run
# itself, halfway through mutating git state. A parse is free and needs
# nothing installed; shellcheck is the fuller answer and stays a separate
# decision (it needs installing, and wiring it into CI is a spend question).
set -euo pipefail
cd "$(dirname "$0")/../.."

FAILURES=0
COUNT=0
while IFS= read -r script; do
  COUNT=$((COUNT + 1))
  if err=$(bash -n "$script" 2>&1); then
    echo "PASS  $script"
  else
    echo "FAIL  $script"
    echo "$err" | sed 's/^/      /'
    FAILURES=$((FAILURES + 1))
  fi
done < <(git ls-files '*.sh')

# The same non-zero-count discipline as l1.sh: an empty file list must not
# read as a pass.
if [[ $COUNT -eq 0 ]]; then
  echo "==> shell-syntax: no tracked .sh files found — refusing to call that a pass"
  exit 1
fi
if [[ $FAILURES -gt 0 ]]; then
  echo "==> shell-syntax: $FAILURES of $COUNT failed to parse"
  exit 1
fi
echo "==> shell-syntax: all $COUNT scripts parse"
