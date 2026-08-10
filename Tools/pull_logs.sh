#!/bin/bash
# Pull the on-device diagnostic log off the iPhone and print where it landed.
#
#   Tools/pull_logs.sh              # first reachable iPhone or iPad
#   Tools/pull_logs.sh "My iPhone"
#
# The app writes every launch to Documents/heiko-diagnostics.log inside its
# own container (previous run kept as .log.1). No tethering needed while
# testing — use the app anywhere, plug in afterwards, run this.
set -euo pipefail
cd "$(dirname "$0")/.."
source Tools/ios_device.sh

BUNDLE_ID="com.klock.heikotranslate"
DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
  DEVICE=$(first_reachable_ios_device_uuid || true)
else
  # Resolve the documented UUID-or-name argument to an exact reachable UUID.
  # Do not let an explicit selector bypass the same safety check as automatic
  # selection; a locked phone must never reach `devicectl copy`.
  DEVICE=$(reachable_ios_device_uuid_for_selector "$DEVICE" || true)
fi

if [[ -z "$DEVICE" ]]; then
  # Say WHY rather than exiting quietly: a paired-but-unreachable phone
  # lists as "unavailable", which looks identical to "no phone" unless
  # you print the table.
  LISTING=$(xcrun devicectl list devices 2>/dev/null || true)
  echo "No reachable device. devicectl sees:" >&2
  if [[ -n "$LISTING" ]]; then
    grep -iE 'iphone|ipad' <<<"$LISTING" >&2 || echo "  (no iOS devices paired)" >&2
  else
    echo "  (devicectl returned nothing)" >&2
  fi
  echo >&2
  echo "Plug the iPhone in over USB and unlock it, then run this again." >&2
  echo "A device shown as 'unavailable' is paired but not reachable right now." >&2
  exit 1
fi

OUT="logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

# Copy the whole Documents directory: devicectl reliably transfers a
# directory, while a single-file source path silently yields nothing.
xcrun devicectl device copy from \
  --device "$DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source Documents \
  --destination "$OUT" \
  --quiet

echo "Pulled to $OUT:"
ls -la "$OUT"
echo
echo "Most recent run, last 60 lines:"
tail -60 "$OUT/heiko-diagnostics.log" 2>/dev/null || echo "(no log — has the app been opened since installing?)"
