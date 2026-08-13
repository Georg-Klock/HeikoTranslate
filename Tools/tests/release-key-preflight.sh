#!/bin/bash
# A build whose bundled Secrets.plist cannot possibly hold a working key must
# never get past the preflight (GitHub #89). release.sh archives and uploads
# whatever HeikoTranslate/Resources/Secrets.plist happens to contain — the
# template's REPLACE-ME, a blank key, or no file at all — and none of the
# other gates can catch it: L1 never exercises the key, L3 takes its key from
# Tools/local.env, and the build succeeds regardless because the plist is a
# bundled resource, not compiled. deploy.sh shares the risk at lower stakes.
#
# Same idiom as build-number-windows.sh: throwaway git repos running the REAL
# release.sh and deploy.sh (copied, not re-implemented) against stubs. No
# network, no Xcode; finishes in a couple of seconds.
#
# The preflight must also never print the key's value — the whole point of
# Secrets.plist being gitignored is that the key exists nowhere public, and a
# gate that echoes it into a terminal (and from there into a pasted log)
# would undo that. Every case's captured output is searched for the fixture
# key at the end.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"

PASS=0
FAIL=0

# Obviously invented, and deliberately not UUID-shaped (privacy-check.sh
# fails any UUID-shaped string that is not registered as synthetic) and not
# shaped like a real Gemini key. The point is only that it is present,
# non-empty, and not the template placeholder.
FAKE_KEY="INVENTED-TEST-KEY-000000000000000000000"

# ALL_OUT accumulates every case's output for the never-prints-the-key sweep.
ALL_OUT=$(mktemp)
trap 'rm -f "$ALL_OUT"' EXIT

