#!/bin/bash
# The rotation script's failure windows (GitHub #9), driven in a sandbox
# with the probe stubbed via ROTATE_PROBE_CMD — no network, no real key.
# macOS-only (PlistBuddy), like the script under test; deliberately NOT in
# the ubuntu L0 CI job for that reason.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"
PASS=0; FAIL=0

check() { # name expected got
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"; fi
}

new_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/repo/Tools" "$SANDBOX/repo/HeikoTranslate/Resources"
  cp "$REPO/Tools/rotate-key.sh" "$SANDBOX/repo/Tools/"
  /usr/libexec/PlistBuddy -c "Add :GEMINI_API_KEY string OLD-KEY-VALUE" \
    "$SANDBOX/repo/HeikoTranslate/Resources/Secrets.plist" >/dev/null
  git -C "$SANDBOX/repo" init -q -b main
  printf 'HeikoTranslate/Resources/Secrets.plist\nprivate/\n' > "$SANDBOX/repo/.gitignore"
  git -C "$SANDBOX/repo" -c user.email=t@t -c user.name=t add -A
  git -C "$SANDBOX/repo" -c user.email=t@t -c user.name=t commit -qm base
}

key_in() { /usr/libexec/PlistBuddy -c "Print :GEMINI_API_KEY" "$SANDBOX/repo/HeikoTranslate/Resources/Secrets.plist"; }

echo "--- rotation with a passing probe"
new_sandbox
status=0
printf 'NEW-KEY-VALUE\n' | (cd "$SANDBOX/repo" && ROTATE_PROBE_CMD=true ./Tools/rotate-key.sh) >"$SANDBOX/out" 2>&1 || status=$?
check "exit" 0 "$status"
check "key written" "NEW-KEY-VALUE" "$(key_in)"
check "backup exists" 1 "$(find "$SANDBOX/repo/private" -name "*.pre-rotation.*" | wc -l | tr -d ' ')"
check "key never printed" 0 "$(grep -c "NEW-KEY-VALUE" "$SANDBOX/out")"
rm -rf "$SANDBOX"

echo "--- rotation with a FAILING probe keeps the new key, loudly"
new_sandbox
status=0
printf 'NEW-KEY-VALUE\n' | (cd "$SANDBOX/repo" && ROTATE_PROBE_CMD=false ./Tools/rotate-key.sh) >"$SANDBOX/out" 2>&1 || status=$?
check "exit nonzero" 2 "$status"
check "new key STAYS" "NEW-KEY-VALUE" "$(key_in)"
check "revert command shown" 1 "$(grep -c "revert with" "$SANDBOX/out")"
check "API-weather caveat shown" 1 "$(grep -c "not proof the key is bad" "$SANDBOX/out")"
check "key never printed" 0 "$(grep -c "NEW-KEY-VALUE" "$SANDBOX/out")"
rm -rf "$SANDBOX"

echo "--- empty and placeholder input write nothing"
new_sandbox
status=0
printf '\n' | (cd "$SANDBOX/repo" && ROTATE_PROBE_CMD=true ./Tools/rotate-key.sh) >/dev/null 2>&1 || status=$?
check "empty refused" 1 "$status"
status=0
printf 'REPLACE-ME\n' | (cd "$SANDBOX/repo" && ROTATE_PROBE_CMD=true ./Tools/rotate-key.sh) >/dev/null 2>&1 || status=$?
check "placeholder refused" 1 "$status"
check "old key untouched" "OLD-KEY-VALUE" "$(key_in)"
rm -rf "$SANDBOX"

echo "--- a TRACKED Secrets.plist stops the rotation with the real warning"
new_sandbox
( cd "$SANDBOX/repo" && rm .gitignore && git -c user.email=t@t -c user.name=t add -A \
  && git -c user.email=t@t -c user.name=t commit -qm tracked )
status=0
printf 'NEW-KEY-VALUE\n' | (cd "$SANDBOX/repo" && ROTATE_PROBE_CMD=true ./Tools/rotate-key.sh) >"$SANDBOX/out" 2>&1 || status=$?
check "tracked refused" 1 "$status"
check "names the emergency" 1 "$(grep -c "TRACKED by git" "$SANDBOX/out")"
check "old key untouched" "OLD-KEY-VALUE" "$(key_in)"
rm -rf "$SANDBOX"

echo "=========================================="
echo "rotate-key windows: $PASS passed, $FAIL failed"
echo "=========================================="
[[ $FAIL -eq 0 ]]
