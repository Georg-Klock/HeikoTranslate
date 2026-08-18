# Turn Arbiter experiment

This branch moves turn ending from a collection of timers into an explicit,
testable lifecycle. It is deliberately incremental: it must preserve the
two-session translation architecture while making wrong-side speech, dropped
replies, and stale callbacks harder to create.

## The contract

An irreversible action — committing a bubble, releasing translation PCM, or
clearing turn state — must be attributable to one current turn. It is allowed
only when all of these are true:

1. the callback carries the active turn ID;
2. `SpeechEndPolicy` has confirmed the person stopped speaking;
3. input and relevant output have both been quiet for their configured tails;
4. the routing decision has enough attributable evidence to choose a side, or
   the system explicitly abstains.

The first three are lifecycle facts. The fourth is an arbitration fact. Keeping
them separate means a fast timer cannot accidentally decide language, and an
uncertain language decision cannot accidentally interrupt a person.

## First shipped slice on this branch

`TurnCoordinator` is the pure lifecycle owner. It assigns a local turn ID,
records input/output progress, and exposes the single finalization gate used by
the service and L3 replay harness. All input-idle, output-tail, speech-end
recheck, and deferred-finalize callbacks now carry the ID they were armed for.

This closes two concrete failure modes:

- transcript idleness could commit while the microphone still vetoed speech
  end; and
- a late timer from a reset turn could act on whichever shared state happened
  to be current.

## What the first device session showed

Measured 2026-08-18, build 2.4.75 EC, about thirteen minutes over two
sessions. Full numbers in TESTING.md's L4 row; what matters for the design:

- **Direction was right on all 17 bubbles**, across de↔en, de↔fr and fr↔en.
  The fr↔en run mattered most, because home was not German: the home side is
  a parameter here, and one garbled utterance whose partner session reported
  a third language still settled home correctly.
- **The lifecycle gate did its job in the one case that tested it.** A loud
  mic buffer vetoed a proposed stop; the turn sealed 0.25 s later once the
  mic went quiet. Nothing committed while someone was still talking.
- **The abstention gap is real and now has evidence.** One turn produced no
  translation from either session, deferred three times, and was cleared with
  no bubble and nothing shown. The person got silence and no reason for it.
  That is the "typed abstention/repair" slice below, and it is the first item
  on this list to have been observed rather than predicted.
- **The #83 resume path did not occur.** `speaker resumed during the commit
  window` appears zero times, so the reconciliation between #83's mic-resume
  and this branch's turn-ID threading rests on L1 alone. Provoking it needs a
  deliberate pause of about a second mid-sentence, and it should be an
  explicit case in the next device run rather than something waited for.

## Target shape

The completed experiment should make the next layer a pure `TurnArbiter`:

```text
timestamped evidence
  (turn ID, session generation, source, transcript patch, LID, VAD, output)
                            |
                            v
                    candidate ledger
         {home, foreign, third, abstain + reasons}
                            |
                 confidence margin / watermark
                            v
       provisional decision -> committed decision -> repair
                            |
                            v
                service effects (PCM, bubble, UI)
```

`TurnLogic` remains the routing policy until the ledger replaces its loose
language-keyed input/output maps. The arbiter must not introduce a third,
always-on “referee” session. A referee is a conditional, turn-scoped source-LID
check: shadow it first, require independent evidence and a confidence margin,
and permit `abstain` rather than inventing a confident answer.

## Next build slices

1. **Barge-in boundary.** Split a committed/draining turn from the next input
   candidate. Fresh VAD immediately ducks or stops old playback and gives the
   reply a new ID; its transcripts cannot append to committed evidence.
2. **Evidence provenance.** Attach turn ID, session generation, monotonic
   arrival time, and patch sequence to all model evidence. Quarantine or
   explicitly mark as inconclusive evidence that cannot be assigned.
3. **Arbitration outcomes.** Replace the nullable binary side with typed
   `home`, `foreign`, `third`, and `abstain` candidates, confidence and reason.
   Use language-pair/script profiles instead of German-specific constants.
4. **Repair state.** Surface a recoverable miss or a safe "please repeat"
   instead of silently clearing an exhausted ambiguous turn.
5. **Referee experiment.** Run the conditional referee in shadow mode, measure
   its independent accuracy and latency, and only then allow narrow overrides.

## Non-negotiable tests

- A loud mic plus quiet transcripts never commits or releases output.
- A late timer, reconnect packet, or audio packet cannot mutate another turn.
- A reply that begins during playback is captured as a separate candidate.
- Low-confidence or conflicting evidence produces an explicit abstention, not
  a wrong-side bubble.
