#!/bin/bash
# A release must be impossible to green while L3's diagnostic switches are
# armed (GitHub #19). L3_ALLOW_RAW=1 downgrades protocol drift from a failure
# back to a warning, and L3_INJECT_RAW=1 seeds a synthetic failing frame —
# both are for investigating a drift in a scratch shell, and release.sh must
# refuse a shell that still has either exported, before it tests, bumps, or
# builds anything.
#
# Same idiom as build-number-windows.sh: a throwaway git repo running the
# REAL release.sh (copied, not re-implemented) against stubs. No network,
# no Xcode; finishes in a couple of seconds.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"

PASS=0
FAIL=0

new_repo() {
  SANDBOX=$(mktemp -d)
  REPO_DIR="$SANDBOX/repo"
  mkdir -p "$REPO_DIR/Tools" "$SANDBOX/bin"
  cat > "$REPO_DIR/project.yml" <<'YML'
name: HeikoTranslate
targets:
  HeikoTranslate:
    info:
      properties:
        CFBundleShortVersionString: "2.3"
        CFBundleVersion: "40"
YML
  cp "$REPO/Tools/release.sh" "$REPO/Tools/build_number.sh" \
    "$REPO/Tools/secrets_preflight.sh" "$REPO_DIR/Tools/"
  cp "$REPO/Tools/ExportOptions.plist.example" "$REPO/Tools/ExportUpload.plist.example" \
    "$REPO_DIR/Tools/"
  # A plausible bundled key, so the #89 preflight (which sits between the
  # override guard and the test gate) cannot be what stops these runs. The
  # key is invented; Tools/tests/release-key-preflight.sh owns the refusals.
  mkdir -p "$REPO_DIR/HeikoTranslate/Resources"
  cat > "$REPO_DIR/HeikoTranslate/Resources/Secrets.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>GEMINI_API_KEY</key>
    <string>INVENTED-L0-KEY-000000000000000000000</string>
    <key>APP_UPDATE_URL</key>
    <string>https://apps.apple.com/invented-fixture</string>
</dict>
</plist>
PLIST
  printf 'Tools/local.env\nHeikoTranslate/Resources/Secrets.plist\n' > "$REPO_DIR/.gitignore"
  printf 'DEVELOPMENT_TEAM="EXAMPLETEAM"\n' > "$REPO_DIR/Tools/local.env"
  # The gate must be the FIRST thing that can fail after the standing guards:
  # a distinctive exit from the L1 stub is how a case proves the run got past
  # the refusal (or never reached this far because of it).
  printf '#!/bin/bash\nexit 55\n' > "$REPO_DIR/Tools/l1.sh"
  printf '#!/bin/bash\nexit 0\n' > "$REPO_DIR/Tools/l3replay.sh"
  chmod +x "$REPO_DIR"/Tools/*.sh
  git -C "$REPO_DIR" init -q -b main
  git -C "$REPO_DIR" -c user.email=t@t -c user.name=t add -A
  git -C "$REPO_DIR" -c user.email=t@t -c user.name=t commit -qm "base"
}

# run_release <name> <expected_exit> <expect_refusal:yes|no> [VAR=VAL ...]
run_release() {
  local name=$1 expected_exit=$2 expect_refusal=$3
  shift 3
  new_repo
  local out="$SANDBOX/release.out" status=0
  (cd "$REPO_DIR" && env "$@" HOME="$SANDBOX" PATH="$SANDBOX/bin:$PATH" \
    ./Tools/release.sh --dry-run) >"$out" 2>&1 || status=$?

  local ok=1 why=""
  [[ $status -eq $expected_exit ]] || { ok=0; why="exit $status, wanted $expected_exit"; }
  if [[ "$expect_refusal" == "yes" ]]; then
    grep -q "L3_ALLOW_RAW/L3_INJECT_RAW is set" "$out" || { ok=0; why="$why; no refusal message"; }
    # Refused before anything ran or changed: no bump, no commit beyond base.
    grep -q 'CFBundleVersion: "40"' "$REPO_DIR/project.yml" || { ok=0; why="$why; build number moved"; }
    [[ "$(git -C "$REPO_DIR" rev-list --count HEAD)" == "1" ]] || { ok=0; why="$why; something was committed"; }
  else
    grep -q "L3_ALLOW_RAW/L3_INJECT_RAW is set" "$out" && { ok=0; why="$why; refused a clean environment"; }
  fi

  if [[ $ok -eq 1 ]]; then
    echo "PASS  $name"; PASS=$((PASS + 1))
  else
    echo "FAIL  $name ($why)"; FAIL=$((FAIL + 1)); sed 's/^/      /' "$out" | tail -8
  fi
  rm -rf "$SANDBOX"
}

run_release "L3_ALLOW_RAW=1 is refused outright"            2 yes L3_ALLOW_RAW=1
run_release "L3_INJECT_RAW=1 is refused outright"           2 yes L3_INJECT_RAW=1
run_release "both set are refused outright"                 2 yes L3_ALLOW_RAW=1 L3_INJECT_RAW=1
run_release "any non-empty value is refused, not just \"1\"" 2 yes L3_ALLOW_RAW=yes
# The control: a clean environment sails past the guard and fails at the L1
# stub's distinctive exit — proof the refusal is the overrides' doing alone.
run_release "a clean environment reaches the test gate"    55 no

echo "=========================================="
echo "release-rejects-l3-overrides: $PASS passed, $FAIL failed"
echo "=========================================="
[[ $FAIL -eq 0 ]]
