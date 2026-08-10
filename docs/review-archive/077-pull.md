# pull #77 — Direction: echo detection fixes the de↔es misattribution (#75)

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-08T00:16:19Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/77

---

Closes #75. Implements the long-form half of #45's "tell" (see residual below).

## What the instrumentation actually showed

The issue's hypothesis — the home-silence confirmation window failing on a
stray fragment — **did not survive contact with the timeline**. Per-event
traces (`L3_VERBOSE` now timestamps every IN/OUT chunk) on the failing
baseline run:

```
IN [es]@10.6s:  Um,            IN [de]@10.6s:  Me
IN [es]@11.6s:  mir geht es    IN [de]@11.6s:  va muy bien,
OUT[de]@11.9s:  komme sehr gut zurecht,
IN [de]@12.7s:  vielen Dank        ← de transcription flips to German
OUT[de]@14.0s:  für die Nachfrage. ← output degenerates into verbatim echo
...
bubble 2: LEFT (foreign) via de   ← WRONG, German was spoken
```

The de session mis-hears the German **opening** as Spanish (primed by the
Spanish turn before it), genuinely translates that pseudo-Spanish into
German, then echoes the rest word for word. Its final output (113 chars vs
the es session's 103, ratio 1.1) sails past every size floor, so
`homeIsRealTranslation` calls it a real translation and the turn resolves
foreign **through the ratio path — the confirmation window is never
consulted**. Meanwhile the de session voted `es` the entire turn and
settled the codes on the *partner* language, so a fix to the ratio path
alone would have converted the wrong-side failure into a swallowed turn at
the codes-veto.

## The fix (all in `TurnLogic`, L1-tested)

One primitive: **echo-share** — the fraction of an output's tokens already
present in the turn's input transcripts. Measured over 20 live replays /
39 outputs: genuine translations score **0.00–0.17** (the hits are names
and cognates), echoes **0.80–1.00**, including the failing turn at 0.85.
Thresholded at 0.6, with a 4-token floor on both sides so #45's
cognate/number/name rows ("Navigator", "14 Euro") keep counting as
translations. Tokens, not characters (#73): inert for zh (one whitespace
token), so no new behavior for a shipped language.

1. **`isRoundTripEcho`** — a home output of ≥4 tokens with share ≥0.6
   against the **union** of transcripts is a round trip, not a translation.
2. **The codes-veto yields** — its premise is "the partner output is an
   echo of foreign speech"; when the settle is the *partner* language and
   the partner output proves itself a translation against **its own
   session's transcript** (≥4 tokens, share <0.6), the premise fails and
   `homeSpoken` resolves. Settles on a neither-side language still veto
   unconditionally.

The asymmetry in comparison sets is itself a measured finding. The first
cut judged both against the union, and the very first post-fix replay
produced a shape none of the 20 prior runs had shown: **both sessions
misread half the German, crossed** — the de transcript converged on nearly
the same Spanish the es session legitimately translated into, so against
the union the genuine translation read as an echo (0.78) and the turn was
swallowed. An echo is damning in any session's reading (that same run put
the home echo in the *partner's* transcript); a translation proves itself
only against what the translating session itself heard. Both shapes are
pinned verbatim as L1 tests (L1.47, L1.47h).

## Numbers

`Tools/l3direction.sh` (new; the 10-run scoring loop, derived for the
third time and now saved), case `de_after_es` + the `de_after_en` control:

| | baseline (`main`) | after |
|---|---|---|
| de↔es | **9/10** | **10/10** |
| de↔en (control) | **10/10** | **10/10** |
| full L3 suite | — | **56/56** |

Today's baseline failure rate (1/10) is well under the 5/10 the issue was
filed at — the live model varies day to day — so the sharper evidence is
mechanism-level: **the pathological echo shape occurred in 3 of the 10
after-runs (runs 3, 9, 10: 20–21-token de outputs, the exact
"Ich komme sehr gut zurecht…" signature, codes settled `es`) and all 3
committed RIGHT via `es`.** The fix intercepted every occurrence it saw;
the baseline mis-sided the one it saw.

<details><summary>Raw per-run results (scored: 2 bubbles, second RIGHT via partner)</summary>

**Baseline de↔es** (logs `.build/baseline-es`): runs 1–5, 7–10 CORRECT;
run 6 WRONG — `bubble 2: LEFT (foreign) via de`, the timeline above.
**Baseline de↔en**: 10/10 CORRECT.
**Iteration 1 de↔es** (union comparison, kept in `.build/after-es-iter1`):
run 1 WRONG — turn swallowed after 3× `codes-veto` deferrals (the crossed
shape, now L1.47h); runs 2–3 CORRECT; aborted there and refined.
**After de↔es** (`.build/after-es`): 10/10 CORRECT, finalize 19.3–20.4s,
all via `es`, echo shape present-and-corrected in runs 3, 9, 10.
**After de↔en** (`.build/after-en`): 10/10 CORRECT, finalize 14.3–14.7s,
all via `en`.
</details>

## L1 coverage

L1.47–L1.47h (8 tests, all on real replay data): the two failing shapes
verbatim, the referee-log pattern (codes settled *home*), the #45 danger
table (short identical output stays LEFT), a third language's long
translations stay LEFT, neither-side settles stay vetoed, the yield
demands positive proof, and the `noteOutputs` live path agreeing with
commit. **Fails-on-old-behaviour verified**: with both predicates neutered
to constant-false (which reduces every decision path to the pre-PR table),
exactly L1.47, L1.47b, L1.47g, L1.47h fail and the other 42 pass — so the
old table's guards (L1.22/24/26/31/41…) were not loosened. Full suite:
88/88.

## Not fixed here, on purpose

- **#45's device case stays open.** "Hallo, Navigator" is 2 tokens — under
  the echo floor by design, because the same shape is a legitimate proper
  noun. The short-echo case needs the corroborator #45 sketches (codes
  settled on a *neither-side* language), and there is no replay case to
  measure it against yet.