new_repo() { # new_repo <plist_state: missing|blank|template|valid|valid_with_url>
  SANDBOX=$(mktemp -d)
  REPO_DIR="$SANDBOX/repo"
  mkdir -p "$REPO_DIR/Tools" "$REPO_DIR/HeikoTranslate/Resources" "$SANDBOX/bin"
  cat > "$REPO_DIR/project.yml" <<'YML'
name: HeikoTranslate
targets:
  HeikoTranslate:
    info:
      properties:
        CFBundleShortVersionString: "2.3"
        CFBundleVersion: "40"
YML
  cp "$REPO/Tools/release.sh" "$REPO/Tools/deploy.sh" "$REPO/Tools/build_number.sh" \
    "$REPO/Tools/ios_device.sh" "$REPO/Tools/pull_logs.sh" "$REPO_DIR/Tools/"
  # release.sh sources the preflight helper once it exists; tolerate its
  # absence so the fail-first run against the unfixed script still runs.
  [ -f "$REPO/Tools/secrets_preflight.sh" ] \
    && cp "$REPO/Tools/secrets_preflight.sh" "$REPO_DIR/Tools/"
  cp "$REPO/Tools/ExportOptions.plist.example" "$REPO/Tools/ExportUpload.plist.example" \
    "$REPO_DIR/Tools/"
  cp "$REPO/HeikoTranslate/Resources/Secrets.plist.example" \
    "$REPO_DIR/HeikoTranslate/Resources/"
  # Secrets.plist is gitignored in the real repo too; if it were tracked (or
  # untracked but visible), release.sh's own dirty-tree guard would fire and
  # mask the refusal under test.
  printf 'Tools/local.env\nHeikoTranslate/Resources/Secrets.plist\n' > "$REPO_DIR/.gitignore"
  printf 'DEVICE_UUID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"\nDEVELOPMENT_TEAM="EXAMPLETEAM"\n' \
    > "$REPO_DIR/Tools/local.env"
  # The gate must stop BEFORE the test gate: a distinctive exit from the L1
  # stub is how a case proves the run got past the refusal (or never reached
  # this far because of it). Same trick as release-rejects-l3-overrides.sh.
  printf '#!/bin/bash\nexit 55\n' > "$REPO_DIR/Tools/l1.sh"
  printf '#!/bin/bash\nexit 0\n' > "$REPO_DIR/Tools/l3replay.sh"
  chmod +x "$REPO_DIR"/Tools/*.sh

  write_plist "$1" "$REPO_DIR/HeikoTranslate/Resources/Secrets.plist"

  git -C "$REPO_DIR" init -q -b main
  git -C "$REPO_DIR" -c user.email=t@t -c user.name=t add -A
  git -C "$REPO_DIR" -c user.email=t@t -c user.name=t commit -qm "base"

  # The preflight extracts the key with the host's own plutil, which the
  # machines that actually cut releases have. On a machine without one
  # (Linux CI), substitute a stub that honours the exact contract the real
  # tool was verified to have: `-extract <key> raw -o - <file>` prints the
  # string value (empty string included) and exits 0; a missing key exits 1.
  if ! command -v plutil >/dev/null 2>&1; then
    cat > "$SANDBOX/bin/plutil" <<'SH'
#!/bin/bash
[[ "${1:-}" == "-extract" && "${3:-}" == "raw" ]] || exit 1
field="$2"
plist="${*: -1}"
[[ -f "$plist" ]] || exit 1
value_line=$(grep -A1 "<key>$field</key>" "$plist" | tail -1)
if [[ "$value_line" =~ \<string\>(.*)\</string\> ]]; then
  printf '%s\n' "${BASH_REMATCH[1]}"
  exit 0
fi
exit 1
SH
    chmod +x "$SANDBOX/bin/plutil"
  fi
}

write_plist() { # write_plist <state> <path>
  local state=$1 path=$2
  case "$state" in
    missing)
      rm -f "$path" ;;
    blank)
      plist_body "" > "$path" ;;
    whitespace)
      plist_body "   " > "$path" ;;
    template_trailing)
      plist_body "REPLACE-ME " > "$path" ;;
    template)
      # The literal template, byte for byte — the exact artifact a fresh
      # checkout is told to copy into place, and the state #89 describes.
      cp "$REPO/HeikoTranslate/Resources/Secrets.plist.example" "$path" ;;
    valid)
      plist_body "$FAKE_KEY" > "$path" ;;
    valid_with_url)
      plist_body "$FAKE_KEY" URL > "$path" ;;
    *) echo "unknown plist state: $state" >&2; exit 2 ;;
  esac
}

plist_body() { # plist_body <key_value> [URL]
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>GEMINI_API_KEY</key>
    <string>$1</string>
EOF
  if [[ "${2:-}" == "URL" ]]; then
    cat <<'EOF'
    <key>APP_UPDATE_URL</key>
    <string>https://apps.apple.com/invented-fixture</string>
EOF
  fi
  cat <<'EOF'
</dict>
</plist>
EOF
}

check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); printf '      ok   %s = %s\n' "$1" "$3"
  else
    FAIL=$((FAIL + 1)); printf '      FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
  fi
}

# run_case <script> <plist_state> <expected_exit> <expect_refusal:yes|no>
run_case() {
  local script=$1 state=$2 expected_exit=$3 expect_refusal=$4
  echo
  echo "--- $script: $state plist"
  new_repo "$state"
  local out="$SANDBOX/out" status=0
  (cd "$REPO_DIR" && PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX" \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    "./Tools/$script") >"$out" 2>&1 || status=$?
  cat "$out" >> "$ALL_OUT"

  check "exit" "$expected_exit" "$status"
  if [[ "$expect_refusal" == "yes" ]]; then
    check "names Secrets.plist" 1 \
      "$(grep -q 'Secrets.plist' "$out" && echo 1 || echo 0)"
    # Stopped before anything moved: the bump has not happened yet, so
    # nothing needs restoring — the number and the history are simply intact.
    check "build number untouched" 40 \
      "$(grep 'CFBundleVersion:' "$REPO_DIR/project.yml" | sed 's/.*"\(.*\)"/\1/')"
    check "nothing committed" 1 "$(git -C "$REPO_DIR" rev-list --count HEAD)"
    check "tree clean" clean \
      "$([[ -z "$(git -C "$REPO_DIR" status --porcelain)" ]] && echo clean || echo dirty)"
  fi
  rm -rf "$SANDBOX"
}

# The three states that cannot possibly be right stop before the test gate,
# the bump, or anything else moves. Exit 55 is the L1 stub: reaching it IS
# the proof that a valid key sails through the preflight to the test gate.
run_case release.sh missing  2 yes
run_case release.sh blank    2 yes
run_case release.sh template 2 yes
run_case release.sh valid   55 no

# Whitespace is not a key. A whitespace-only value slipped past the plain
# emptiness check, and REPLACE-ME with a trailing space slipped past the
# exact comparison — both found by review against the real plutil, which
# preserves the whitespace faithfully. The preflight trims before checking.
run_case release.sh whitespace        2 yes
run_case release.sh template_trailing 2 yes

# deploy.sh shares the preflight: same three refusals, and the same proof
# that a valid key reaches its L1 gate.
run_case deploy.sh missing  2 yes
run_case deploy.sh blank    2 yes
run_case deploy.sh template 2 yes
run_case deploy.sh valid   55 no

# APP_UPDATE_URL is a warning, never a refusal (#89, #9): a release without
# it still runs — all the way to the test gate — but says what the missing
# key means. A release with it stays quiet.
echo
echo "--- release.sh: valid key, no APP_UPDATE_URL -> warns, does not stop"
new_repo valid
out="$SANDBOX/out"; status=0
(cd "$REPO_DIR" && PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX" ./Tools/release.sh) \
  >"$out" 2>&1 || status=$?
cat "$out" >> "$ALL_OUT"
check "exit (reached the test gate)" 55 "$status"
check "warns about APP_UPDATE_URL" 1 "$(grep -q 'APP_UPDATE_URL' "$out" && echo 1 || echo 0)"
rm -rf "$SANDBOX"

echo
echo "--- release.sh: valid key with APP_UPDATE_URL -> no warning"
new_repo valid_with_url
out="$SANDBOX/out"; status=0
(cd "$REPO_DIR" && PATH="$SANDBOX/bin:$PATH" HOME="$SANDBOX" ./Tools/release.sh) \
  >"$out" 2>&1 || status=$?
cat "$out" >> "$ALL_OUT"
check "exit (reached the test gate)" 55 "$status"
check "no APP_UPDATE_URL warning" 0 "$(grep -c 'APP_UPDATE_URL' "$out" || true)"
rm -rf "$SANDBOX"

# The sweep: no case, refusal or pass, may ever print the key's value.
echo
echo "--- no case prints the key's value"
check "key value absent from every output" 0 "$(grep -c "$FAKE_KEY" "$ALL_OUT" || true)"

echo
echo "=========================================="
printf 'release-key-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "=========================================="
[[ $FAIL -eq 0 ]]
