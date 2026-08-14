#!/bin/bash
# Measure whether spoken numbers survive translation (GitHub #33).
#
# Device evidence on build 2.3.46 showed two failures wearing one costume:
# 185 heard as 184 (acoustic — vierundachtzig and fünfundachtzig differ by a
# syllable), and hundertfünfundachtzig written as "100 85" (compositional —
# the words were heard correctly and assembled wrongly, because German puts
# units before tens). This quantifies both on the wire path the app ships,
# so the mitigate-or-escalate decision rests on a rate rather than on one
# bad afternoon.
#
#   Tools/numberprobe.sh              # the whole corpus, de -> en
#   Tools/numberprobe.sh 3            # repeat each case 3 times
#
# Costs a few cents per pass. Uses `say` + the real GeminiLiveSession via
# floorprobe.sh — no device, no simulator.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

REPEATS="${1:-1}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# German sentence | comma-separated acceptable renderings of the VALUE.
# An all-digit alternative is matched against the digits of the output; any
# other alternative is matched case-insensitively against the raw text. Both
# forms are needed because English legitimately writes small numbers as
# words, and 16:42 legitimately becomes 4:42 PM — neither is the number
# being lost, and a harness that called them failures would overstate #33.
#
# Chosen for the two mechanisms: compound tens (unit-before-ten), the
# hundreds compound that failed on device, and prices, which are the case
# that actually matters at a counter.
CASES=(
  "Das macht hundertfünfundachtzig Euro.|185,one hundred eighty-five"
  "Das macht vierundachtzig Euro.|84,eighty-four"
  "Das macht einundzwanzig Euro.|21,twenty-one"
  "Das macht siebenundsiebzig Euro.|77,seventy-seven"
  "Das macht zweihundertdreiunddreißig Euro.|233,two hundred thirty-three"
  "Das macht vierzehn Euro fünfzig.|1450,14.50,fourteen fifty"
  "Ich hätte gerne fünfundzwanzig Stück.|25,twenty-five"
  "Der Zug fährt um sechzehn Uhr zweiundvierzig.|42,forty-two"
  "Das Zimmer hat die Nummer dreihundertzwölf.|312,three hundred twelve"
  "Wir sind zu neunt.|9,nine"
)

PASS=0; FAIL=0
printf "%-44s %-8s %s\n" "spoken (de)" "verdict" "heard back (en)"
printf "%-44s %-8s %s\n" "--------------------------------------------" "--------" "---------------"

for _ in $(seq 1 "$REPEATS"); do
  for case in "${CASES[@]}"; do
    text="${case%%|*}"
    want="${case##*|}"

    say -v Anna -o "$TMP/s.aiff" "$text" 2>/dev/null || {
      echo "!!  'say' has no German voice Anna installed — skipping" >&2; exit 2; }
    afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/s.aiff" "$TMP/s.wav"

    if OUT=$(./Tools/floorprobe.sh "$TMP/s.wav" en 2>/dev/null); then
      heard="${OUT#FLOORPROBE-OUT: }"
    else
      heard="(probe error)"
    fi

    # The measurement is whether the VALUE came through, not how it was
    # spelled: an all-digit alternative is checked against the output's
    # digits, anything else against the raw text.
    hit=0
    digits=$(printf '%s' "$heard" | tr -cd '0-9')
    IFS=',' read -ra WANTS <<< "$want"
    for w in "${WANTS[@]}"; do
      if [[ "$w" =~ ^[0-9]+$ ]]; then
        [[ "$digits" == *"$w"* ]] && { hit=1; break; }
      else
        printf '%s' "$heard" | grep -qi -- "$w" && { hit=1; break; }
      fi
    done
    if [ "$hit" -eq 1 ]; then
      verdict="ok"; PASS=$((PASS + 1))
    else
      verdict="LOST"; FAIL=$((FAIL + 1))
    fi
    printf "%-44s %-8s %s\n" "${text:0:42}" "$verdict" "${heard:0:46}"
  done
done

echo
TOTAL=$((PASS + FAIL))
echo "==> numbers survived $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] || echo "==> $FAIL lost — see #33"
