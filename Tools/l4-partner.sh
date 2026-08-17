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
# Each entry is "<partner line>|<German the tester says back>". The German is
# a CUE, not a script — say it naturally, and say something else if that is
# what the moment calls for. It exists so the corpus comes out balanced by
# construction rather than by luck: the first real run (2026-08-17) produced
# six partner turns and ONE home turn, which cannot measure home-language
# detection at all.
#
# The replies get deliberately shorter as the exchange goes on, ending in
# one-word answers. That is not filler — TESTING.md records short utterances
# right after the other language as the documented hard case, and "Ja." after a
# French question is the smallest version of it that a real till produces.
case "$lang" in
  es) PHRASES=(
        "Hola, buenos días.|Guten Tag!"
        "¿En qué puedo ayudarle?|Ich hätte gern einen Kaffee."
        "¿Con leche?|Ja, bitte."
        "Son catorce euros con cincuenta.|Hier, bitte."
        "¿Quiere pagar con tarjeta?|Nein, bar."
        "¿Algo más?|Nein, danke."
        "La estación está a la derecha, después del semáforo.|Vielen Dank, das ist sehr nett."
        "¿Es usted de aquí?|Ich komme aus Deutschland."
        "¿Cuánto tiempo se queda?|Eine Woche."
        "Que tenga un buen día.|Danke, ebenfalls!"
      ) ;;
  fr) PHRASES=(
        "Bonjour, monsieur.|Guten Tag!"
        "Qu'est-ce que vous désirez ?|Ich hätte gern einen Kaffee."
        "Avec du lait ?|Ja, bitte."
        "Ça fait quatorze euros cinquante.|Hier, bitte."
        "Vous payez par carte ?|Nein, bar."
        "Et avec ceci ?|Nein, danke."
        "La gare est à droite, après le feu.|Vielen Dank, das ist sehr nett."
        "Vous êtes d'ici ?|Ich komme aus Deutschland."
        "Vous restez combien de temps ?|Eine Woche."
        "Bonne journée !|Danke, ebenfalls!"
      ) ;;
  en) PHRASES=(
        "Hello there.|Guten Tag!"
        "What can I get you?|Ich hätte gern einen Kaffee."
        "With milk?|Ja, bitte."
        "That'll be fourteen fifty.|Hier, bitte."
        "Are you paying by card?|Nein, bar."
        "Anything else?|Nein, danke."
        "The station is on the right, past the traffic lights.|Vielen Dank, das ist sehr nett."
        "Are you from around here?|Ich komme aus Deutschland."
        "How long are you staying?|Eine Woche."
        "Have a good day.|Danke, ebenfalls!"
      ) ;;
esac

# 12s is the measured default: the partner line takes 2-3s, the turn clock
# needs 1.4s of transcript idle to close it, and a short German reply plus its
# own pause fits in what is left. Longer wastes the run; shorter merges the two
# languages into one turn, which measures something else entirely.
auto=""
if [ "${1:-}" = "--auto" ]; then
  auto="${2:-12}"
elif [ -n "${1:-}" ]; then
  PHRASES=("$1")
fi

echo "Partner voice: $voice ($lang).  Phone unlocked, app open, mic ON."
echo "Say the GERMAN line after each partner line — it is a cue, not a script."
echo "Leave about a second of silence either side so it lands as its OWN turn."
echo "The point is a native partner voice against your native German."
echo
i=0
for p in "${PHRASES[@]}"; do
  i=$((i + 1))
  line="${p%%|*}"
  # A custom phrase passed on the command line carries no cue; `${p#*|}` would
  # then return the phrase itself, printing it as though it were German.
  case "$p" in *"|"*) cue="${p#*|}" ;; *) cue="" ;; esac
  echo "[$i/${#PHRASES[@]}] $line"
  say -v "$voice" "$line"
  [ -n "$cue" ] && printf '      \033[1msay in German:\033[0m %s\n' "$cue"
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
