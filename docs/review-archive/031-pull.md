# pull #31 — Share the finalize-deferral policy between the app and the L3 harness

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-05T02:13:53Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/31

---

Fixes #21. This one changed what we know about #18.

## The drift

The L3 harness — the gate `release.sh` runs before every upload — kept a hand-maintained copy of the service's per-utterance orchestration, and had drifted at the decision that matters most. The app **defers** a finalize that would drop a turn whose translation hasn't arrived (SPEC §5.1, *"keep showing live text and wait"*), retrying up to 3 times over ~6 seconds. The harness had **no deferral at all** — 7 references in the service, 0 in `Tools/l3replay/main.swift`.

The decision now lives in `Models/FinalizePolicy.swift`, compiled by both. Drift becomes a compile error.

## Measured impact — the reason this mattered

Same 10 `de_after_es` replays against the live API, before and after:

| | Correct | Turn lost | Over-segmented | **Wrong side** |
|---|---|---|---|---|
| Before (19 runs) | 32% | 47% | 11% | 11% |
| After deferral, no retry guard (10) | 20% | 20% | 30% | 30% |
| **After, complete (10)** | **50%** | **0%** | **0%** | **50%** |

**Every run now produces exactly two bubbles.** Turn boundaries are stable; lost and split turns are gone entirely.

So the previous baseline was substantially *the instrument*. Nearly half of what looked like de↔es failure was the harness wiping turns the app would have recovered.

## What this does to #18

The remaining failure is now clean and singular: **50% of German-after-Spanish turns land on the wrong side.** That is precisely — and only — what a referee session addresses.

This inverts my earlier read. On the noisy baseline the referee looked like it targeted 11% of runs and wasn't worth ~50% more tokens per conversation. On a baseline that describes the app, it targets **100% of the remaining failures**, on a coin-flip that Heiko would hit every other sentence in Spanish. #18 is justified — now with a real before/after number to measure the fix against.

## A divergence I introduced, then caught

The first re-measure came back *worse* (20% correct, over-segmentation 11% → 30%). The service's deferral timer skips its retry when speech has resumed — *"don't force-finalize mid-sentence"* — and my harness retried unconditionally, finalizing a held-open turn on top of the next utterance. Second commit adds the guard; over-segmentation went to 0%.

Worth being plain about: I introduced that in the same commit that closed the original drift. The *decision* is now shared, but the retry's surrounding conditions are still written twice. **The extraction is incomplete**, and this is evidence for finishing it rather than proof it's done.

## Deliberately not extracted

The harness's timing constants are wider than the app's on purpose (*"widened for jitter"*, documented at their definition) — an adaptation to running over a real network with no audio hardware, not drift. Extracting the whole orchestration is a far larger, riskier refactor of the timing logic that took the most device work to get right.

