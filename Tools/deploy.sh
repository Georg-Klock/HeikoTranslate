#!/bin/bash
# Build, install to the iPhone, and pull the diagnostic log back — the loop
# this project runs a dozen times a day, in one command.
#
#   Tools/deploy.sh            # L1, bump, build, wait for the phone, install, logs
#   Tools/deploy.sh --no-build # skip the build (already built)
#   Tools/deploy.sh --no-bump  # don't increment the build number
#   Tools/deploy.sh --no-test  # skip L1 (debugging the deploy path, not the app)
#   Tools/deploy.sh --wait 300 # wait longer than the default 120s
#
# The phone must be UNLOCKED. A locked iPhone reports as "unavailable" to
# devicectl, which looks exactly like "not plugged in" — that single fact
# has cost this project more time than any bug in the app.
set -euo pipefail
cd "$(dirname "$0")/.."
source Tools/ios_device.sh

BUNDLE_ID="com.klock.heikotranslate"

# The paired iPhone's UDID identifies a physical device, and the Apple
# Developer team ID identifies an account. Neither is a fact about this
# project, so both live in gitignored Tools/local.env rather than in the public
# repo. Create it with:
#   printf 'DEVICE_UUID="<udid>"\nDEVELOPMENT_TEAM="<team-id>"\n' > Tools/local.env
# Find the UDID with:    xcrun devicectl list devices
# Find the team ID with: Xcode → Settings → Accounts → your team
[ -f Tools/local.env ] && . Tools/local.env
if [ -z "${DEVICE_UUID:-}" ]; then
  echo "No DEVICE_UUID. Run 'xcrun devicectl list devices', then:" >&2
  echo "  echo 'DEVICE_UUID=\"<udid>\"' >> Tools/local.env" >&2
  exit 1
fi
if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  echo "No DEVELOPMENT_TEAM. Find it in Xcode → Settings → Accounts, then:" >&2
  echo "  echo 'DEVELOPMENT_TEAM=\"<team-id>\"' >> Tools/local.env" >&2
  exit 1
fi
BUILD=1
BUMP=1
# L1 before anything reaches the phone. This used to be a rule Georg kept in
# his head; it became a gate on 2026-08-08, when CI stopped running on pull
# requests. Both this script and release.sh now really do refuse to proceed
# without L1 — the CI config claimed that before it was true of this one.
# It runs BEFORE the bump, so a failing suite costs no build number.
RUN_L1=1
WAIT_SECONDS=120
# Guards for the EXIT trap installed after the bump, below. INSTALLED is the
# point of no return: once the phone has the build, the number has reached a
# screen, so it must end up in git whatever happens next.
BUMPED=0
COMMITTED=0
INSTALLED=0
INSTALL_ATTEMPTED=0
SIGNALLED=0
CURRENT_BUILD=""
NEXT_BUILD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --no-bump) BUMP=0; shift ;;
    --no-test) RUN_L1=0; shift ;;
    --wait) WAIT_SECONDS="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# Runs first, before the bump and before any trap is armed: a failing suite
# should cost nothing and leave nothing to clean up. --no-test exists for the
# case where you are debugging the deploy path itself, not the app.
if [[ "$RUN_L1" == "1" ]]; then
  ./Tools/l1.sh
else
  echo "==> Skipping L1 (--no-test)"
fi

# Commit the bump. The number on the pill has to identify exactly ONE build,
# and it only does that if every number that ever reached a device also exists
# in git. Leaving the bump uncommitted breaks that quietly: 2.3.36 was
# installed on the phone while the repo said 34, so a bug report naming 2.3.36
# could not be traced to any code. The build number is a counter shared with
# release.sh — it only ever goes up, and it is never reverted.
#
# A function because the EXIT trap needs it too: a failure between the install
# and the commit still has to record the number. Two copies of this would be
# two chances to drift.
# Extra body line for the commit, when the number has to be recorded despite an
# unclear outcome. Empty on the normal path.
BUILD_NOTE=""

