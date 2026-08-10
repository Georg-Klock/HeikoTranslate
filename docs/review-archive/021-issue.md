# issue #21 — The L3 release gate mirrors the service's orchestration instead of exercising it — and has already drifted (no finalize-deferral path)

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-04T20:01:13Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/21

---

## Summary
CLAUDE.md's first rule: *"Tests must exercise the real app types… Never re-implement app logic inside a test file — a mirror copy passes forever while the app regresses."* The L3 harness — the **release gate** `release.sh` runs before every upload — violates it at the layer that matters most.

`Tools/l3replay.sh` compiles the real `GeminiLiveSession` and the real `TurnLogic` (good), but `Tools/l3replay/main.swift` says it plainly: line 81 *"Mirrors GeminiLiveTranslationService's per-utterance state"*, line 183 *"Mirrors GeminiLiveTranslationService.handle"*, line 256 *"Mirrors finalizeTurn + resetForNextUtterance"*. The orchestration — timers, finalize policy, code-veto sequencing, direction rechecks — is a hand-maintained copy.

## It has already drifted
The service gained the **finalize-deferral** path (`finalizeDeferrals` / `maxFinalizeDeferrals`, SPEC §5.1 "keep showing live text and wait" — the fix for the swallowed-bubble-on-starved-uplink failure). The harness has no deferral logic at all (zero grep hits). So the gate finalizes turns on a schedule the shipping app no longer uses — in exactly the timing-sensitive territory where L3 "flakes" live (`en_long` split bubbles, swallowed second turns). Some of those flakes may be harness artifacts; worse, the harness can pass where the app would fail.

## Suggested fix
Extract the per-utterance orchestration policy (state + timer decisions, no AVFoundation, no @MainActor) into a platform-free component that **both** the service and the harness compile — the same move that created TurnLogic in the first place, one layer up. The harness then supplies clocks/transport; the policy is shared by construction and drift becomes a compile error.

## Severity
**High** — not a user-facing bug, but it weakens the trustworthiness of every L3 green light, and the project's process leans hard on that gate.

*From the 2026-08-04 architecture audit, hand-verified against the harness source.*

---

### Georg-Klock — 2026-08-05T16:35:17Z

## #31 closes the drift it names, but not this issue — and it demonstrates why the issue needs a mechanism rather than a rule

Notes from reviewing #31, which is labelled `Fixes #21`.

### 1. `Fixes #21` overstates it, by the PR's own account

This issue's stated fix is *"extract the per-utterance orchestration policy (state + timer decisions…) into a platform-free component that both compile."* #31 extracts **one decision** — whether a finalize waits — and says so plainly:

> The *decision* is now shared, but the retry's surrounding conditions are still written twice. **The extraction is incomplete.**

That's the right call for scope, and the deliberately-not-extracted timing constants are well argued. But the three mirror comments this issue cites (`main.swift` lines 81 / 183 / 256 — "Mirrors GeminiLiveTranslationService's per-utterance state" / "Mirrors …handle" / "Mirrors finalizeTurn + resetForNextUtterance") are still there. Suggest #31 land as `Refs #21`, and this issue stay open with its scope narrowed to what remains.

### 2. Partial extraction re-created the problem one layer down — live, in this branch

The strongest argument for finishing the work is that #31 stopping halfway produced a fresh instance of the same defect. Its new retry guard:

```swift
// Tools/l3replay/main.swift:252
if now.timeIntervalSince(lastContentAt) >= 1.0 { finalizeTurn() }

// GeminiLiveTranslationService.swift:1026
if Date().timeIntervalSince(self.lastInputAt) < 1.0 { return }
```

Presented as "the same guard," but they read different clocks. `lastInputAt` is set only by `noteInputActivity()`, called only from `.inputTranscript` — **input speech only**. The harness's `lastContentAt` is also bumped by `.outputTranscript` and by translator `.audioChunk`s, i.e. by *the translation the deferral is waiting for*. So on the success path this feature exists to serve — translation arrives at ~T+1.8 of a 2.0s wait — the app retries and commits, while the harness sees 0.2s of "content", skips the retry, and finalizes ~1.1s later via the ordinary timers.

Both eventually commit, so **L3 goes green while the timing diverges**. That is this issue's thesis, reproduced inside the PR that fixes this issue. It is the best available evidence that the boundary can't be drawn mid-policy.

### 3. The anti-mirror rule got violated in the test suite for the anti-mirror type

`FinalizePolicy.isRecoverable` substring-matches `TurnLogic.lastRejectReason` — a human-readable diagnostic string — and `FinalizePolicyTests` types those strings in as literals:

```swift
"codes-veto: settled en, home session never translated"
"no session produced any translation"
```

Nothing binds the policy's input contract to what `TurnLogic` actually emits. Reword the producer and: every L1.33 test stays green, `isRecoverable` returns false forever, the deferral silently never fires, and **the app regresses to precisely the pre-#21 harness behaviour** — this time in the shipping app rather than the gate. A mirror copy passing forever while the app regresses, in the fix for the issue about mirror copies passing forever.

### 4. What "give the rule teeth" would concretely mean

The lesson I'd draw is that CLAUDE.md's rule is currently a maxim, and maxims lose to convenience at 2am. Mechanisms that would have caught each of the above:

1. **Type the reject reasons.** `TurnLogic.RejectReason` as an enum, with interpolated detail carried alongside rather than inside the match key. Drift becomes a compile error, which is what this issue asked for.
2. **Bind policy tests to the producer.** L1.33b should drive a real `TurnLogic` into each rejection state and feed its actual `lastRejectReason` in, not literals. Cheap, and it is the repo's own stated test rule.
3. **Every threshold the harness shares with the app comes from one symbol.** #31 shares `2.0` and `3` but re-types `1.0`. If a constant appears in both `main.swift` and the service, it belongs in the shared policy — and the clock it is measured against belongs there too, which is what §2 above is really about.
4. **Audit the remaining mirror surface by grep, not by memory.** The three `// Mirrors …` comments are honest markers; they should be treated as a checklist with an owner, and it should be a CI-visible failure to add a fourth.

### 5. Severity still looks right

`High` remains correct, and arguably firmer now: #31 proved the gate had been misreporting roughly half of the de↔es failures (47% turn-lost → 0% once the harness ran the app's actual rule). Every L3 green light predating #31 carries that error bar, which is worth stating in TESTING.md as a dated boundary — results before 2026-08-04 are not comparable to results after it.

---

Not arguing #31 shouldn't merge — it should, after the clock mismatch in §2 is fixed. Arguing it should merge as `Refs #21`, with this issue left open for the orchestration surface it explicitly did not touch.
