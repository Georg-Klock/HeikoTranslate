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
#
# Exit semantics (#84 review — this is a regression GATE, not just a
# counter): exit 0 ONLY when every run scored CORRECT. A WRONG run is a
# real direction failure; an INCONCLUSIVE run (session errors/timeout)
# says nothing about direction and means rerun; a CRASHED run (no result
# summary from l3replay at all — compile failure, harness abort) or a
# nonzero inner exit must never be silently absorbed into any bucket. The
# counts print regardless,
# so measurement baselines can still read a partial score off the output.
# Tools/tests/l3direction-scoring.sh pins all four outcomes with a stubbed
# l3replay, no network.
set -uo pipefail
cd "$(dirname "$0")/.."
case="${1:?usage: l3direction.sh TestAudio/<case>.wav [runs] [logdir]}"
runs="${2:-10}"
if ! [[ "$runs" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: runs must be a positive integer, got '$runs'" >&2
  exit 2
fi
name="$(basename "$case" .wav)"
logdir="${3:-.build/l3direction-$name-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$logdir"
partner=en; [[ "$name" == *_es ]] && partner=es
correct=0
wrong=0
inconclusive=0
crashed=0
for i in $(seq 1 "$runs"); do
  log="$logdir/run$i.log"
  L3_VERBOSE=1 Tools/l3replay.sh "$case" >"$log" 2>&1
  status=$?
  if [[ "$status" -ne 0 ]]; then
    crashed=$((crashed+1))
    echo "run $i: CRASHED (l3replay exit $status — see $log)"
    continue
  fi
  if ! grep -qE "^[0-9]+ passed, [0-9]+ failed$" "$log"; then
    crashed=$((crashed+1))
    echo "run $i: CRASHED (l3replay exit $status, no result summary — see $log)"
    continue
  fi
  if grep -q "❌ no session errors" "$log"; then
    inconclusive=$((inconclusive+1))
    echo "run $i: INCONCLUSIVE ($(grep '❌ no session errors' "$log" | head -1 | sed 's/.*: //'))"
    continue
  fi
  bubbles=$(grep -c "^    bubble " "$log")
  if [[ "$bubbles" == 2 ]] && grep -q "bubble 2: RIGHT (home) via $partner" "$log"; then
    correct=$((correct+1)); echo "run $i: CORRECT"
  else
    wrong=$((wrong+1))
    side=$(grep "bubble 2:" "$log" | head -1 | sed 's/^ *//')
    echo "run $i: WRONG (${bubbles} bubbles; ${side:-no second bubble})"
  fi
done
echo
echo "$name: $correct/$runs correct, $wrong wrong, $inconclusive inconclusive, $crashed crashed — logs in $logdir"
[[ "$correct" -eq "$runs" ]]
