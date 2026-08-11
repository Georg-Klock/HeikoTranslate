#!/bin/bash
# Cut a TestFlight build: test, bump, archive, export, upload. One command,
# the release-side counterpart to Tools/deploy.sh.
#
#   Tools/release.sh              # L1+L3, bump, archive, upload
#   Tools/release.sh --no-l3      # L1 only (L3 already run this session)
#   Tools/release.sh --no-tests   # skip the gate entirely (don't)
#   Tools/release.sh --dry-run    # archive, but stop before uploading
#
# See docs/release.md — in particular the rule for when a change earns a
# CFBundleShortVersionString bump. This script never touches that number; it
# only moves CFBundleVersion, which must move on every upload.
set -euo pipefail
cd "$(dirname "$0")/.."

# The Apple Developer team ID identifies an account, not this project, so it
# lives in gitignored Tools/local.env and the export plist is generated from a
# committed template at build time. Create it with:
#   echo 'DEVELOPMENT_TEAM="<team-id>"' >> Tools/local.env
# Find it in Xcode → Settings → Accounts → your team.
source Tools/build_number.sh
[ -f Tools/local.env ] && . Tools/local.env
if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  echo "No DEVELOPMENT_TEAM. Find it in Xcode → Settings → Accounts, then:" >&2
  echo "  echo 'DEVELOPMENT_TEAM=\"<team-id>\"' >> Tools/local.env" >&2
  exit 1
fi

RUN_TESTS=1
RUN_L3=1
DRY_RUN=0

# Guards for the EXIT trap installed after the bump, below. UPLOADED is the
# point of no return: once Apple has the build, that number is claimed forever
# (TestFlight will not accept it twice), so it must end up in git whatever
# happens next. Before that point nothing has claimed it and the bump should be
# put back. #22.
BUMPED=0
UPLOADED=0
UPLOAD_ATTEMPTED=0
COMMITTED=0
RELEASE_NOTE=""
CURRENT_BUILD=""
NEXT_BUILD=""
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-tests) RUN_TESTS=0; shift ;;
    --no-l3) RUN_L3=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# A build you cannot tie to a commit is a build you cannot debug when Heiko
# reports something odd from Germany three weeks later.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "!!  Working tree is dirty. Commit or stash first — an uploaded build" >&2
  echo "!!  must correspond to a commit that exists." >&2
  git status --short >&2
  exit 2
fi

BRANCH=$(git branch --show-current)
if [[ "$BRANCH" != "main" ]]; then
  echo "!!  On branch '$BRANCH'. Releases are cut from main (CLAUDE.md: work" >&2
  echo "!!  happens on a branch and lands through a PR). Merge first." >&2
  exit 2
fi

# L3's diagnostic switches must never reach a release. L3_ALLOW_RAW=1
# downgrades protocol drift from a failure back to a warning, and
# L3_INJECT_RAW=1 seeds a synthetic failing frame — both exist for
# investigating a drift in a scratch shell, and a shell that still has one
# exported is exactly the shell most likely to cut the next release. Refuse
# loudly rather than silently unsetting: the environment was armed, and the
# human should know. Fires even with --no-l3, which means "L3 already ran
# this session" — a session with these set proves nothing. GitHub #19.
if [[ -n "${L3_ALLOW_RAW:-}" || -n "${L3_INJECT_RAW:-}" ]]; then
  echo "!!  L3_ALLOW_RAW/L3_INJECT_RAW is set in this shell. These are" >&2
  echo "!!  diagnostic switches for investigating protocol drift; an L3 run" >&2
  echo "!!  under them proves nothing about the release. Unset them first:" >&2
  echo "!!    unset L3_ALLOW_RAW L3_INJECT_RAW" >&2
  exit 2
fi

# The log holds full conversation transcripts — Heiko's and whoever he is
# talking to. With DIAGNOSTIC_UPLOAD_URL set, the app POSTs it on every
# backgrounding. A TestFlight build can reach the public link, where those
# would be strangers' conversations landing in Georg's bucket. docs/release.md
# says to check this by hand; a script that checks is worth more than a doc
# that asks you to remember.
#
# Test the VALUE, not the key name. Secrets.plist.example ships the key with
# "REPLACE-ME" in it, and AppConfig deliberately ignores that — so grepping for
# the key alone refuses a build that would never upload anything. This mirrors
# AppConfig.diagnosticUploadURL exactly: non-empty, not REPLACE-ME, https.
SECRETS="HeikoTranslate/Resources/Secrets.plist"
UPLOAD_URL=""
if [[ -f "$SECRETS" ]]; then
  UPLOAD_URL=$(/usr/libexec/PlistBuddy -c "Print :DIAGNOSTIC_UPLOAD_URL" "$SECRETS" 2>/dev/null || true)
