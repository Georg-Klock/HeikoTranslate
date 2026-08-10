#!/bin/bash
# Direction-accuracy measurement loop (GitHub #75): run one L3 replay case N
# times, keep each run's full verbose log, and score each run by whether the
# turn landed on the correct side.
#
#   Tools/l3direction.sh TestAudio/de_after_es.wav [runs] [logdir]
#
# A run is CORRECT when it produced exactly 2 bubbles and bubble 2 committed
# RIGHT (home) via the partner session — the shape both de_after_* cases
# expect. Talks to the live API: each run costs a few cents.
#
# This loop has been derived from scratch twice (the referee experiment and
# #75); it lives here so the third measurement uses the same scoring as the
# first two.
set -uo pipefail
cd "$(dirname "$0")/.."
case="${1:?usage: l3direction.sh TestAudio/<case>.wav [runs] [logdir]}"
runs="${2:-10}"
name="$(basename "$case" .wav)"
logdir="${3:-.build/l3direction-$name-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$logdir"
partner=en; [[ "$name" == *_es ]] && partner=es
correct=0
for i in $(seq 1 "$runs"); do
  log="$logdir/run$i.log"
  L3_VERBOSE=1 Tools/l3replay.sh "$case" >"$log" 2>&1
  bubbles=$(grep -c "^    bubble " "$log")
  if [[ "$bubbles" == 2 ]] && grep -q "bubble 2: RIGHT (home) via $partner" "$log"; then
    correct=$((correct+1)); echo "run $i: CORRECT"
  else
    side=$(grep "bubble 2:" "$log" | head -1 | sed 's/^ *//')
    echo "run $i: WRONG (${bubbles} bubbles; ${side:-no second bubble})"
  fi
done
echo
echo "$name: $correct/$runs correct — logs in $logdir"
