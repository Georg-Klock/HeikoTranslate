#!/usr/bin/env bash
# L1 — the fast logic suite, in one command.
#
# This exists because L1 is now the gate that CI no longer is. Since 2026-08-08
# the workflow runs on merges to `main` only (see .github/workflows/l1.yml), so
# nothing on GitHub checks a pull request before it is opened. That is a fine
# trade only if L1 actually runs locally, every time, from a single command
# nobody has to remember the flags for. Hence this file.
#
# It deliberately does NOT pass -quiet. `-quiet` suppresses the "Executed N
# tests" summary, which is the only line that proves the suite ran at all — a
# scheme that silently builds zero test targets exits 0 and looks identical to
# a pass. The count is asserted below, the same way the CI job asserts it.
set -euo pipefail
cd "$(dirname "$0")/.."

# The project file is generated and gitignored, so it does not follow the
# checkout: after a branch switch it can reference files that no longer exist,
# or silently omit ones newly added — and a gate that tests a stale project
# proves nothing about the code it claims to gate. Regenerating here also
# means a fresh clone can reach the gate at all, and release.sh/deploy.sh
# inherit the guarantee through this script. Idempotent, well under a second.
# GitHub #17.
xcodegen generate >/dev/null

DEST=${L1_DESTINATION:-'platform=iOS Simulator,name=iPhone 17 Pro'}
OUT=$(mktemp -t l1out)
trap 'rm -f "$OUT"' EXIT

echo "==> L1  ($DEST)"
set +e
xcodebuild test -project HeikoTranslate.xcodeproj -scheme HeikoTranslate \
  -destination "$DEST" 2>&1 | tee "$OUT" | grep -E "^(Test Suite|Executed|.*error:|\*\* )"
# PIPESTATUS survives only until the next command. This line used to end in
# `|| true` — and under the pipefail set at the top, any xcodebuild failure
# fails the pipeline, so `true` always ran and reset PIPESTATUS to (0) before
# it was read. A failed build whose output still carried a passing summary
# line was reported as "L1 passed". Capture the whole array first; grep
# finding no lines to display is fine and must not fail the gate (set +e
# covers it).
PIPE=("${PIPESTATUS[@]}")
set -e
STATUS=${PIPE[0]}

if [[ $STATUS -ne 0 ]]; then
  echo "==> L1 FAILED (xcodebuild exit $STATUS)" >&2
  grep -E "error:|failed" "$OUT" | head -20 >&2 || true
  exit "$STATUS"
fi

# The suite must have run, and it must have run a non-zero number of tests.
if ! grep -qE "Executed [1-9][0-9]* tests?, with 0 failures" "$OUT"; then
  echo "==> L1 did not report a passing non-zero test count — refusing to call this a pass." >&2
  grep -E "Executed .* tests?" "$OUT" | tail -5 >&2 || echo "  (no 'Executed' line at all)" >&2
  exit 1
fi

grep -E "Executed [0-9]+ tests?, with 0 failures" "$OUT" | tail -1
echo "==> L1 passed"
