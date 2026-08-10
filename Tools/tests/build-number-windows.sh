#!/bin/bash
# Proves the build-number invariant survives failure at every point in
# deploy.sh and release.sh: **every number that ever reaches a screen or Apple
# exists in exactly one commit, and no number is ever reverted after that.**
#
#   Tools/tests/build-number-windows.sh
#
# That invariant is the whole point of #16, and #22 found two holes in it that
# only open when something fails midway — so the only way to check the fix is
# to make things fail midway. Each case builds a throwaway git repo, copies the
# REAL scripts into it (they `cd` to their own parent, so they run against the
# fake repo), and puts stub xcrun/xcodebuild/xcodegen on PATH that fail exactly
# where the case says. No copy of the scripts' logic lives here — the thing
# under test is the thing that ships.
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"

PASS=0
FAIL=0
KEEP="${KEEP:-0}"

# --- harness ---------------------------------------------------------------

# A fake project with the same shape deploy.sh/release.sh read and rewrite.
# Everything the harness owns (stubs, captured output, the fake DerivedData
# tree) lives OUTSIDE the git repo, or the scripts' own dirty-tree checks would
# be reacting to the test rig instead of to the code under test.
new_repo() {
  SANDBOX=$(mktemp -d)
  REPO_DIR="$SANDBOX/repo"
  mkdir -p "$REPO_DIR/Tools" "$SANDBOX/bin"
  # deploy.sh resolves the built .app under $HOME; give it one to find.
  mkdir -p "$SANDBOX/Library/Developer/Xcode/DerivedData/HeikoTranslate-aaa/Build/Products/Debug-iphoneos/HeikoTranslate.app"
  cat > "$REPO_DIR/project.yml" <<'YML'
name: HeikoTranslate
targets:
  HeikoTranslate:
    info:
      properties:
        CFBundleShortVersionString: "2.3"
        CFBundleVersion: "40"
YML
  cp "$REPO/Tools/deploy.sh" "$REPO/Tools/release.sh" "$REPO_DIR/Tools/"
  printf '#!/bin/bash\nexit 0\n' > "$REPO_DIR/Tools/pull_logs.sh"
  printf '#!/bin/bash\nexit 0\n' > "$REPO_DIR/Tools/l3replay.sh"
  chmod +x "$REPO_DIR"/Tools/*.sh
  git -C "$REPO_DIR" init -q -b main
  git -C "$REPO_DIR" -c user.email=t@t -c user.name=t add -A
  git -C "$REPO_DIR" -c user.email=t@t -c user.name=t commit -qm "base"
}

# Stubs. FAIL_AT names the step that should fail; everything else succeeds.
# This is how a locked phone, a dropped cable, or a rejected archive is
# reproduced without any of them being present.
write_stubs() {
  cat > "$SANDBOX/bin/xcodegen" <<'SH'
#!/bin/bash
exit 0
SH
  cat > "$SANDBOX/bin/xcodebuild" <<'SH'
#!/bin/bash
case " $* " in
  *" test "*)    [[ "${FAIL_AT:-}" == "l1"      ]] && exit 65 ;;
  *" archive "*) [[ "${FAIL_AT:-}" == "archive" ]] && exit 65 ;;
  *"-exportArchive"*)
    [[ "${FAIL_AT:-}" == "upload" ]] && exit 70
    [[ "${FAIL_AT:-}" == "sigterm_after_upload" ]] && kill -TERM "$PPID" ;;
  *)             [[ "${FAIL_AT:-}" == "build"   ]] && exit 65
                 [[ "${FAIL_AT:-}" == "sigterm_during_build" ]] && kill -TERM "$PPID" ;;
esac
exit 0
SH
  cat > "$SANDBOX/bin/xcrun" <<'SH'
#!/bin/bash
# devicectl: list / install / info
case " $* " in
  *"list devices"*)
    [[ "${FAIL_AT:-}" == "nophone" ]] && { echo "no devices"; exit 0; }
    echo "iPhone  connected"; exit 0 ;;
  *"install app"*)
    [[ "${FAIL_AT:-}" == "install" ]] && exit 1
    touch "$SANDBOX_MARK/installed"; exit 0 ;;
  *"info apps"*)
    # The #22.1 window: this used to be a fatal pipeline AFTER the install.
    [[ "${FAIL_AT:-}" == "install_info" ]] && exit 0   # prints nothing -> grep fails
    # Ctrl-C's stand-in, delivered past the point of no return. SIGTERM rather
    # than SIGINT because SIGINT is not deliverable to a background job the way
    # a terminal delivers it; both go through the same handler.
    [[ "${FAIL_AT:-}" == "sigterm_after_install" ]] && kill -TERM "$PPID"
    echo "com.klock.heikotranslate  HeikoTranslate"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$SANDBOX"/bin/*
}

# A git that refuses to commit, to reach the "already uploaded and I cannot
# record it" branch — the one failure the script cannot recover from itself.
write_failing_git() {
  cat > "$SANDBOX/bin/git" <<SH
#!/bin/bash
for a in "\$@"; do [[ "\$a" == "commit" ]] && exit 1; done
exec /usr/bin/git "\$@"
SH
  chmod +x "$SANDBOX/bin/git"
}

build_number() { grep 'CFBundleVersion:' "$REPO_DIR/project.yml" | sed 's/.*"\(.*\)"/\1/'; }
head_subject() { git -C "$REPO_DIR" log -1 --pretty=%s; }
is_dirty()     { [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]] && echo dirty || echo clean; }

check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); printf '      ok   %s = %s\n' "$1" "$3"
  else
    FAIL=$((FAIL + 1)); printf '      FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
  fi
}

run() { # run <script> [args...]   — with stubs and FAIL_AT in effect
  local script="$1"; shift
  ( cd "$REPO_DIR" \
    && SANDBOX_MARK="$SANDBOX" PATH="$SANDBOX/bin:$PATH" \
       HOME="$SANDBOX" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
       "./Tools/$script" "$@" ) >"$SANDBOX/out" 2>&1
  echo $?
}

case_start() { echo; echo "--- $1"; new_repo; write_stubs; }
case_end()   { [[ "$KEEP" == "1" ]] || rm -rf "$SANDBOX"; }

# --- deploy.sh -------------------------------------------------------------

case_start "deploy: happy path commits the number it installed"
  status=$(FAIL_AT= run deploy.sh)
  check "exit"          0             "$status"
  check "build number"  41            "$(build_number)"
  check "head"          "Build 2.3.41 (device)" "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end

case_start "deploy: build fails before install -> number goes back"
  status=$(FAIL_AT=build run deploy.sh)
  check "exit"          65            "$status"
  check "build number"  40            "$(build_number)"
  check "head"          base          "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end

case_start "deploy: phone never appears -> number goes back"
  status=$(FAIL_AT=nophone run deploy.sh --wait 1)
  check "exit"          1             "$status"
  check "build number"  40            "$(build_number)"
  check "tree"          clean         "$(is_dirty)"
case_end

# #22.1 — the regression this issue was filed for.
case_start "deploy: post-install info line fails -> number is COMMITTED, not reverted"
  status=$(FAIL_AT=install_info run deploy.sh)
  check "installed"     yes           "$([[ -e "$SANDBOX/installed" ]] && echo yes || echo no)"
  check "build number"  41            "$(build_number)"
  check "head"          "Build 2.3.41 (device)" "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end

# #22.3 — the revert must not eat unrelated work.
case_start "deploy: a failed deploy preserves unrelated project.yml edits"
  printf '# a hand edit made while the deploy was running\n' >> "$REPO_DIR/project.yml"
  status=$(FAIL_AT=build run deploy.sh)
  check "build number"  40            "$(build_number)"
  check "hand edit kept" yes          "$(grep -q 'a hand edit' "$REPO_DIR/project.yml" && echo yes || echo no)"
case_end

# --- release.sh ------------------------------------------------------------

case_start "release: archive fails -> number goes back, tree left clean"
  status=$(FAIL_AT=archive run release.sh)
  check "exit"          65            "$status"
  check "build number"  40            "$(build_number)"
  check "head"          base          "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end

case_start "release: L1 fails before the bump -> nothing moved"
  status=$(FAIL_AT=l1 run release.sh)
  check "exit"          65            "$status"
  check "build number"  40            "$(build_number)"
  check "tree"          clean         "$(is_dirty)"
case_end

# Expectation CHANGED after the #33 review. An exit code cannot tell "never
# reached Apple" from "Apple took it and then something failed", and the two
# mistakes are not symmetric: a burned number skips one in a counter that is
# only ever required to increase, while reverting a number TestFlight already
# holds is permanent — it will not accept that number twice. So a failed upload
# burns its number and records why.
case_start "release: upload fails -> number is BURNED, not reverted"
  status=$(FAIL_AT=upload run release.sh)
  check "exit"          70            "$status"
  check "build number"  41            "$(build_number)"
  check "head"          "Release 2.3.41" "$(head_subject)"
  check "commit says why" yes \
        "$(git -C "$REPO_DIR" log -1 --pretty=%B | grep -q 'burned deliberately' && echo yes || echo no)"
  check "tree"          clean         "$(is_dirty)"
case_end

case_start "deploy: the install command itself fails -> number is BURNED, not reverted"
  status=$(FAIL_AT=install run deploy.sh)
  check "build number"  41            "$(build_number)"
  check "head"          "Build 2.3.41 (device)" "$(head_subject)"
  check "commit says why" yes \
        "$(git -C "$REPO_DIR" log -1 --pretty=%B | grep -q 'burned deliberately' && echo yes || echo no)"
  check "tree"          clean         "$(is_dirty)"
case_end

case_start "release: happy path uploads and commits"
  status=$(FAIL_AT= run release.sh)
  check "exit"          0             "$status"
  check "build number"  41            "$(build_number)"
  check "head"          "Release 2.3.41" "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end

# #22.2 — the unrecoverable one. Uploaded, and the commit will not go through.
# The script cannot fix this, so the bar is: it must NOT revert, and it must
# say so unmissably.
case_start "release: uploaded but the commit fails -> keeps the number, shouts"
  write_failing_git
  status=$(FAIL_AT= run release.sh)
  check "build number"  41            "$(build_number)"
  check "kept the bump" dirty         "$(is_dirty)"
  check "warns loudly"  yes           "$(grep -q 'ALREADY UPLOADED' "$SANDBOX/out" && echo yes || echo no)"
case_end

case_start "release: dry run archives, reverts, leaves the tree clean"
  status=$(FAIL_AT= run release.sh --dry-run)
  check "exit"          0             "$status"
  check "build number"  40            "$(build_number)"
  check "head"          base          "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end


# --- signals (added after review of #33) ------------------------------------
# EXIT alone does not cover a killed script, and an interrupt mid-run is the
# scenario #22 named for release.sh. Both directions have to hold.

case_start "deploy: signal DURING the build -> number goes back"
  status=$(FAIL_AT=sigterm_during_build run deploy.sh)
  check "exit"          143           "$status"
  check "build number"  40            "$(build_number)"
  check "head"          base          "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end

case_start "deploy: signal AFTER the install -> number is committed"
  status=$(FAIL_AT=sigterm_after_install run deploy.sh)
  check "exit"          143           "$status"
  check "build number"  41            "$(build_number)"
  check "head"          "Build 2.3.41 (device)" "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end

case_start "release: signal AFTER the upload -> number is committed, not reverted"
  status=$(FAIL_AT=sigterm_after_upload run release.sh)
  check "exit"          143           "$status"
  check "build number"  41            "$(build_number)"
  check "head"          "Release 2.3.41" "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end

# --- traceability and recovery (added after review of #33) ------------------

case_start "deploy: a dirty worktree is recorded IN the commit, not just warned about"
  echo "scratch" > "$REPO_DIR/notes.txt"
  status=$(FAIL_AT= run deploy.sh)
  check "exit"          0             "$status"
  check "head"          "Build 2.3.41 (device)" "$(head_subject)"
  check "names the dirty file" yes \
        "$(git -C "$REPO_DIR" log -1 --pretty=%B | grep -q 'notes.txt' && echo yes || echo no)"
case_end

case_start "deploy: --no-bump does not sweep a staged project.yml edit into a Build commit"
  printf '# unrelated staged edit\n' >> "$REPO_DIR/project.yml"
  git -C "$REPO_DIR" add project.yml
  status=$(FAIL_AT= run deploy.sh --no-bump)
  check "exit"          0             "$status"
  check "head"          base          "$(head_subject)"
  check "edit still staged" yes \
        "$(git -C "$REPO_DIR" diff --cached --quiet -- project.yml && echo no || echo yes)"
case_end

case_start "deploy: a failing pre-commit hook cannot lose an installed number"
  mkdir -p "$REPO_DIR/.git/hooks"
  printf '#!/bin/bash\nexit 1\n' > "$REPO_DIR/.git/hooks/pre-commit"
  chmod +x "$REPO_DIR/.git/hooks/pre-commit"
  status=$(FAIL_AT= run deploy.sh)
  check "build number"  41            "$(build_number)"
  check "head"          "Build 2.3.41 (device)" "$(head_subject)"
  check "said it bypassed" yes "$(grep -q 'no-verify' "$SANDBOX/out" && echo yes || echo no)"
case_end

case_start "release: an unrecordable uploaded number leaves a recovery note on disk"
  write_failing_git
  status=$(FAIL_AT= run release.sh)
  check "build number"  41            "$(build_number)"
  check "recovery note" yes           "$([[ -f "$REPO_DIR/.build-number-recovery" ]] && echo yes || echo no)"
  check "note names the build" yes \
        "$(grep -q '2.3.41' "$REPO_DIR/.build-number-recovery" 2>/dev/null && echo yes || echo no)"
case_end

# ---------------------------------------------------------------------------

echo
echo "=========================================="
printf 'build-number windows: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "=========================================="
[[ "$FAIL" == "0" ]]