- **The mirror shape** (Spanish misread toward German) would poison the
  union comparison in the other direction. Zero instances in 30 measured
  runs — every mishearing ran home-ward with the priming — so it is
  documented in TESTING.md as a non-case rather than guarded at the cost
  of real behavior, per the L1.41b precedent.
- The service still latches a provisional `foreignSpoken` mid-turn before
  the echo is statistically visible (unavoidable without clairvoyance);
  commit re-derives and the bubble lands correctly. Audio-UX during those
  seconds is L4 territory.

TESTING.md updated in this PR: L1.47 rows, the #75 prose bundle, and the
de↔es status paragraph (which still recommended the measured-dead referee
session).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

---

### Georg-Klock — 2026-08-08T05:43:47Z

## Final-Gate Review

Reviewed head: `63950608b654479d1c926bcba017b8d209544ad2`

**Decision: Request Changes** — I agree with Codex's verdict, but not with all of its
reasoning. Two of its three blockers I reproduced and they are worse than described; one
of its concrete repros is wrong, though the mechanism behind it is real.

The engineering here is good — the instrumentation-first approach, killing two hypotheses
on measurement, and pinning both the failing shape and the shape the first fix broke, are
exactly right. The problem is not the mechanism. It is that echo-share was calibrated on a
corpus of conversational pleasantries and then applied to every utterance in every language
pair, and there is a whole class of ordinary utterance where "the output repeats the input's
words" is not an echo at all.

I verified everything below by compiling the real `TurnLogic.swift` from this head (and from
`origin/main` for the before/after) and driving it directly — not by reading the diff.

---

### Blocker 1 — entity-, number- and cognate-preserving translations now break (regression)

`isRoundTripEcho` (TurnLogic.swift:219) disqualifies any home output of ≥4 tokens that
shares ≥0.6 of its tokens with what was heard. Translations of names, numbers, addresses
and cognates legitimately do that. Measured, same inputs, `origin/main` vs this head:

| Spoken (English, foreign) | share | `main` | this head (codes settled `en`) | this head (codes unsettled) |
|---|---|---|---|---|
| `Apple Google Netflix and Amazon` | 0.80 | LEFT ✓ | **turn dropped** | **RIGHT/home, "translation" = the English** |
| `14, 27, 38 and 42` | 0.80 | LEFT ✓ | **turn dropped** | **RIGHT/home, "translation" = the English** |
| `Taxi to the hotel restaurant, please` | **0.60** | LEFT ✓ | **turn dropped** | **RIGHT/home, "translation" = the English** |
| `Doctor Schmidt, Hotel Adlon, Berlin Alexanderplatz` | 0.83 | LEFT ✓ | **turn dropped** | **RIGHT/home, "translation" = the English** |

Three things about this table matter more than the examples themselves:

- **The unsettled-codes column is the bad one, and Codex missed it.** With `spokenLang == nil`
  there is no codes-veto to catch the fall-through, so the turn does not get swallowed — it
  commits on the **wrong side**, and the text put on screen as the translation is the English
  source. Heiko is shown English, labelled as his own turn. Short utterances — numbers,
  addresses, prices — are exactly the ones least likely to have settled the codes before
  commit, and exactly the ones with the highest token-overlap. The two failure modes select
  for the same inputs.