commit_build_number() {
  # vs HEAD, not vs the index: a previous failed attempt may have left
  # project.yml staged, and plain `git diff` compares worktree to index —
  # it would report "nothing to commit" and return success without ever
  # recording the number. Caught by Tools/tests/build-number-windows.sh.
  git diff --quiet HEAD -- project.yml && return 0
  local committed_version committed_build yml_changed_lines
  committed_version=$(grep CFBundleShortVersionString project.yml | sed 's/.*"\(.*\)"/\1/')
  committed_build=$(grep 'CFBundleVersion:' project.yml | sed 's/.*"\(.*\)"/\1/')
  # Two changed lines is exactly the CFBundleVersion swap. More than that and
  # unrelated project.yml edits are riding along inside a commit labelled
  # "Build X", which misfiles them.
  yml_changed_lines=$(git diff -U0 HEAD -- project.yml | grep -c '^[+-][^+-]' || true)
  # Reported by return value, never left to `set -e`: on_exit calls this as
  # `commit_build_number || …`, and bash disables `set -e` inside a function
  # invoked that way, so a failed commit would otherwise fall through to
  # COMMITTED=1 and claim it recorded a number it did not.
  git add project.yml || return 1
  # Record WHAT ELSE was uncommitted, in the commit itself. The build was made
  # from this worktree, so a build number committed beside three dirty files
  # does not identify the code that produced it — the warning below said so
  # only in the terminal, where it scrolls away. In the commit message it is
  # still there when the bug report arrives three weeks later.
  local dirty_note
  local -a msg=(-m "Build $committed_version.$committed_build (device)")
  dirty_note=$(git status --porcelain | grep -v ' project.yml$' || true)
  if [[ -n "$dirty_note" ]]; then
    msg+=(-m "Built from a dirty worktree. Uncommitted at build time:" -m "$dirty_note")
  fi
  [[ -n "$BUILD_NOTE" ]] && msg+=(-m "$BUILD_NOTE")
  # A pre-commit hook must not be able to lose a number that is already on the
  # phone, so a failed commit is retried once without hooks, loudly.
  git commit -q "${msg[@]}" || {
    echo "!!  git commit failed; retrying without hooks (--no-verify)." >&2
    git commit -q --no-verify "${msg[@]}" || return 1
  }
  COMMITTED=1
  echo "==> Committed the build number as $committed_version.$committed_build"
  if (( yml_changed_lines > 2 )); then
    echo "!!  project.yml carried changes beyond the build number into that"
    echo "!!  commit. Check 'git show HEAD' — they may belong somewhere else."
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "!!  Other files are still uncommitted, so this build is not fully"
    echo "!!  reproducible from git. The number is recorded either way, but"
    echo "!!  commit the rest before a build you might get a report about."
  fi
}

# Undo the bump and NOTHING else. The old `git checkout -- project.yml` threw
# away every uncommitted project.yml edit along with it, and this script has no
# dirty-tree guard (deliberately — the daily loop deploys over work in
# progress), so a hand edit plus any failed deploy silently destroyed the edit.
revert_build_number() {
  local now
  sed -i '' "s/CFBundleVersion: \"$NEXT_BUILD\"/CFBundleVersion: \"$CURRENT_BUILD\"/" project.yml
  now=$(grep 'CFBundleVersion:' project.yml | sed 's/.*"\(.*\)"/\1/')
  if [[ "$now" == "$CURRENT_BUILD" ]]; then
    echo "==> Deploy did not complete — build number left at $CURRENT_BUILD" >&2
  else
    echo "!!  Could not restore the build number: project.yml says '$now'," >&2
    echo "!!  expected '$CURRENT_BUILD'. Check it by hand before releasing." >&2
  fi
}

# The terminal scrolls; a file does not. When the number is spent but unrecorded
# the recovery is one command, and this is where it waits.
leave_recovery_note() {
  cat > .build-number-recovery <<NOTE
Build number $1 is $2, but committing it FAILED.
Until this is committed, that build maps to no commit in git.

Recover with:
  git add project.yml && git commit -m "Build $1"
  rm .build-number-recovery

Leaving this file in place is deliberate: it is untracked, so
release.sh's dirty-tree guard will refuse to cut a release until
you have dealt with it.
NOTE
  echo "!!  Wrote .build-number-recovery with the command to run." >&2
}