fi
if [[ -n "$UPLOAD_URL" && "$UPLOAD_URL" != "REPLACE-ME" && "$UPLOAD_URL" == https://* ]]; then
  if [[ "${ALLOW_UPLOAD_URL:-0}" != "1" ]]; then
    echo "!!  DIAGNOSTIC_UPLOAD_URL is set in Secrets.plist." >&2
    echo "!!  This build would POST conversation transcripts on every" >&2
    echo "!!  backgrounding, and a TestFlight build can reach the public" >&2
    echo "!!  link — those would be strangers' conversations." >&2
    echo "!!  Remove the key, or re-run with ALLOW_UPLOAD_URL=1 if this" >&2
    echo "!!  build is genuinely going nowhere near the public link." >&2
    exit 2
  fi
  echo "==> WARNING: releasing with DIAGNOSTIC_UPLOAD_URL set (overridden)"
fi

if [[ "$RUN_TESTS" == "1" ]]; then
  # One definition of "L1 passed", shared with deploy.sh and quoted in PR
  # bodies. It asserts a non-zero test count; the old inline -quiet invocation
  # here could not tell a pass from a scheme that ran no tests at all.
  ./Tools/l1.sh
  if [[ "$RUN_L3" == "1" ]]; then
    echo "==> L3 (live API, costs a few cents)"
    ./Tools/l3replay.sh
  fi
fi

# Failures are reported by return value, never left to `set -e`: this is called
# from on_exit as `commit_build_number || …`, and bash disables `set -e` inside
# a function invoked that way. Without the explicit `|| return 1` a failed
# commit would fall through to `COMMITTED=1` and the caller would be told the
# number was recorded when it was not — the worst possible lie for this script
# to tell. Caught by Tools/tests/build-number-windows.sh.
commit_build_number() {
  # vs HEAD, not vs the index: a previous failed attempt may have left
  # project.yml staged, and plain `git diff` compares worktree to index —
  # it would report "nothing to commit" and return success without ever
  # recording the number. Caught by Tools/tests/build-number-windows.sh.
  git diff --quiet HEAD -- project.yml && return 0
  git add project.yml || return 1
  local -a msg=(-m "Release $VERSION.$NEXT_BUILD")
  [[ -n "$RELEASE_NOTE" ]] && msg+=(-m "$RELEASE_NOTE")
  git commit -q "${msg[@]}" || {
    # A pre-commit hook must not be able to lose a number Apple already has.
    echo "!!  git commit failed; retrying without hooks (--no-verify)." >&2
    git commit -q --no-verify "${msg[@]}" || return 1
  }
  COMMITTED=1
}

# The terminal scrolls; a file does not.
leave_recovery_note() {
  cat > .build-number-recovery <<NOTE
Release $VERSION.$NEXT_BUILD is ALREADY UPLOADED to TestFlight, but
committing the build number FAILED. That number is spent — TestFlight
will not accept it again — and right now it maps to no commit.

Recover with:
  git add project.yml && git commit -m "Release $VERSION.$NEXT_BUILD"
  rm .build-number-recovery

Leaving this file in place is deliberate: it is untracked, so
the dirty-tree guard above will refuse the next release until you
have dealt with it.
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
  exit $((128 + signo))
}


# Undo the bump and NOTHING else. The dirty-tree guard above runs before the
# test gate, which takes minutes — long enough for a hand edit to land in
# project.yml that `git checkout -- project.yml` would silently destroy.
revert_build_number() {
  local now
  set_build_number "$NEXT_BUILD" "$CURRENT_BUILD"
  now=$(grep 'CFBundleVersion:' project.yml | sed 's/.*"\(.*\)"/\1/')
  if [[ "$now" != "$CURRENT_BUILD" ]]; then
    echo "!!  Could not restore the build number: project.yml says '$now'," >&2
    echo "!!  expected '$CURRENT_BUILD'. Fix it before the next release." >&2
  fi
}

# release.sh had no trap at all (#22). Two windows that cost real numbers:
#
#   - A failed archive, after the bump and before the commit, stranded a bumped
#     uncommitted project.yml. Every later run then refused on its own
#     dirty-tree check until someone cleaned up by hand.
#   - An interrupt after the upload succeeded but before the commit left an
#     Apple-visible build recorded in no commit. That one is permanent:
#     TestFlight build numbers cannot be reused, so the number is spent and
#     nothing in git says which code produced it.
#
# So the direction of the fix flips at UPLOADED, exactly as deploy.sh's flips
# at INSTALLED.
on_exit() {
  local status=$?
  if [[ "$BUMPED" != "1" || "$COMMITTED" == "1" ]]; then exit $status; fi
  if [[ "$UPLOADED" != "1" && "$UPLOAD_ATTEMPTED" == "1" ]]; then
    # Interrupted or failed mid-upload. Whether Apple registered the build is
    # unknowable from an exit code, and the two mistakes are not equally bad: a
    # burned number skips one in a counter only required to increase, while
    # reverting a number TestFlight already has is permanent and unrecoverable
    # — it will never accept that number again. Burn it, and record why.
    UPLOADED=1
    RELEASE_NOTE="Upload did not report success; whether TestFlight registered this build is unknown. The number is burned deliberately rather than risk reusing one Apple already has."
    echo "==> Upload outcome unknown — burning $VERSION.$NEXT_BUILD rather" >&2
    echo "    than risk reusing a number TestFlight may already hold." >&2
  fi
  if [[ "$UPLOADED" == "1" ]]; then
    echo >&2
    echo "==> Upload succeeded but the run did not finish — committing" >&2
    echo "    $VERSION.$NEXT_BUILD so the uploaded build stays traceable." >&2
    commit_build_number || {
      echo "!!  COULD NOT COMMIT, and $VERSION.$NEXT_BUILD IS ALREADY UPLOADED." >&2
      echo "!!  That number is spent — TestFlight will not take it again." >&2
      echo "!!  Commit project.yml by hand NOW." >&2
      leave_recovery_note
    }
  else
    revert_build_number
    echo "==> Release did not upload — build number left at $CURRENT_BUILD" >&2
  fi
  exit $status
}

CURRENT_BUILD=$(grep 'CFBundleVersion:' project.yml | sed 's/.*"\(.*\)"/\1/')
if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  echo "Could not read CFBundleVersion from project.yml (got '$CURRENT_BUILD')." >&2
  exit 2
fi
NEXT_BUILD=$((CURRENT_BUILD + 1))
VERSION=$(grep CFBundleShortVersionString project.yml | sed 's/.*"\(.*\)"/\1/')
set_build_number "$CURRENT_BUILD" "$NEXT_BUILD"
BUMPED=1
trap on_exit EXIT
trap 'on_signal 2' INT
trap 'on_signal 15' TERM
echo "==> Releasing $VERSION.$NEXT_BUILD (build $CURRENT_BUILD -> $NEXT_BUILD)"

xcodegen generate >/dev/null

ARCHIVE=/tmp/ht-release.xcarchive
rm -rf "$ARCHIVE"
echo "==> Archiving"
xcodebuild archive -project HeikoTranslate.xcodeproj -scheme HeikoTranslate \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates -quiet \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"

if [[ "$DRY_RUN" == "1" ]]; then
  # Put the build number back. Nothing was uploaded, so nothing has claimed
  # $NEXT_BUILD — and leaving project.yml modified would make the very next
  # run fail its own dirty-tree check, turning a dry run into a chore.
  revert_build_number
  BUMPED=0          # handled here; leave the trap nothing to do
  xcodegen generate >/dev/null
  echo "==> Dry run: archived at $ARCHIVE, nothing uploaded."
  echo "    Build number left at $CURRENT_BUILD; the tree is clean."
  exit 0
fi

echo "==> Exporting and uploading to TestFlight"
# destination: upload in this plist sends the build through the account already
# signed into Xcode. No App Store Connect API key involved.
# Set BEFORE the command, not after: a signal arriving while xcodebuild runs is
# not delivered until the child exits, so the trap would run with UPLOADED
# still 0 and revert a number Apple may already hold. Deterministic, and
# reproduced by Tools/tests/build-number-windows.sh.
UPLOAD_ATTEMPTED=1
# Generated, not committed: the template carries a $DEVELOPMENT_TEAM
# placeholder so the account identifier never lands in the public repo.
EXPORT_PLIST=/tmp/ht-ExportUpload.plist
sed "s/\$DEVELOPMENT_TEAM/$DEVELOPMENT_TEAM/" Tools/ExportUpload.plist.example > "$EXPORT_PLIST"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath /tmp/ht-release-export -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates
# Apple has it now. $NEXT_BUILD is spent whatever happens below.
UPLOADED=1

commit_build_number
echo
echo "==> Uploaded $VERSION.$NEXT_BUILD. Committed the build bump."
echo "    Push it: git push"
echo "    Processing takes 5-15 min. If $VERSION's first build is already"
echo "    approved, this one reaches external testers without a full review."