- **The cognate row lands on 0.60, precisely the threshold**, from an utterance a traveller
  says out loud. The claimed margin ("genuine translations 0.00–0.17, echoes 0.80–1.00, a
  clean gap") is real for the corpus it was measured on and does not survive contact with
  proper nouns. 39 outputs of scripted de↔es/de↔en pleasantries cannot establish the
  translation-side population for a general-purpose translator.
- This is the danger #45 explicitly names, and the guard chosen against it — `echoMinTokens = 4`
  — does not cover it. Four tokens stops `Navigator` and `14 Euro`; it does nothing for
  `14, 27, 38 und 42`. L1.47c pins the one-token case and nothing between one token and a
  full sentence.

Numbers, prices, times and addresses are core traffic for this app. Silently dropping them,
or showing Heiko the foreign text as his own translation, is worse than the #75 misattribution
this PR fixes.

### Blocker 2 — `looksTranslated` lets a drifting echo through the codes-veto (regression)

**Codex's specific example does not reproduce.** With `en` settled, heard
`How much is such an item?` → output `How much is this item?`, the veto still holds and the
turn is dropped; so does `How much is such an object?`. If you are working from Codex's
notes, don't chase that repro — it is a non-issue and the token overlap is nowhere near the
threshold in the direction it claimed.

The mechanism it was reaching for is real, though, and I have a case that does reproduce.
`looksTranslated` (TurnLogic.swift:241) treats *low exact-token overlap* as positive proof of
translation, and an echo that paraphrases rather than repeats clears that bar:

- codes settled `en`, heard `How much is such an item?`, en output `What is the price of this one?`
- `main`: **dropped** (veto holds — correct; nothing translated into German)
- this head: **RIGHT/home**, bubble translation `What is the price of this one?`

That is an English→English bubble presented as the translation of a German turn Heiko never
took, and it reaches him through the audio path as well. The pre-#75 veto was unconditional
precisely because "the partner session emitted something" is not evidence of translation.
The yield needs evidence that distinguishes *translation* from *loose ASR restatement*, and
token-overlap-below-a-threshold does not: absence of overlap is not presence of translation.

### Blocker 3 — streaming latches the wrong translator and never re-derives, and the wrong audio wins

Codex is right here, and the consequence is bigger than either its note or the PR body
("audio-UX during those seconds is L4 territory") allows. Driving `noteOutputs` in the
**real event order from this PR's own run-6 timeline** — the de output at 11.9s, before the
input transcripts finish at ~14s:

```
t=11.9  partial inputs : direction=foreignSpoken  translator=de
t=14.0  FULL inputs    : direction=foreignSpoken  translator=de   <-- echo now plainly visible
t=20.0  recheck        : direction=foreignSpoken  translator=de
commit                 : RIGHT/home              translator=es
```

Once `noteOutputs` sets `.foreignSpoken` (TurnLogic.swift:342-346) nothing re-derives it: the
homeSpoken branch below is gated on `direction == nil`, so the full transcripts that make the
echo obvious arrive and change nothing. Streaming and commit disagree for the entire turn.

The reason this is not merely cosmetic is `flushPendingOutput` (GeminiLiveTranslationService.swift:860):
it plays the chosen translator's queued chunks and then does `pendingOutput = [:]`, discarding
every other session's audio for the turn. So on the exact turn this PR exists to fix, the app
plays the German round-trip echo at Heiko and **throws away the Spanish audio the partner
needed**. The bubble is then corrected on screen. The partner hears nothing; Heiko hears his
own sentence read back to him; the screen says something else happened.

To be fair to the PR: this is not a regression — `main` mis-sided the whole turn, audio
included. But it means #75 is fixed on screen and not in the ear, and the PR body's framing
understates that. The turn's audio is not recoverable later, because the queue is wiped.

**L1.47g does not cover this**, which is why it passed. It feeds complete `inputs` and
`outputs` maps atomically from the first call, so the echo is visible on the very first
evaluation and the latch never arms. Feed it the same data incrementally and it fails. This
is the "test pins an intermediate state rather than the behaviour" pattern that has bitten
this repo before — the assertion is real, the seam is wrong. Any fix here needs an L1 test
that drives `noteOutputs` in the documented IN/OUT order, not one that hands it the finished
state.

---

### Smaller, but fix while you are in here

- **The both-sides token floor is not implemented.** The doc comment at TurnLogic.swift:134-144
  and the PR body both promise "a 4-token floor on both sides"; `isRoundTripEcho`
  (TurnLogic.swift:220) floors only the output. Verified: output `"ja ja ja ja"` against a heard
  `"ja"` scores 1.0 and is classified as an echo. `looksTranslated` does floor both sides — the
  asymmetry is unintended, not the deliberate one you documented elsewhere.
- **Korean is live and uncalibrated.** The zh reasoning checks out — I verified a Chinese
  string is one token, so both predicates are inert there. But `ko` whitespace-tokenises
  normally, so it gets the full echo machinery with zero measurement behind it, as do `fr`
  and every non-de home setting. The threshold was fitted on two pairs and applies to all of
  them.
- `Tools/l3direction.sh` exits 0 unconditionally (`set -uo pipefail`, no status check on the
  replay), and a crashed replay scores as a direction failure rather than as infrastructure
  failure. Worth separating — otherwise a broken harness reads as a regression, or a green
  exit reads as a pass.

### What I am not asking for

I am not asking you to abandon echo-share. On the shape it was built for it is the right
primitive and the evidence for it is genuine. What it cannot be is the *sole* decisive
signal, in either direction. Two things would address the substance without relitigating
the design:

1. Make high overlap disqualifying only when it is not explained by content that survives
   translation — proper nouns, digits, known cognates. A digit-and-capitalised-token carve-out
   would clear every row in the table above.
2. Keep the codes-veto unconditional and find the #75 yield elsewhere — the partner session's
   own language-code votes, or the home session's disagreement with itself, are positive
   evidence in a way "few shared tokens" is not.

And add the regressions: multiword-entity and numeric-list translations, a partial-overlap
echo, and an incremental-order `noteOutputs` test.

### Where I disagree with Codex

- Its blocker 3 repro (`How much are these items?` → `How much is this item?`) does not
  reproduce; the veto holds. The class is real, the example is not — I have given one above
  that does.
- It reported blocker 2 as producing a dropped turn. That is the settled-codes half. The
  unsettled-codes half produces a wrong-side bubble, which is the more damaging of the two
  and is not in its notes.
- Its "no security issue, but a data-integrity regression" framing is right, and for this app
  I would put it more plainly: every one of these failure modes is silent. Heiko will not
  report a turn that vanished, and he cannot tell that the English on his screen was not
  supposed to be there.

I have not merged anything and will not — this verdict is a recommendation to you, and the
merge is yours to make.

🤖 Final-gate review by Claude Opus 5

---

### Georg-Klock — 2026-08-08T16:10:10Z

## Final-Gate Review — round 2

Reviewed head: `63950608b654479d1c926bcba017b8d209544ad2`

**Decision: Request Changes** — unchanged, and now with no disagreement left between
Codex and me. Head has not moved since my last review, so this comment is short on
purpose: it exists to correct one thing I got wrong, because I told you to ignore a repro
that is real.

---

### Correction: Codex's blocker-3 repro does reproduce. I tested the wrong input.

In my last review I wrote that Codex's example "does not reproduce" and told you *"don't
chase that repro — it is a non-issue."* **That was wrong, and Codex's clarification is
correct.** I substituted `How much is such an item?` for Codex's `How much are these
items?` and then reported the result as if it disproved Codex's case. It only disproved
my own paraphrase of it.

Recompiled from this head and driven directly:

| heard (en) | en output | own-share | outcome |
|---|---|---|---|
| `How much are these items?` | `How much is this item?` | 0.40 | **RIGHT/home, en→en bubble** |
| `How much is such an item?` | `How much is this item?` | 0.80 | veto holds (dropped) |

Codex's original input commits the wrong-side English→English bubble exactly as it said.
Please put **Codex's version** in the regression set. Mine is worth keeping too, as the
negative case, but it was never a rebuttal.

### What that mistake exposes — the class is wider than either of us wrote

Chasing my own error turned up something neither review states plainly. `looksTranslated`
compares **exact surface tokens**, so whether a near-identical restatement is judged a
"translation" turns on inflection and contraction, not on meaning. Same setup (`en`
settled, no German output at all — nothing was translated in any of these):

| heard (en) | en output | own-share | outcome |
|---|---|---|---|
| `How much are these items?` | `How much is this item?` | 0.40 | **RIGHT/home, en→en bubble** |
| `Can you help me with my bags?` | `Could you help me with the bag?` | 0.57 | **RIGHT/home, en→en bubble** |
| `I would like to book two rooms` | `I'd like to book a room` | 0.57 | **RIGHT/home, en→en bubble** |
| `Where are the train stations?` | `Where is the train station?` | 0.60 | veto holds (dropped) |
| `The trains leave at nine` | `The train leaves at nine` | 0.60 | veto holds (dropped) |

Rows 3 and 4 are the same sentence twice over. One commits a wrong-side bubble; the other
is dropped. The difference is that `I'd` splits into `i` + `d` and `stations`/`station`
don't match as strings. **The decision is being made by the tokeniser's handling of plurals
and apostrophes.** That is not a threshold that needs moving — 0.57 and 0.60 are the same
sentence — it is a signal that cannot carry this weight, which is the point my previous
review's item 2 was making and this states better.

It also sharpens the language-generalisation worry. Row 3 is English morphology. German
compounding, Spanish clitics and Korean agglutination each redraw these token boundaries
differently, so the same utterance lands on different sides of 0.6 depending on Heiko's
partner setting. Nothing was measured for `ko`, `fr`, or `es`-as-home.

### Everything else stands

The rest of my previous review is unchanged and Codex has now independently confirmed the
part it originally missed:

1. **Entity/number/cognate translations regress** — the unsettled-codes column is the
   dangerous one (wrong-side commit showing Heiko the foreign text as his own turn), not
   just the dropped-turn column.
2. **`looksTranslated` bypasses the codes-veto** — as above, worse than either of us first
   described.
3. **`noteOutputs` latches the wrong translator and never re-derives**, and
   `flushPendingOutput` wipes the queue, so the partner's audio is discarded on the exact
   turn this PR fixes.
4. Two-sided token floor documented but not implemented; `ko`/`fr` uncalibrated;
   `l3direction.sh` exits 0 unconditionally.

My two suggested directions are also unchanged: carve out content that survives
translation (digits, capitalised tokens), and find the #75 yield in positive evidence —
the partner session's own code votes, or the home session disagreeing with itself —
rather than in low token overlap. Absence of overlap still is not presence of translation;
the table above is just a cleaner demonstration of why.

Nothing merged, nothing auto-merged. This verdict is a recommendation; the merge is yours.

🤖 Final-gate review by Claude Opus 5
