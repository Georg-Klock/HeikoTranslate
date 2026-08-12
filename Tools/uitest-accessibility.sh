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
[ -n "$SIM" ] && xcrun simctl privacy "$SIM" grant microphone com.klock.heikotranslate 2>/dev/null || true
xcodebuild test -project HeikoTranslate.xcodeproj \
  -scheme HeikoTranslateAccessibility -destination "$DEST" 2>&1 \
  | grep -E "Test Case|Executed|error:|\*\* " || true
