# Pair restriction, and why it does not apply to the language codes (#135)

**Status: not implemented. Negative finding, recorded so it is not retried.**
No code changed; L1 260/260, exactly as branched from the 2.4.65 commit.

**Where the code is.** This page is on `main`. The branch that carried it was
archived as the tag **`archive/pair-restriction`** (commit `8bece0b`) and then
deleted. `Tools/lid-bench.py`, which produced the numbers below, lives on
`archive/interpreter-mode`.

## The idea

Restricting a language classifier's output to the two configured languages is
free and large. Measured with `Tools/lid-bench.py` on `TestAudio`: whisper-tiny
goes from **89.5% open-set to 100% pair-restricted** at full clip length, and
the same holds for SpeechBrain ECAPA and Silero. Google's tuplemax-loss paper
(ICASSP 2019) reports the effect for the same reason — most of the error is
probability mass sitting on languages that cannot be the answer, and the app
always knows both languages in advance.

So: apply it to the referee.

## Why there is nowhere to apply it

**The referee is already pair-restricted.** `LanguageReferee` runs exactly two
`SFSpeechRecognizer`s, one per side, and `RefereeEvidence` compares two
`Reading`s. There is no wider candidate set to narrow.

The only place a wider-than-pair decision happens on the shipping path is
`TurnLogic.noteInputLanguage`, where the Gemini sessions' reported input
language codes are counted. A code naming any of the eight app languages casts
a global vote, including languages that are in neither side of the current
pair — which is where #125's impossible settle comes from.

Restricting those votes to `[home, partner]` was tried here and **reverted**.

## What it broke, and why that is correct

Seven L1 tests failed. Three (L1.17, L1.34, L1.38) used a third language as an
incidental fixture and could have been rewritten. The other four could not, and
L1.47e states the reason plainly:

> a neither-side settle has no translation to trust

A settle on `fr` under a de↔es pair correctly **vetoes** the turn. Under the
restriction those votes vanish, no settle forms, no veto arms — and genuinely
foreign speech could commit as though the home language had been spoken.

**The codes are not a two-way classifier, so the two-way trick does not
transfer.** They answer a different question: *was the speech the home
language, or not?* A third language is meaningful evidence for "not home", and
throwing it away throws away the answer. The type's own doc has said this from
the beginning — codes "are used only as a veto — never to decide a side" — and
a veto only needs home/not-home.

The bench result is about a classifier CHOOSING between two candidates. The
codes are a witness reporting what they heard. Narrowing a choice discards
impossible options; narrowing a report discards evidence.

## Where the win is still available

Unchanged and still true: **any LID model added as a second witness should be
scored over the configured pair, never over its full label set.** That is
Phase 2 of #135 and it is unbuilt. `Tools/lid-bench.py` already scores both
ways for exactly this comparison, and the pair-restricted column is the one to
read.

The distinction to carry forward: restriction belongs at the point where a
model is asked *which of these two*, not at the point where a session reports
*what I heard*.
