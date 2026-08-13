#!/usr/bin/env bash
# Capture the App Store screenshots from the real app (GitHub #26).
#
# Every frame the store shows must be one the shipping app can actually
# produce, so these are simulator captures of the app driven by its own
# DEBUG scaffolding — never a composite, never a mockup:
#
#   -UITestSeed  YES   an invented food-order transcript (ConversationViewModel)
#   -UITestRings YES   drives the real published properties a live session
#                      drives, cycling understanding -> translating every 4s
#
# The transcript is a hard-coded fixture of invented sentences. No real
# conversation is ever captured; the diagnostic log and anything a real user
# said stay off this path entirely.
#
# Usage:
#   Tools/appstore-shots.sh            capture both device sizes
#   Tools/appstore-shots.sh 63         just the 6.3"
#   Tools/appstore-shots.sh 69         just the 6.9"
#
# The captures land in .build/appstore-raw/ and are NOT copied over
# design/appstore/ automatically — choosing which moment of the animation
# ships is a judgement call, and on the 6.3" one frame needs a scroll nudge
# first (see "The 6.3" scroll" below). Flatten the ones you pick with:
#
#   Tools/appstore_flatten.py <raw.png> design/appstore/<name>.png --expect WxH
#
# The 6.3" scroll: the seeded transcript is slightly taller than the 6.3"
# viewport, so at the extremes of its scroll range either the first bubble
# sits under the language pill or the last sits under the status line. There
# is a position where neither does. Nudge the transcript there by hand
# before capturing — the 6.9" screen is tall enough that it does not arise.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

WHICH="${1:-both}"
APP_ID="com.klock.heikotranslate"
OUT=".build/appstore-raw"
DERIVED=".build/appstore-dd"

# name:udid-lookup:expected pixel size — the slot sizes App Store Connect
# wants for the 6.3" and 6.9" displays.
DEV_63="iPhone 17 Pro"
DEV_69="iPhone 17 Pro Max"
SIZE_63="1206x2622"
SIZE_69="1320x2868"

mkdir -p "$OUT"

echo "==> building (Debug — the seed and ring demo are #if DEBUG)"
xcodebuild -project HeikoTranslate.xcodeproj -scheme HeikoTranslate \
  -configuration Debug -destination "platform=iOS Simulator,name=$DEV_63" \
  -derivedDataPath "$DERIVED" build > "$OUT/build.log" 2>&1 \
  || { echo "!!  build failed — see $OUT/build.log" >&2; exit 1; }
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Heiko Translate.app"
[ -d "$APP" ] || { echo "!!  no .app at $APP" >&2; exit 1; }

capture() {
  local device=$1 tag=$2 expect=$3 udid
  udid=$(xcrun simctl list devices available \
         | grep -F "$device (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  if [ -z "$udid" ]; then
    echo "!!  no available simulator named '$device'" >&2
    return 1
  fi

  echo "==> $device ($udid)"
  xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1 || xcrun simctl boot "$udid" || true
  xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1 || true

  xcrun simctl install "$udid" "$APP"
  # Granted up front: the permission alert is a system window and would sit
  # in the middle of every frame. (Its own text is worth looking at on a
  # FRESH device — that dialog is where App Review 5.1.2(i) is satisfied —
  # but a simulator that already had the app caches the old purpose string,
  # so only an erased device shows a changed one.)
  xcrun simctl privacy "$udid" grant microphone "$APP_ID" || true
  xcrun simctl terminate "$udid" "$APP_ID" 2>/dev/null || true

  # The status bar Apple's own marketing uses: 9:41, full bars, charging.
  xcrun simctl status_bar "$udid" override \
    --time "09:41" --cellularBars 4 --wifiBars 3 \
    --batteryState charging --batteryLevel 100

  xcrun simctl launch "$udid" "$APP_ID" -UITestSeed YES -UITestRings YES
  sleep 4

  # One per second across a full 8s animation cycle, so both halves of it
  # (understanding, then translating) are on offer.
  local i
  for i in $(seq 1 9); do
    xcrun simctl io "$udid" screenshot --type=png "$OUT/$tag-$i.png" 2>/dev/null
    sleep 1
  done
  echo "    wrote $OUT/$tag-{1..9}.png  (expect $expect)"
}

case "$WHICH" in
  63)   capture "$DEV_63" de-63 "$SIZE_63" ;;
  69)   capture "$DEV_69" de-69 "$SIZE_69" ;;
  both) capture "$DEV_63" de-63 "$SIZE_63"; capture "$DEV_69" de-69 "$SIZE_69" ;;
  *)    echo "usage: $0 [63|69|both]" >&2; exit 2 ;;
esac

echo
echo "==> raw captures in $OUT — pick the frames, then flatten each:"
echo "    Tools/appstore_flatten.py $OUT/de-63-N.png design/appstore/de-63-conversation.png --expect $SIZE_63"
echo "    Tools/appstore_flatten.py $OUT/de-69-N.png design/appstore/de-69-conversation.png --expect $SIZE_69"
