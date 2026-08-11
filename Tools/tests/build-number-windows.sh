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
  cp "$REPO/Tools/deploy.sh" "$REPO/Tools/release.sh" "$REPO/Tools/pull_logs.sh" \
    "$REPO/Tools/ios_device.sh" "$REPO_DIR/Tools/"
  cp "$REPO/Tools/ExportOptions.plist.example" "$REPO/Tools/ExportUpload.plist.example" \
    "$REPO_DIR/Tools/"
  printf 'Tools/local.env\n' > "$REPO_DIR/.gitignore"
  printf 'DEVICE_UUID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"\nDEVELOPMENT_TEAM="EXAMPLETEAM"\n' \
    > "$REPO_DIR/Tools/local.env"
  # Exercise the scripts' L1 call without copying the simulator-specific gate
  # into this deterministic shell harness. The xcodebuild stub below controls
  # whether this step succeeds or fails.
  printf '#!/bin/bash\nxcodebuild test\n' > "$REPO_DIR/Tools/l1.sh"
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
  # First, so the settings query can never trip the build-failure branches.
  # Answers the shape deploy.sh parses (GitHub #3): the fake DerivedData the
  # sandbox sets up, named exactly.
  *"-showBuildSettings"*)
    printf 'Build settings for action build and target HeikoTranslate:\n'
    printf '    TARGET_BUILD_DIR = %s\n' "$HOME/Library/Developer/Xcode/DerivedData/HeikoTranslate-aaa/Build/Products/Debug-iphoneos"
    printf '    FULL_PRODUCT_NAME = HeikoTranslate.app\n'
    exit 0 ;;
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
    json_path=""
    filter=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --filter) filter="${2:-}"; shift 2 ;;
        --json-output) json_path="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done

    # The production helper intentionally uses devicectl's documented JSON
    # interface. These fixtures make the fake command obey its exact filter:
    # `UUID|state|name|type` per line. A state is reachable only when its
    # explicit predicate appears in the requested filter; names and UUIDs
    # must match their respective literal filters too. That makes a
    # text-parsing regression fail this test rather than merely exercise the
    # happy path.
    fixtures="${DEVICE_FIXTURE:-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|connected|Example iPhone|iPhone}"
    if [[ -z "$json_path" ]]; then
      if [[ -n "${DEVICE_LISTING:-}" ]]; then
        printf '%s\n' "$DEVICE_LISTING"
      elif [[ "${FAIL_AT:-}" == "nophone" ]]; then
        echo "no devices"
      else
        while IFS='|' read -r fixture_uuid fixture_state fixture_name fixture_type; do
          printf '%s  %s  %s\n' "$fixture_name" "$fixture_uuid" "$fixture_state"
        done <<< "$fixtures"
      fi
      exit 0
    fi

    printf '%s\n' "$filter" >> "$SANDBOX_MARK/device-filters"
    printf '{\n  "result": {"devices": [\n' > "$json_path"
    first=1
    if [[ "${FAIL_AT:-}" != "nophone" ]]; then
      while IFS='|' read -r fixture_uuid fixture_state fixture_name fixture_type; do
        # Every query in production constrains the device class. Keep the
        # fixture honest about that too, so a future broad query cannot pass.
        fixture_type="${fixture_type:-iPhone}"
        [[ "$filter" == *"hardwareProperties.deviceType == '$fixture_type'"* ]] || continue
        if [[ "$filter" == *"identifier == '"* ]]; then
          filter_upper=$(printf '%s' "$filter" | tr '[:lower:]' '[:upper:]')
          fixture_uuid_upper=$(printf '%s' "$fixture_uuid" | tr '[:lower:]' '[:upper:]')
          [[ "$filter_upper" == *"IDENTIFIER == '$fixture_uuid_upper'"* ]] || continue
        fi
        if [[ "$filter" == *"deviceProperties.name == '"* ]] \
          && [[ "$filter" != *"deviceProperties.name == '$fixture_name'"* ]]; then
          continue
        fi
        # Without a State predicate devicectl would return every state. If
        # one is present, return only its exact matches. This makes both a
        # broadening to `unavailable` and an accidental removal of the state
        # filter make the negative deploy tests fail.
        if [[ "$filter" == *"State == '"* ]]; then
          [[ "$filter" == *"State == '$fixture_state'"* ]] || continue
        fi
        [[ "$first" == "1" ]] || printf ',\n' >> "$json_path"
        printf '    {"identifier":"%s","deviceProperties":{"name":"%s"}}' \
          "$fixture_uuid" "$fixture_name" >> "$json_path"
        first=0
      done <<< "$fixtures"
    fi
    printf '\n  ]}}\n' >> "$json_path"
    exit 0 ;;
  *"install app"*)
    [[ "${FAIL_AT:-}" == "install" ]] && exit 1
    prev=""
    for arg in "$@"; do
      [[ "$prev" == "--device" ]] && printf '%s' "$arg" > "$SANDBOX_MARK/installed-device"
      # The positional .app path — recorded so a case can assert WHICH build
      # was installed, the invariant the DerivedData glob broke. GitHub #3.
      [[ "$arg" == *.app ]] && printf '%s' "$arg" > "$SANDBOX_MARK/installed-app"
      prev="$arg"
    done
    touch "$SANDBOX_MARK/installed"; exit 0 ;;
  *"copy from"*)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--device" ]]; then
        printf '%s' "$2" > "$SANDBOX_MARK/copied-device"
        break
      fi
      shift
    done
    exit 0 ;;
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
  # The helper consumes only two JSON fields. Stub plutil as well so this
  # release-safety harness remains self-contained and checks the structured
  # contract rather than relying on the host macOS implementation.
  cat > "$SANDBOX/bin/plutil" <<'SH'
