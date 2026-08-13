#!/usr/bin/env bash
# The accessibility gate must be able to fail (GitHub #88). The script's
# xcodebuild pipeline used to end in `|| true`, so a failing accessibility
# suite — or a scheme that built zero tests — reported success, on a script
# whose whole purpose is that the wheels' VoiceOver claims are verified, not
# assumed (TESTING.md, the #14 section). Same idiom, same fix, same pinning
# as l1-gate-regenerates.sh does for l1.sh.
#
# These cases run the REAL Tools/uitest-accessibility.sh (copied, not
# re-implemented — a stub would pass forever while the script regressed) in a
# sandbox whose PATH serves stub xcodegen/xcodebuild/xcrun that log their
# invocations. HOME points into the sandbox so the script's simulator
# preference cleanup touches nothing real. No Xcode, no simulator, no
# network; finishes in about a second.
set -euo pipefail
cd "$(dirname "$0")/../.."
REAL_SCRIPT="$PWD/Tools/uitest-accessibility.sh"

FAILURES=0

run_case() {
  local name=$1 executed_line=$2 xcodebuild_exit=$3 expect_exit=$4
  local sandbox log out
  # Plain `mktemp -d`, no BSD-style -t template: this suite runs in the
  # ubuntu l0 job, and GNU mktemp rejects a -t template without X's.
  sandbox=$(mktemp -d)
  log="$sandbox/calls.log"
  out="$sandbox/a11y.out"
  mkdir -p "$sandbox/repo/Tools" "$sandbox/bin" "$sandbox/home"
  cp "$REAL_SCRIPT" "$sandbox/repo/Tools/uitest-accessibility.sh"

  cat > "$sandbox/bin/xcodegen" <<SH
#!/bin/bash
echo "xcodegen \$*" >> "$log"
exit 0
SH
  # The script greps `simctl list devices booted` for a device id; under
  # pipefail an empty list would kill it before xcodebuild ever ran, so the
  # stub reports one booted device. The id is the repo's standard synthetic
  # fixture (SYNTHETIC_UUIDS in Tools/privacy-check.sh) — obviously invented.
  cat > "$sandbox/bin/xcrun" <<SH
#!/bin/bash
echo "xcrun \$*" >> "$log"
if [[ "\$1 \$2" == "simctl list" ]]; then
  echo "    iPhone 17 Pro (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Booted)"
fi
exit 0
SH
  cat > "$sandbox/bin/xcodebuild" <<SH
#!/bin/bash
echo "xcodebuild \$1" >> "$log"
echo "Test Case '-[WheelAccessibilityTests testWheelIsAdjustable]' passed"
echo "Test Suite 'All tests' passed"
echo "	 $executed_line"
echo "** TEST SUCCEEDED **"
exit $xcodebuild_exit
SH
  chmod +x "$sandbox/bin/xcodegen" "$sandbox/bin/xcrun" "$sandbox/bin/xcodebuild"

  local status=0
  PATH="$sandbox/bin:$PATH" HOME="$sandbox/home" \
    "$sandbox/repo/Tools/uitest-accessibility.sh" >"$out" 2>&1 || status=$?

  local ok=1
  if [[ "$expect_exit" == "0" ]]; then
    [[ $status -eq 0 ]] || ok=0
    grep -q "^xcodebuild test" "$log" || ok=0
    # The filtered display must survive the fix: the summary line is the one
    # a human reads off a green run.
    grep -q "Executed" "$out" || ok=0
  else
    # A failing xcodebuild, or a run that executed zero tests, must fail —
    # whatever passing-looking lines the output carried. This is exactly
    # what `|| true` used to swallow.
    [[ $status -ne 0 ]] || ok=0
  fi

  if [[ $ok -eq 1 ]]; then
    echo "PASS  $name"
  else
    echo "FAIL  $name (script exit $status; log: $(tr '\n' '|' < "$log"))"
    FAILURES=$((FAILURES + 1))
  fi
  rm -rf "$sandbox"
}

run_case "a failing xcodebuild cannot pass on its summary line" \
  "Executed 7 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds" 65 1
run_case "a scheme that ran zero tests is not a pass" \
  "Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds" 0 1
run_case "a passing non-zero run passes" \
  "Executed 7 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds" 0 0

if [[ $FAILURES -gt 0 ]]; then
  echo "==> uitest-accessibility-gate: $FAILURES failure(s)"
  exit 1
fi
echo "==> uitest-accessibility-gate: all cases pass"