L1 **48/48** (this branch is based on `main`, so it doesn't carry the 4 tests from the open #29/#30 branches). L1.33–L1.33e cover the policy.

---

### Georg-Klock — 2026-08-05T02:32:11Z

## Adversarial review

Reviewed against both call sites at this branch's head. The diagnosis is right, extracting `FinalizePolicy` is the right move, and "the extraction is incomplete, and this is evidence for finishing it rather than proof it's done" is the correct framing. Two structural problems remain, and one of them is live.

### 1. "Same guard as the service's deferral timer" — it isn't (blocking)

`Tools/l3replay/main.swift:252`

```swift
if now.timeIntervalSince(lastContentAt) >= 1.0 { finalizeTurn() }
```

`GeminiLiveTranslationService.swift:1026`

```swift
if Date().timeIntervalSince(self.lastInputAt) < 1.0 { return }
```

Different clocks. `lastInputAt` is set only by `noteInputActivity()`, which is called only from the `.inputTranscript` branch — **input speech, nothing else**. The harness's `lastContentAt` is bumped by three things:

- `.inputTranscript` (`main.swift:207`) — matches the intent
- `.outputTranscript` (`main.swift:212`) — the model's **translation text**
- `.audioChunk` above the RMS floor (`main.swift:200`) — the model's **translated audio**

So in the harness, the late-arriving translation — the exact thing the deferral is waiting for — resets the guard clock. Walk the success path this feature exists to serve:

- T+0.0 finalize rejects with `codes-veto`, the German translation is still in flight → defer, `deferUntil = T+2.0`
- T+1.8 the German translation text starts arriving
  - service: `lastInputAt` unchanged (speaker stopped seconds ago)
  - harness: `lastContentAt = T+1.8`
- T+2.0 interval elapses
  - **service:** `now - lastInputAt` ≫ 1.0 → retries → commits the now-complete turn on the deferral clock
  - **harness:** `now - lastContentAt` = 0.2 < 1.0 → **skips the retry**

The harness then falls through to the ordinary `tick()` branches, which need `outputQuiet` (>1.1s since `lastOutputAt`) — and `lastOutputAt` was just bumped by the same arriving translation. So it finalizes at least ~1.1s later than the app, on a different clock, every time the awaited translation lands near the deferral boundary.

Both eventually commit, so **L3 stays green while the timing diverges** — which is precisely the "a mirror copy passes forever while the app regresses" failure this PR exists to end. Same class of bug, one layer down, in the guard added to fix the first one.

The guard should compare against an input-only clock. The harness already has the ingredients — it just needs its own `lastInputAt` set in the `.inputTranscript` branch alongside `lastContentAt`.

### 2. The `1.0` is duplicated too, and it belongs in `FinalizePolicy`

The PR says "the retry's surrounding conditions are still written twice" and defers it. Fair for the timer plumbing — but the *constant* is the cheap half:

```swift
/// How long after the last INPUT a deferred retry may still fire. New speech
/// means the normal timers own the turn again — don't force-finalize
/// mid-sentence.
static let speechResumedGuard: TimeInterval = 1.0
```

Two lines, both call sites use it, and combined with finding 1 it would have made the divergence a matter of passing the right clock rather than re-deriving the rule. Leaving `2.0` and `3` shared but `1.0` duplicated is the least defensible split of the three numbers.

### 3. The reject-reason coupling is stringly-typed, and the tests mirror it

`FinalizePolicy.isRecoverable` matches substrings of `TurnLogic.lastRejectReason` — a human-readable diagnostic string. Nothing binds the two. If someone rewords `"codes-veto: settled \(guess.rawValue), …"` to `"code veto: …"`, then:

- every L1.33 test stays green — they type the strings in as literals
- `isRecoverable` returns false forever
- the deferral silently never fires
- the app regresses to **exactly the pre-#21 harness behaviour**, in the app itself

L1.33b is a mirror copy of `TurnLogic`'s reason strings living in a test file, which `CLAUDE.md` names directly:

> Never re-implement app logic inside a test file — a mirror copy passes forever while the app regresses.

The reason strings *are* app logic here; they are this type's input contract. The fix is the same one this PR applies everywhere else: drive a real `TurnLogic` into each rejection state and feed its actual `lastRejectReason` into the policy, so the test breaks when the producer moves. Better still, give `TurnLogic` a `RejectReason` enum and carry the interpolated detail separately — then drift is the compile error this PR set out to make it, rather than a green suite.

### 4. `committed:` is computed differently at the two call sites

- service: `committed: turn.hasCommitted` — sticky, true if this turn *ever* committed
- harness: `committed: committed != nil` — true only if *this* call produced a bubble

They coincide today (a re-finalize after a commit yields `already committed (R1)`, which is terminal, so both reach `.giveUp`/`.committed` and reset). But it's two definitions of the same word at the boundary of the type built to have one. Have `decide` take the `Bubble?` and derive it internally.

### 5. The deferral converts lost turns into wrong-side turns — that's a worse failure for Heiko

The table shows turn-lost 47% → 0% and wrong-side 11% → 50%. In absolute terms wrong-side went **up**, roughly 2/19 → 5/10.

The PR reads "0% turn lost" as unambiguous progress. For this user it isn't. A lost turn is silence — Heiko notices nothing happened and says it again. A wrong-side turn is the app confidently speaking the wrong translation, aligned to the wrong speaker, with no error surfaced — and he cannot read the transcript to catch it. **This change makes the de↔es failure mode quieter to the instrument and louder to the user.**

That strengthens the PR's own conclusion, past where it stops. The data doesn't just say "#18 is justified" — it says **#18 is a release blocker for the es pair**. Either it lands before this does, or `es` comes out of the picker until it does. Shipping this alone converts a known-flaky pair into a confidently-wrong one.

### 6. Measurement caveats worth putting in the PR body

- **n=10.** 5/10 wrong-side carries a 95% CI of roughly 19–81%. "A coin-flip that Heiko would hit every other sentence" is stated with more confidence than 10 runs support.
- **Cross-instrument comparison.** The PR correctly argues the old baseline was "substantially the instrument" — which means 32% → 50% correct compares two different measuring devices and shouldn't be read as an improvement. The internally valid claim is the *composition* of the after-column: 0 of 10 lost, 0 of 10 split, and that one holds up well.
- **L3 is documented flaky** (TESTING.md §L3: one rerun expected per three). Neither column says whether reruns were folded in.

The defensible headline is "turn boundaries are now stable and wrong-side attribution is the only remaining failure mode," which is both true and enough to justify #18.

### 7. Minor — L3 wall-clock

Each turn can now absorb 3 × 2.0s of deferral, and the `deferUntil` branch returns before the `streamEndedAt` check, so end-of-stream is deferred with it. A two-turn case can add ~12s against the `audioSeconds + 45` budget in `main.swift:150`. Bounded and safe (a `.giveUp` always clears `deferUntil`), but it eats a quarter of the slack, and "replay timed out" is now a nearer failure.

### 8. Merge conflicts

`TESTING.md` conflicts with **both** #29 and #30 (verified) — all three append after L1.29e and extend the same "Beyond the numbered rows" block. Whichever two land second each need a rebase.

---

**Verdict:** finding 1 should be fixed before merge — it is a live divergence in the guard this PR added to fix a divergence, and the release gate cannot certify a behaviour it doesn't reproduce. Finding 3 is the one worth spending real time on: the type was extracted to make drift a compile error, and the coupling that matters most is still a substring match with a mirrored test.