#!/bin/bash
[[ "$1" == "-extract" ]] || exit 1
field="$2"
json_path=""
for arg in "$@"; do json_path="$arg"; done

case "$field" in
  result.devices.*.identifier|result.devices.*.deviceProperties.name) ;;
  *) exit 1 ;;
esac
index_part="${field#result.devices.}"
index="${index_part%%.*}"
[[ "$index" =~ ^[0-9]+$ ]] || exit 1
line_number=$((index + 3))
device_line=$(sed -n "${line_number}p" "$json_path")

if [[ "$field" == *.identifier ]]; then
  [[ "$device_line" =~ \"identifier\":\"([^\"]+)\" ]] || exit 1
  printf '%s\n' "${BASH_REMATCH[1]}"
else
  [[ "$device_line" =~ \"name\":\"([^\"]*)\" ]] || exit 1
  printf '%s\n' "${BASH_REMATCH[1]}"
fi
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
       DEVICE_LISTING="${DEVICE_LISTING:-}" \
       DEVICE_FIXTURE="${DEVICE_FIXTURE:-}" \
       HOME="$SANDBOX" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
       "./Tools/$script" "$@" ) >"$SANDBOX/out" 2>&1
  echo $?
}

case_start() { echo; echo "--- $1"; unset DEVICE_LISTING DEVICE_FIXTURE; new_repo; write_stubs; }
case_end()   { [[ "$KEEP" == "1" ]] || rm -rf "$SANDBOX"; }

# --- deploy.sh -------------------------------------------------------------

case_start "deploy: happy path commits the number it installed"
  status=$(FAIL_AT= run deploy.sh)
  check "exit"          0             "$status"
  check "build number"  41            "$(build_number)"
  check "head"          "Build 2.3.41 (device)" "$(head_subject)"
  check "installed device" "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" "$(cat "$SANDBOX/installed-device")"
  check "tree"          clean         "$(is_dirty)"
case_end

# GitHub #3: the app path used to come from `ls | head -1` over DerivedData —
# alphabetical, so a stale hash directory sorting first got INSTALLED while
# the fresh build number was committed. The path must come from the build
# settings, whatever else is lying around.
case_start "deploy: installs the app the build settings name, not the alphabetically first DerivedData"
  mkdir -p "$SANDBOX/Library/Developer/Xcode/DerivedData/HeikoTranslate-000/Build/Products/Debug-iphoneos/Stale.app"
  status=$(FAIL_AT= run deploy.sh)
  check "exit" 0 "$status"
  check "installed app" \
    "$SANDBOX/Library/Developer/Xcode/DerivedData/HeikoTranslate-aaa/Build/Products/Debug-iphoneos/HeikoTranslate.app" \
    "$(cat "$SANDBOX/installed-app")"
case_end

# deploy installs to DEVICE_UUID explicitly but used to pull logs from
# whichever phone answered first. With a second iPhone attached that is a
# silent mismatch: the log you then read belongs to a device that never got
# the build. The target is listed SECOND here so first-reachable is the wrong
# answer, which is the only arrangement that can fail.
case_start "deploy: logs come from the phone that was installed to"
  DEVICE_FIXTURE=$'11111111-1111-1111-1111-111111111111|connected|Other iPhone|iPhone\nAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|connected|Target iPhone|iPhone'
  status=$(FAIL_AT= run deploy.sh)
  check "exit"          0             "$status"
  check "installed device" "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" "$(cat "$SANDBOX/installed-device")"
  check "copied device"    "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" "$(cat "$SANDBOX/copied-device")"
case_end

case_start "deploy: build fails before install -> number goes back"
  status=$(FAIL_AT=build run deploy.sh)
  check "exit"          65            "$status"
  check "build number"  40            "$(build_number)"
  check "head"          base          "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end

case_start "deploy: phone never appears -> number goes back"
  status=$(FAIL_AT=nophone run deploy.sh --wait -1)
  check "exit"          1             "$status"
  check "build number"  40            "$(build_number)"
  check "tree"          clean         "$(is_dirty)"
case_end

# #54 — `unavailable` contains `available`, so the old predicate left the
# wait loop and marked the install as attempted. That burned a build number
# for a phone that could not possibly have received it.
case_start "deploy: unavailable target is not treated as reachable"
  # A misleading display name would fool a substring check for `available`.
  DEVICE_FIXTURE="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|unavailable|Available iPhone"
  status=$(FAIL_AT= run deploy.sh --wait -1)
  check "exit"          1             "$status"
  check "installed"     no            "$([[ -e "$SANDBOX/installed" ]] && echo yes || echo no)"
  check "build number"  40            "$(build_number)"
  check "head"          base          "$(head_subject)"
  check "tree"          clean         "$(is_dirty)"
case_end

# The installer always targets DEVICE_UUID. A different reachable phone must
# not let it leave the wait loop while that configured target is unavailable.
case_start "deploy: another reachable phone cannot stand in for the unavailable target"
  # A UUID in a *different device's name* must not be mistaken for the target
  # identifier. Only the real target is unavailable here.
  DEVICE_FIXTURE=$'11111111-1111-1111-1111-111111111111|connected|AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\nAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|unavailable|Target iPhone'
  status=$(FAIL_AT= run deploy.sh --wait -1)
  check "exit"          1             "$status"
  check "installed"     no            "$([[ -e "$SANDBOX/installed" ]] && echo yes || echo no)"
  check "build number"  40            "$(build_number)"
  check "head"          base          "$(head_subject)"
case_end

# Wi-Fi paired devices remain valid deploy targets.
case_start "deploy: paired available target is reachable"
  DEVICE_FIXTURE="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|available (paired)|Example iPhone"
  status=$(FAIL_AT= run deploy.sh)
  check "exit"          0             "$status"
  check "installed"     yes           "$([[ -e "$SANDBOX/installed" ]] && echo yes || echo no)"
  check "build number"  41            "$(build_number)"
  check "head"          "Build 2.3.41 (device)" "$(head_subject)"
case_end

case_start "deploy: a lowercase devicectl UUID is canonicalized before install"
  DEVICE_FIXTURE="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|connected|Example iPhone"
  status=$(FAIL_AT= run deploy.sh)
  check "exit"          0             "$status"
  check "installed device" "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" "$(cat "$SANDBOX/installed-device")"
  check "build number"  41            "$(build_number)"
case_end

# pull_logs chooses only a row the same helper marks reachable; an unavailable
# device must never be handed to `devicectl copy`.
case_start "pull logs: skip unavailable rows and use a paired reachable phone"
  DEVICE_FIXTURE=$'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|unavailable|Locked iPhone\n11111111-1111-1111-1111-111111111111|available (paired)|Reachable iPhone'
  status=$(FAIL_AT= run pull_logs.sh)
  check "exit"          0             "$status"
  check "copied device" "11111111-1111-1111-1111-111111111111" "$(cat "$SANDBOX/copied-device")"
case_end

case_start "pull logs: disconnected rows are rejected without a copy"
  DEVICE_FIXTURE="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|disconnected|Example iPhone"
  status=$(FAIL_AT= run pull_logs.sh)
  check "exit"          1             "$status"
  check "copy attempted" no           "$([[ -e "$SANDBOX/copied-device" ]] && echo yes || echo no)"
case_end

# `not connected` contains the old accepted substring. It must remain
# unreachable even if its name says otherwise.
case_start "deploy: not connected target does not consume a build number"
  DEVICE_FIXTURE="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|not connected|Available target"
  status=$(FAIL_AT= run deploy.sh --wait -1)
  check "exit"          1             "$status"
  check "installed"     no            "$([[ -e "$SANDBOX/installed" ]] && echo yes || echo no)"
  check "build number"  40            "$(build_number)"
  check "head"          base          "$(head_subject)"
case_end

case_start "pull logs: explicit unavailable UUID cannot bypass reachability"
  DEVICE_FIXTURE="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|unavailable|Example iPhone"
  status=$(FAIL_AT= run pull_logs.sh "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
  check "exit"          1             "$status"
  check "copy attempted" no           "$([[ -e "$SANDBOX/copied-device" ]] && echo yes || echo no)"
case_end

case_start "pull logs: explicit lowercase UUID resolves to its reachable device"
  DEVICE_FIXTURE="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|connected|Example iPhone"
  status=$(FAIL_AT= run pull_logs.sh "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
  check "exit"          0             "$status"
  check "copied device" "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" "$(cat "$SANDBOX/copied-device")"
case_end

case_start "pull logs: paired named device with an apostrophe resolves safely"
  DEVICE_FIXTURE=$'11111111-1111-1111-1111-111111111111|connected|Other iPhone|iPhone\nAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|available (paired)|Georg\'s iPhone|iPhone'
  status=$(FAIL_AT= run pull_logs.sh "Georg's iPhone")
  check "exit"          0             "$status"
  check "copied device" "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" "$(cat "$SANDBOX/copied-device")"
case_end

case_start "pull logs: explicit unavailable named device cannot bypass reachability"
  DEVICE_FIXTURE="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|unavailable|Georg's iPhone|iPhone"
  status=$(FAIL_AT= run pull_logs.sh "Georg's iPhone")
  check "exit"          1             "$status"
  check "copy attempted" no           "$([[ -e "$SANDBOX/copied-device" ]] && echo yes || echo no)"
case_end

case_start "pull logs: connected iPad remains a supported automatic target"
  DEVICE_FIXTURE="22222222-2222-2222-2222-222222222222|connected|Example iPad|iPad"
  status=$(FAIL_AT= run pull_logs.sh)
  check "exit"          0             "$status"
  check "copied device" "22222222-2222-2222-2222-222222222222" "$(cat "$SANDBOX/copied-device")"
case_end

case_start "pull logs: malformed JSON identifier is rejected without a copy"
  DEVICE_FIXTURE="not-a-uuid|connected|Example iPhone"
  status=$(FAIL_AT= run pull_logs.sh)
  check "exit"          1             "$status"
  check "copy attempted" no           "$([[ -e "$SANDBOX/copied-device" ]] && echo yes || echo no)"
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