# EXIT alone is not enough. Bash does NOT run an EXIT-only trap when the script
# is killed by SIGINT, and Ctrl-C during a long xcodebuild is *the* realistic
# interrupt on this project — it is literally the scenario #22 describes for
# release.sh ("an interrupt after -exportArchive succeeds but before the
# commit"). Measured, not assumed: a script with `trap f EXIT` that takes
# SIGINT never runs f; adding INT/TERM fixes it. The handler re-raises with the
# conventional 128+signo so callers and CI still see a real interrupt.
on_signal() {
  local signo=$1
  SIGNALLED=$signo
  exit $((128 + signo))
}

# The build number only goes up and is never reverted once it has been seen.
# Which way this falls is decided by INSTALLED, not by whether the script
# reached its last line — see #22.
on_exit() {
  local status=$?
  if [[ "$BUMPED" != "1" || "$COMMITTED" == "1" ]]; then exit $status; fi
  if [[ "$INSTALLED" != "1" && "$INSTALL_ATTEMPTED" == "1" ]]; then
    # Interrupted mid-install. Whether the phone took the build is unknowable
    # from here, and the two mistakes are not equally bad: keeping an unclaimed
    # number skips one in a counter that is only ever required to increase,
    # while reverting a claimed one puts an untraceable build on the phone —
    # the failure this whole pipeline exists to prevent. So burn it, and say so
    # in the commit.
    INSTALLED=1
    BUILD_NOTE="Install was interrupted; whether the phone took this build is unknown. The number is burned deliberately rather than risk reverting one already on the device."
    echo "==> Install was interrupted — burning $NEXT_BUILD rather than" >&2
    echo "    risk reverting a number the phone may already have." >&2
  fi
  if [[ "$INSTALLED" == "1" ]]; then
    echo "==> Deploy did not finish, but the phone may be running" >&2
    echo "    $NEXT_BUILD — committing the number so it stays traceable." >&2
    commit_build_number || {
      echo "!!  COULD NOT COMMIT the build number, and the phone is running" >&2
      echo "!!  $NEXT_BUILD. Commit project.yml by hand NOW — until you do," >&2
      echo "!!  that build maps to no commit." >&2
      leave_recovery_note "$NEXT_BUILD" "installed on the phone"
    }
  else
    revert_build_number
  fi
  exit $status
}

# The on-screen pill is CFBundleShortVersionString + CFBundleVersion, so the
# BUILD number is what has to move for "did my phone update?" to stay
# answerable. Bumping it here makes that true by construction — there is no
# longer a way to forget, which is what the old refuse-to-install guard was
# working around. The marketing version deliberately stays put: Apple reviews
# the first build of each version, so changing it would put every TestFlight
# update behind a fresh review.
if [[ "$BUILD" == "1" && "$BUMP" == "1" ]]; then
  CURRENT_BUILD=$(grep 'CFBundleVersion:' project.yml | sed 's/.*"\(.*\)"/\1/')
  if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "Could not read CFBundleVersion from project.yml (got '$CURRENT_BUILD')." >&2
    echo "Fix it there, or pass --no-bump." >&2
    exit 2
  fi
  NEXT_BUILD=$((CURRENT_BUILD + 1))
  sed -i '' "s/CFBundleVersion: \"$CURRENT_BUILD\"/CFBundleVersion: \"$NEXT_BUILD\"/" project.yml
  BUMPED=1
  # Nothing between here and the commit is guaranteed to succeed — the build
  # can fail, and the phone can simply never show up, which on this project is
  # the single most common way a deploy ends (a locked iPhone reports as
  # "unavailable"). Without this, an aborted deploy leaves project.yml bumped
  # and uncommitted: the tree is dirty so release.sh refuses, and the next
  # deploy bumps again so the counter skips. Revert unless we got as far as
  # committing — or as far as INSTALLING, after which reverting is the bug.
  trap on_exit EXIT
  trap 'on_signal 2' INT
  trap 'on_signal 15' TERM
  echo "==> Build number $CURRENT_BUILD -> $NEXT_BUILD"
fi

