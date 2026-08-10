#!/bin/bash
# L0 test for Tools/l3direction.sh (#84 review): the gate must exit 0 only
# when every run is CORRECT, and must distinguish WRONG (real failure),
# INCONCLUSIVE (session errors — rerun), and CRASHED (no l3replay summary
# at all). Stubs l3replay.sh; runs in seconds, no network, no Xcode.
set -uo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Tools" "$tmp/TestAudio" "$tmp/.build"
cp "$here/Tools/l3direction.sh" "$tmp/Tools/"
touch "$tmp/TestAudio/de_after_es.wav"

pass=0; fail=0
check() {
  local label="$1" want="$2"
  rm -f "$tmp/.count"
  set +e
  (cd "$tmp" && Tools/l3direction.sh TestAudio/de_after_es.wav 3 ".build/$label" >".build/$label.out" 2>&1)
  local got=$?
  set -e 2>/dev/null || true
  if [[ "$got" == "$want" ]]; then
    pass=$((pass+1)); echo "✅ $label (exit $got)"
  else
    fail=$((fail+1)); echo "❌ $label: wanted exit $want, got $got"
    sed 's/^/    /' "$tmp/.build/$label.out" 2>/dev/null | tail -6
  fi
}

# The stub counts invocations so one specific run in the loop can misbehave.
stub() {
  cat >"$tmp/Tools/l3replay.sh" <<'STUB'
#!/bin/bash
n=$(cat "$(dirname "$0")/../.count" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$(dirname "$0")/../.count"
STUB
  cat >>"$tmp/Tools/l3replay.sh"
  chmod +x "$tmp/Tools/l3replay.sh"
}

correct_run='cat <<EOF
    bubble 1: LEFT (foreign) via de [finalized 5.0s]
    bubble 2: RIGHT (home) via es [finalized 10.0s]
12 passed, 0 failed
EOF'

wrong_run='cat <<EOF
    bubble 1: LEFT (foreign) via de [finalized 5.0s]
    bubble 2: LEFT (foreign) via de [finalized 10.0s]
10 passed, 2 failed
EOF'

inconclusive_run='cat <<EOF
  ❌ no session errors: [es] session closed mid-replay
0 passed, 12 failed
EOF'

stub <<EOF
$correct_run
EOF
check all-correct 0

stub <<EOF
if [ "\$n" = 2 ]; then $wrong_run
else $correct_run
fi
EOF
check one-wrong-fails 1

stub <<EOF
if [ "\$n" = 2 ]; then $inconclusive_run
else $correct_run
fi
EOF
check one-inconclusive-fails 1

stub <<EOF
if [ "\$n" = 2 ]; then
  echo "swiftc: error: something did not compile" >&2
  exit 1
else $correct_run
fi
EOF
check one-crashed-fails 1

# A result-shaped log is not evidence if the nested replay itself failed.
# l3direction must check the exit status before it accepts the summary.
stub <<EOF
if [ "\$n" = 2 ]; then
  $correct_run
  exit 1
else $correct_run
fi
EOF
check summary-plus-failure-fails 1

# Run-count validation: garbage must not silently become a zero-run pass.
set +e
(cd "$tmp" && Tools/l3direction.sh TestAudio/de_after_es.wav banana >/dev/null 2>&1)
got=$?
if [[ "$got" == 2 ]]; then pass=$((pass+1)); echo "✅ bad-run-count-rejected (exit 2)"
else fail=$((fail+1)); echo "❌ bad-run-count-rejected: wanted exit 2, got $got"; fi

echo
echo "$pass passed, $fail failed"
exit $((fail > 0 ? 1 : 0))
