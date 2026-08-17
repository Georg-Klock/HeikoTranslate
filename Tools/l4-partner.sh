#!/bin/bash
# A NATIVE partner voice for device testing, from the laptop (#125).
#
# Every device measurement this project has is one tester speaking both
# languages, and the second language carries their accent — the recorded case
# of ten English utterances transcribed AS GERMAN by the `de` session is
# exactly that artifact (TESTING.md, "Who is speaking, and why it changes what
# the evidence means"). So a de↔es or de↔fr failure rate measured solo cannot
# distinguish "the arbitration is broken" from "the model never heard Spanish".
#
# This plays the PARTNER side in a natively-trained voice while the tester
# speaks the home side in their own native German. That is the real
# configuration — native German, native foreign — without needing a second
# person in the room.
#
#   Tools/l4-partner.sh es            # the Spanish script, one line per Enter
#   Tools/l4-partner.sh fr
#   Tools/l4-partner.sh es --auto 12  # hands-free, 12s between lines
#   Tools/l4-partner.sh es "¿Cuánto cuesta?"   # one custom line
#
# READ THIS BEFORE TRUSTING A PASS. Synthetic speech is cleaner than a human:
# no disfluency, no room, no breath, steady prosody. TESTING.md already records
# that a TTS fixture could not reproduce #32 and that "the remaining difference
# is a human voice". So the two outcomes are NOT symmetric:
#
#   * The turns still collapse  -> the bug is REAL and is not about accent.
#     This is the strong result, and the one worth having.
#   * The turns come out clean  -> accent is implicated, but not proven; TTS
#     removed several human qualities at once. Treat as a lead, not a verdict.
#
# Place the phone about where a person's mouth would be relative to the laptop
# speakers — a hand's width or so — at ordinary conversational volume. Too loud
# clips the mic and measures the wrong thing.
set -euo pipefail
cd "$(dirname "$0")/.."

lang="${1:?usage: l4-partner.sh <es|fr|en> [--auto SECONDS | \"custom phrase\"]}"
shift || true

case "$lang" in
  es) voice="Paulina" ;;   # es_MX — the app's Spanish target (SPEC §3.1)
  fr) voice="Jacques" ;;   # fr_FR
  en) voice="Daniel"  ;;   # en_GB, distinct from a US-accented tester
  *)  echo "unsupported language '$lang' (es, fr, en)" >&2; exit 2 ;;
esac

# Override the voice: PARTNER_VOICE=Thomas Tools/l4-partner.sh fr
#
# This is not a cosmetic knob. The outcomes below are asymmetric only if the
# voice is a fair stand-in for a native speaker — "a collapse is a REAL bug"
# stops being true if the collapse was caused by the voice. Jacques in
# particular was judged poor on listening (2026-08-17); Thomas is the other
# fr_FR option, and macOS also ships newer fr_FR variants (Eddy, Flo, Shelley).
# `say -v '?'` lists what is installed. If a run collapses, repeat it with a
# different voice before believing the result.
voice="${PARTNER_VOICE:-$voice}"

if ! say -v "$voice" "" >/dev/null 2>&1; then
  echo "Voice '$voice' is not installed." >&2
  echo "Add it: System Settings -> Accessibility -> Spoken Content -> System Voices." >&2
  exit 1
fi

# Ordinary things the other side of a counter or a street actually says. Kept
# short, because short utterances are where the arbitration fails (TESTING.md
# §L3: a short sentence right after the other language is the hard case).
case "$lang" in
  es) PHRASES=(
        "Hola, buenos días."
        "¿En qué puedo ayudarle?"
        "Son catorce euros con cincuenta."
        "¿Quiere pagar con tarjeta?"
        "La estación está a la derecha, después del semáforo."
        "Perdone, ¿de dónde es usted?"
      ) ;;
  fr) PHRASES=(
        "Bonjour, monsieur."
        "Qu'est-ce que vous désirez ?"
        "Ça fait quatorze euros cinquante."
        "Vous payez par carte ?"
        "La gare est à droite, après le feu."
        "Excusez-moi, vous venez d'où ?"
      ) ;;
  en) PHRASES=(
        "Hello there."
        "What can I get you?"
        "That'll be fourteen fifty."
        "Are you paying by card?"
        "The station is on the right, past the traffic lights."
        "Sorry, where are you from?"
      ) ;;
esac

auto=""
if [ "${1:-}" = "--auto" ]; then
  auto="${2:?--auto needs a number of seconds}"
elif [ -n "${1:-}" ]; then
  PHRASES=("$1")
fi

echo "Partner voice: $voice ($lang).  Phone unlocked, app open, mic ON."
echo "Reply in GERMAN after each line, as you normally would."
echo "The point is a native partner voice against your native German."
echo
i=0
for p in "${PHRASES[@]}"; do
  i=$((i + 1))
  echo "[$i/${#PHRASES[@]}] $p"
  say -v "$voice" "$p"
  if [ -n "$auto" ]; then
    sleep "$auto"
  else
    # Wait for the tester to finish replying. Reading from the terminal keeps
    # the pace human, which matters: the turn clock is 1.4s of transcript idle
    # plus a mic veto, so a machine-gun sequence measures something else.
    printf '      … reply in German, then press Enter for the next line: '
    read -r _ </dev/tty || true
  fi
done
echo
echo "Done. Now: Tools/pull_logs.sh"
echo "Then read the 'commit' lines and their 'why:' lines for these turns."
echo "A collapse here is a REAL bug. A clean run is a lead, not a verdict."
