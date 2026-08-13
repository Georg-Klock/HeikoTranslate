#!/bin/bash
# Structural preflight over the bundled Secrets.plist (GitHub #89), shared by
# deploy.sh and release.sh the way build_number.sh is. The build archives
# whatever HeikoTranslate/Resources/Secrets.plist happens to contain — the
# template's REPLACE-ME, a blank key, or no file at all — and none of the
# other gates can catch it: L1 never exercises the key, L3 takes its key from
# Tools/local.env, and the build succeeds regardless because the plist is a
# bundled resource, not compiled. What each bad state ships: a missing file
# fatalErrors at first launch; REPLACE-ME or a blank key launches, fails
# every handshake, and shows every installer the permanent update sentence
# (#9's revoked-key screen, against the wrong cause).
#
# Structural on purpose: this refuses only the states that cannot possibly be
# right. Whether the key is LIVE is what L3 and Tools/l2probe.sh establish —
# a network probe here would just be a slower, flakier copy of them.
#
# The key's value is never echoed, by anything on these paths: it exists
# nowhere public, and a gate that printed it into a terminal (and from there
# into a pasted log) would undo that.

SECRETS_PLIST="HeikoTranslate/Resources/Secrets.plist"
SECRETS_TEMPLATE="HeikoTranslate/Resources/Secrets.plist.example"
# The template's exact placeholder, asserted against the template itself at
# run time (below) so this file cannot drift from Secrets.plist.example.
SECRETS_PLACEHOLDER="REPLACE-ME"

# Exits 2 (the guard convention in both callers) unless the plist exists and
# GEMINI_API_KEY is present, non-empty, and not the template placeholder.
# Runs before the test gate and before the bump, so a refusal moves nothing
# and there is nothing to restore.
assert_secrets_key() {
  local key
  if [[ ! -f "$SECRETS_PLIST" ]]; then
    echo "!!  $SECRETS_PLIST is missing. The build would bundle no key at all" >&2
    echo "!!  and the app would crash at first launch. Create it:" >&2
    echo "!!    cp $SECRETS_TEMPLATE $SECRETS_PLIST" >&2
    echo "!!  then put the real key in it. It is gitignored; keep it that way." >&2
    exit 2
  fi
  if ! key=$(plutil -extract GEMINI_API_KEY raw -o - "$SECRETS_PLIST" 2>/dev/null); then
    echo "!!  $SECRETS_PLIST has no GEMINI_API_KEY entry (or is not a valid" >&2
    echo "!!  plist). The build would bundle a key the app cannot read." >&2
    exit 2
  fi
  if [[ -z "$key" ]]; then
    echo "!!  GEMINI_API_KEY in $SECRETS_PLIST is empty. The app would launch," >&2
    echo "!!  fail every handshake, and show installers the permanent update" >&2
    echo "!!  sentence (#9) — for a key that was never there." >&2
    exit 2
  fi
  if [[ "$key" == "$SECRETS_PLACEHOLDER" ]]; then
    echo "!!  GEMINI_API_KEY in $SECRETS_PLIST is still the template's" >&2
    echo "!!  $SECRETS_PLACEHOLDER placeholder. Put the real key in it." >&2
    exit 2
  fi
  # The placeholder above is a copy of the template's, and a copy can drift.
  # If the template ever changes its placeholder, refuse to trust this check
  # rather than silently passing a key that equals the NEW placeholder.
  if [[ -f "$SECRETS_TEMPLATE" ]] \
    && ! grep -q ">$SECRETS_PLACEHOLDER<" "$SECRETS_TEMPLATE"; then
    echo "!!  $SECRETS_TEMPLATE no longer uses the $SECRETS_PLACEHOLDER" >&2
    echo "!!  placeholder this preflight checks for. Update" >&2
    echo "!!  Tools/secrets_preflight.sh to match the template." >&2
    exit 2
  fi
}

# A warning, never a refusal (#9's operational leftover): without
# APP_UPDATE_URL the revoked-key sentence still shows, but its tap goes
# nowhere. Development builds omit it on purpose, so only release.sh asks.
warn_if_no_update_url() {
  local url
  if ! url=$(plutil -extract APP_UPDATE_URL raw -o - "$SECRETS_PLIST" 2>/dev/null) \
    || [[ -z "$url" ]]; then
    echo "**  $SECRETS_PLIST has no APP_UPDATE_URL. If this build's key is" >&2
    echo "**  ever revoked, the update sentence will show with a tap that" >&2
    echo "**  goes nowhere (#9). Set it once the unlisted link exists." >&2
  fi
}
