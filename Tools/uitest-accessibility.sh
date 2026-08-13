#!/bin/bash
# The LOCAL accessibility verification for the language wheels (#14):
# inspects the real accessibility tree via the UI-test target that is
# deliberately not in CI. Run after touching the wheels or their modifiers.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
xcodegen generate >/dev/null
DEST=${L1_DESTINATION:-'platform=iOS Simulator,name=iPhone 17 Pro'}
# The permission alert would otherwise gate the whole run on a fresh
# container; the harness grants it the way a human tester's first tap would.
SIM=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
[ -n "$SIM" ] && # The simulator stores app preferences at the DEVICE level
# (data/Library/Preferences/<bundle>.plist), where `simctl uninstall`
# cannot reach them — a "fresh install" here inherits whatever pair some
# earlier run persisted, which is how GitHub #81 got filed against an app
# that was never broken. Real iPhones keep preferences in the app
# container, so this is a simulator-only trap. Clear it so every run
# starts from the true first-launch state.
rm -f "$HOME/Library/Developer/CoreSimulator/Devices/$SIM/data/Library/Preferences/com.klock.heikotranslate.plist"
xcrun simctl privacy "$SIM" grant microphone com.klock.heikotranslate 2>/dev/null || true
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

# The pipeline used to end in `|| true` — there because a display grep with
# no matching lines exits 1, which pipefail would turn into a false failure,
# but it swallowed the real status along with the false one: a failing suite,
# a scheme that built zero tests, and a green run were indistinguishable at
# $? (GitHub #88). Same construct as l1.sh: tee the full output aside, read
# xcodebuild's own status out of PIPESTATUS immediately, and let set +e cover
# the harmless empty grep.
set +e
xcodebuild test -project HeikoTranslate.xcodeproj \
  -scheme HeikoTranslateAccessibility -destination "$DEST" 2>&1 \
  | tee "$OUT" | grep -E "Test Case|Executed|error:|\*\* "
PIPE=("${PIPESTATUS[@]}")
set -e
STATUS=${PIPE[0]}

if [[ $STATUS -ne 0 ]]; then
  echo "==> accessibility suite FAILED (xcodebuild exit $STATUS)" >&2
  grep -E "error:|failed" "$OUT" | head -20 >&2 || true
  exit "$STATUS"
fi

# The suite must have run, and it must have run a non-zero number of tests —
# a scheme that silently builds no test target exits 0 and looks identical
# to a pass. Same assertion as l1.sh.
if ! grep -qE "Executed [1-9][0-9]* tests?, with 0 failures" "$OUT"; then
  echo "==> the accessibility suite did not report a passing non-zero test count — refusing to call this a pass." >&2
  grep -E "Executed .* tests?" "$OUT" | tail -5 >&2 || echo "  (no 'Executed' line at all)" >&2
  exit 1
fi

echo "==> accessibility verification passed"
