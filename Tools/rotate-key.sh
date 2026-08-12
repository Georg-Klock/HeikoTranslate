#!/bin/bash
# Rotate the Gemini API key in the LOCAL, gitignored Secrets.plist — the
# scripted-rotation piece of GitHub #9, so a compromise response is one
# command instead of a hunt through Xcode for which file holds the key.
#
#   Tools/rotate-key.sh          # prompts for the new key (hidden input)
#   echo "$KEY" | Tools/rotate-key.sh   # or piped, for a password manager
#
# The key is read from STDIN, never argv (argv is visible to every process
# on the machine), is never echoed, and never appears in any output. The
# old plist is backed up into private/ (gitignored, the repo's documented
# home for durable-but-unpublishable material) before anything is written.
#
# After writing, one live probe verifies the NEW key actually translates.
# On probe failure the new key STAYS — the usual reason to rotate is that
# the old key is already revoked, so silently reverting to it is not
# obviously safer — and the backup path is printed for a one-command
# revert if the operator decides otherwise.
#
# macOS-only (PlistBuddy), like the deploy pipeline this sits beside.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

PLIST="HeikoTranslate/Resources/Secrets.plist"
PB=/usr/libexec/PlistBuddy
# The probe is injectable so Tools/tests/rotate-key-windows.sh can drive
# both outcomes without the network; the default is the real L2 probe.
PROBE="${ROTATE_PROBE_CMD:-python3 Tools/livetest.py --text \"Two coffees, please.\" --target de --tail 5}"

[[ -f "$PLIST" ]] || { echo "No $PLIST — nothing to rotate. See README for first-time setup." >&2; exit 1; }
if git ls-files --error-unmatch "$PLIST" >/dev/null 2>&1; then
  echo "!!  $PLIST is TRACKED by git. That is the emergency, not the rotation:" >&2
  echo "!!  fix the tracking first (git rm --cached), then rotate." >&2
  exit 1
fi

if [[ -t 0 ]]; then
  read -r -s -p "New GEMINI_API_KEY (input hidden): " NEW_KEY
  echo
else
  IFS= read -r NEW_KEY || true
fi
[[ -n "${NEW_KEY:-}" ]] && [[ "$NEW_KEY" != "REPLACE-ME" ]] || {
  echo "Empty or placeholder key — nothing written." >&2; exit 1; }

mkdir -p private
BACKUP="private/Secrets.plist.pre-rotation.$(date +%Y%m%d-%H%M%S)"
cp "$PLIST" "$BACKUP"

"$PB" -c "Set :GEMINI_API_KEY $NEW_KEY" "$PLIST" 2>/dev/null \
  || "$PB" -c "Add :GEMINI_API_KEY string $NEW_KEY" "$PLIST"
echo "==> Key written to $PLIST (old plist: $BACKUP)"

echo "==> Verifying the new key with one live probe"
if eval "$PROBE" >/dev/null 2>&1; then
  echo "==> Probe passed — rotation complete. Revoke the OLD key at its"
  echo "    provider now; the backup keeps it readable until you do:"
  echo "    $BACKUP"
else
  echo "!!  Probe FAILED with the new key. The new key STAYS (the old one" >&2
  echo "!!  is often already revoked — reverting is not obviously safer)." >&2
  echo "!!  If the old key is known-good, revert with:" >&2
  echo "!!    cp \"$BACKUP\" \"$PLIST\"" >&2
  echo "!!  Note the live API itself has degraded days (see #65) — a" >&2
  echo "!!  failed probe is not proof the key is bad. Retry before acting." >&2
  exit 2
fi