if [[ "$BUILD" == "1" ]]; then
  VERSION=$(grep CFBundleShortVersionString project.yml | sed 's/.*"\(.*\)"/\1/')
  BUILD_NO=$(grep 'CFBundleVersion:' project.yml | sed 's/.*"\(.*\)"/\1/')
  echo "==> Building $VERSION.$BUILD_NO for device"
  xcodegen generate >/dev/null
  xcodebuild -project HeikoTranslate.xcodeproj -scheme HeikoTranslate \
    -destination 'generic/platform=iOS' -allowProvisioningUpdates -quiet build \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
fi

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/HeikoTranslate-*/Build/Products/Debug-iphoneos/*.app | head -1)

echo "==> Waiting up to ${WAIT_SECONDS}s for an unlocked, connected iPhone"
deadline=$((SECONDS + WAIT_SECONDS))
# "connected" is the USB word. Over Wi-Fi a perfectly installable phone reads
# "available (paired)" — and install works: it opens a tunnel and goes. Gating
# on "connected" alone made every wireless deploy fail with a message telling
# the user to unlock a phone that was already unlocked. Accept either, but only
# for the configured target — another reachable device must not make an
# unavailable target appear ready.
while true; do
  if ios_device_with_uuid_is_reachable "$DEVICE_UUID"; then
    break
  fi
  if (( SECONDS > deadline )); then
    echo >&2
    echo "Never became reachable. devicectl sees:" >&2
    DEVICE_LISTING=$(xcrun devicectl list devices 2>/dev/null || true)
    grep -iE 'iphone|ipad' <<<"$DEVICE_LISTING" >&2 || true
    echo >&2
    echo "UNLOCK the phone (locked reads as 'unavailable'), and prefer a data" >&2
    echo "cable — macOS has been seeing zero iPhones on USB." >&2
    exit 1
  fi
  sleep 3
done

echo "==> Installing"
# No version guard here any more. It existed because the pill showed only
# CFBundleShortVersionString, so bumping just the build number left the same
# text on screen install after install — that is how 2.2 stayed on the pill
# from build 16 to 32 and the phone looked like it had never updated. The pill
# now includes the build number and this script bumps it above, so the number
# cannot fail to change. Guarding against it would only reject good installs.
# Set BEFORE the command, not after: a signal arriving while devicectl runs is
# not delivered until the child exits, so the trap would run with INSTALLED
# still 0 and revert a number the phone may already have. Reproduced by
# Tools/tests/build-number-windows.sh; it is deterministic, not a rare race.
INSTALL_ATTEMPTED=1
xcrun devicectl device install app --device "$DEVICE_UUID" "$APP" --quiet
# The point of no return. From here the number exists on a screen, so nothing
# downstream may revert it — see on_exit.
INSTALLED=1

# Informational only, hence `|| true`. Under `set -euo pipefail` this pipeline
# failing — the phone drops off USB right after the install, devicectl changes
# its output format, grep simply matches nothing — used to kill the script
# AFTER the install and fire the revert trap, leaving the phone running a build
# number that existed nowhere in git. The exact failure #16 was built to
# prevent, reintroduced by the trap added to prevent a different one (#22).
xcrun devicectl device info apps --device "$DEVICE_UUID" 2>/dev/null | grep -i heiko || true

# Only when this run bumped. Without the guard, `--no-bump` over a project.yml
# that was already staged for unrelated reasons would sweep those edits into a
# commit labelled "Build X (device)" — a regression the HEAD-vs-index fix
# introduced, since staged-but-unmodified now counts as "there is something to
# commit".
if [[ "$BUMPED" == "1" ]]; then commit_build_number; fi

echo "==> Pulling logs"
# Name the device rather than letting pull_logs pick the first reachable one.
# The install above is explicit about DEVICE_UUID, so with a second phone
# attached the two could disagree: install to the target, then read the log off
# whatever else happened to be plugged in. Measured 2026-08-10 with two paired
# iPhones — it happened to pick the right one, which is exactly the kind of
# luck that stops being lucky while you are reading the wrong log.
./Tools/pull_logs.sh "$DEVICE_UUID" || true
