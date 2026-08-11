#!/usr/bin/env bash
# The L1 gate must test the project generated from THIS checkout, not
# whatever HeikoTranslate.xcodeproj happened to be lying around (GitHub #17).
# The generated project is gitignored, so it does not follow a branch switch —
# a stale one can omit newly added sources and tests, and a green gate over
# the wrong project proves nothing.
#
# These cases run the REAL Tools/l1.sh (copied, not re-implemented — a stub
# would pass forever while the script regressed) in a sandbox whose PATH
# serves stub xcodegen/xcodebuild that log their invocations. No Xcode, no
# network; finishes in about a second.
set -euo pipefail
cd "$(dirname "$0")/../.."
REAL_L1="$PWD/Tools/l1.sh"

FAILURES=0

run_case() {
  local name=$1 xcodegen_exit=$2 xcodebuild_exit=$3 expect_l1_exit=$4
  local sandbox log out
  sandbox=$(mktemp -d -t l1gate)
  log="$sandbox/calls.log"
  out="$sandbox/l1.out"
  mkdir -p "$sandbox/repo/Tools" "$sandbox/bin"
  cp "$REAL_L1" "$sandbox/repo/Tools/l1.sh"

  cat > "$sandbox/bin/xcodegen" <<SH
#!/bin/bash
echo "xcodegen \$*" >> "$log"
exit $xcodegen_exit
SH
  cat > "$sandbox/bin/xcodebuild" <<SH
#!/bin/bash
echo "xcodebuild \$1" >> "$log"
echo "Test Suite 'All tests' passed"
echo "	 Executed 5 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
echo "** TEST SUCCEEDED **"
exit $xcodebuild_exit
SH
  chmod +x "$sandbox/bin/xcodegen" "$sandbox/bin/xcodebuild"

  local status=0
  PATH="$sandbox/bin:$PATH" "$sandbox/repo/Tools/l1.sh" >"$out" 2>&1 || status=$?

  local ok=1
  if [[ "$expect_l1_exit" == "0" ]]; then
    [[ $status -eq 0 ]] || ok=0
    # The whole point: generation happened, and BEFORE the test run.
    [[ "$(head -1 "$log")" == xcodegen* ]] || ok=0
    grep -q "^xcodebuild test" "$log" || ok=0
  elif [[ "$xcodegen_exit" != "0" ]]; then
    [[ $status -ne 0 ]] || ok=0
    # A failed generation must stop the gate — testing a stale project
    # after xcodegen failed is exactly the false green this guards against.
    if grep -q "^xcodebuild" "$log"; then ok=0; fi
  else
    # xcodebuild failed while printing a passing-looking summary. The gate
    # must propagate that failure — the summary line alone is not a pass.
    # This is the `|| true`-clobbers-PIPESTATUS regression: the gate read
    # exit 0 off a failed build and printed "L1 passed" over it.
    [[ $status -ne 0 ]] || ok=0
    if grep -q "L1 passed" "$out"; then ok=0; fi
  fi

  if [[ $ok -eq 1 ]]; then
    echo "PASS  $name"
  else
    echo "FAIL  $name (l1 exit $status; log: $(tr '\n' '|' < "$log"))"
    FAILURES=$((FAILURES + 1))
  fi
  rm -rf "$sandbox"
}

run_case "regenerates the project, then tests" 0 0 0
run_case "a failed generation stops the gate" 1 0 1
run_case "a failing xcodebuild cannot pass on its summary line" 0 65 1

if [[ $FAILURES -gt 0 ]]; then
  echo "==> l1-gate-regenerates: $FAILURES failure(s)"
  exit 1
fi
echo "==> l1-gate-regenerates: all cases pass"
