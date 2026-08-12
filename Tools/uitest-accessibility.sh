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
xcodebuild test -project HeikoTranslate.xcodeproj \
  -scheme HeikoTranslateAccessibility -destination "$DEST" 2>&1 \
  | grep -E "Test Case|Executed|error:|\*\* " || true
