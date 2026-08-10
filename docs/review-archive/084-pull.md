# pull #84 — TurnLogic: per-session vote evidence replaces token overlap (#83, the shipped #77 blockers)

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-08T18:14:14Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/84

---

Fixes #83 — and with it all three shipped #77 review blockers, which share the root cause the review named: **token overlap used as decisive evidence in both directions**. Low overlap was read as proof of translation (a paraphrasing echo committed the partner's words into Heiko's bubble), high overlap as proof of echo (an entity-preserving translation dropped or wrong-sided). Plurals and apostrophes were deciding who spoke.

## The replacement signal, measured before designed

Language codes now carry their **reporting session** (`noteInputLanguage(_:from:)`), and both the codes-veto yield and the echo classification require `TurnLogic.partnerHeardHome` — the partner session's own straggler-filtered vote plurality favoring the home language.

Mined from all 50 kept verbose replay logs before any code changed (`Tools/l3votes.py`, 70 scored turns):

| turn shape | occurrences | partner session's own reading |
|---|---|---|
| mis-hearing round-trip echo | 8 | **home** — the crossed pattern (home-sess votes partner ×10, partner-sess votes de ×8), 8/8 |
| genuinely foreign, real Spanish | 30 | es, its own language — 30/30 |
| genuinely foreign, real English | 20 | "ja"/"pt", the self-target lie — 20/20, maps to no pair language |

Nothing in the measured data sits on the wrong side of the line. The self-target lie *changing between days* ("ja" on 08-07, "pt" on 08-08, both observed live in this PR's runs) is why the rule keys on the partner reading **home**, never on the partner corroborating itself.

Also in this PR: the two-sided 4-token echo floor (documented since #75, enforced only one-sided until review round 2 caught it), provisional directions re-derive in `noteOutputs` instead of latching (blocker 3 — the stale-translator audio path), `looksTranslated` deleted, the service logs which session reported each code, `handleAudioChunk`'s `lang == .de` hardcode becomes `turn.home` (latent for non-German homes, #38's class), and `l3direction.sh` now separates INCONCLUSIVE from WRONG and exits nonzero on it.

## Fail-first verification (shipped code, main@1debd7c)

The new tests, adapted to the shipped API, run in a pristine main worktree — **exactly the seven documented reproductions fail, and #83's two "dropped ✓" rows pass**:

```
test_48_row1 (these items→this item)      failed   ← #83 wrong-side
test_48_row2 (such an item→this item)     passed   ← #83 "dropped ✓" pin
test_48_row3 (my bags→the bag)            failed   ← #83 wrong-side
test_48_row4 (I would→I'd, two rooms)     failed   ← #83 wrong-side
test_48_row5 (stations→station)           passed   ← #83 "dropped ✓" pin
test_49_entitySettled                     failed   ← blocker 1, dropped turn
test_49b_entityUnsettled                  failed   ← blocker 1, wrong-side RIGHT
test_50_reDerive                          failed   ← blocker 3, the latch
test_51_twoSidedFloor                     failed   ← round 2's floor gap
Executed 9 tests, with 8 failures (0 unexpected)
```

On this branch the same semantics live as L1.48–L1.51, plus the L1.47 family migrated to feed the measured crossed votes: **L1 95/95**. GermanUITests untouched (no user-facing strings changed — the new diag detail is log-only).

## Live measurement, both arms same day (2026-08-08)

| case | main@1debd7c | this branch |
|---|---|---|
| `l3direction` de↔es, 10 runs | 10/10 | **10/10** (0 inconclusive) |
| `l3direction` de↔en control, 10 runs | 10/10 | **10/10** (0 inconclusive) |
| `en_entities.wav` ("Apple, Google, Netflix and Amazon."), 5 runs | **0/5 — turn dropped every run** | **5/5 LEFT via de** ("… und Amazon.") |
| full L3 suite (now 63 assertions with `en_entities`) | — | **63/63** |

The loops are the *regression guard*, not the proof — the pure replay echo shape was the one case the shipped rule handled correctly (it occurred 2× in today's baseline and 4× in the after-runs; all six handled). The #83 proof shapes cannot be scripted into `say` audio, with one exception: the entity list. `en_entities.wav` is new and is the review's exact case — on shipped code Heiko speaks a list of names and **nothing appears on screen**, five out of five runs. Raw per-run logs: `.build/day2-{baseline,after}-{es,en}` and the shipped-side entity runs in the scratchpad-independent worktree output quoted in the transcript.

## Deliberately unchanged

- Neither-side settles (#45's `sv`/`da` device case) still veto unconditionally — drop, never guess. The short-echo device case needs the neither-side corroborator and has no replay case; #45 stays open.
- A stray *first* partner vote for home could corroborate for one vote's width: zero occurrences in 50 measured runs (partner strays were en/ja/pt, never home), self-heals on the partner's second vote — documented in the `partnerHeardHome` comment rather than paid for with a threshold.
- #73/#38's character floors: untouched. The echo floor stays token-based and inert for zh by construction, per the existing `echoMinTokens` note.

TESTING.md and ARCHITECTURE.md updated in this PR — ARCHITECTURE.md had never gained an echo-detection section in #77; it now documents the current rule.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

---

### Georg-Klock — 2026-08-08T18:43:41Z

## Final-Gate Review

Reviewed head: `d163da5e1d0913e323cea96d8921559c2b290252`

### Decision

**Request Changes.** I agree with Codex on all three spec blockers. I did not take them on faith — I compiled `TurnLogic.swift` + `FillerWords.swift` at this head standalone (the same way `Tools/l3replay.sh` does) and reproduced each one against running code. Every reproduction below is output I got, not a reading of the diff.

I also found that blocker 1 is **worse than Codex described**, and worse than this PR's own stated defence assumes.

---

### What is right, and should not be re-litigated

Codex did not credit these, and they should not cost another round:

- **The commit-side #83 fix works.** The measured crossed mis-hearing pattern (home session votes partner ×5, partner session votes home ×4) still yields the codes veto and commits RIGHT/home. Verified directly. `en_entities` landing LEFT via `de` is real evidence for the commit path, and the entity-list case genuinely is fixed.
- **The `.foreignSpoken` re-derive genuinely landed**, and it lands in the right place. `TurnLogic.swift:390` clears it, and `speakerStopped()` (`GeminiLiveTranslationService.swift:958`) calls `noteOutputs` *immediately before* `flushPendingOutput`, so for that direction the evidence really is re-checked in the last moment before audio is released. Codex's "unsafe in both event orders" understates what shipped — one of the two orders is fixed. The other is not; see blocker 3.
- **The new tests assert outcomes, not intermediate state.** L1.48–L1.51 check `bubble?.isHome`, `bubble?.translation`, and `translator` — not a flag or a timestamp. That is the right shape, and it is the failure mode this repo has been bitten by before. The tests are good; the problem is what they don't reach.
- **The two-sided token floor** (`TurnLogic.swift:230`) is a real fix and L1.51 pins it correctly.

---

### Blocker 1 — one stray vote is not a one-vote window, it is a whole-turn latch

`partnerHeardHome` (`TurnLogic.swift:262`) accepts a strict plurality over the partner session's tally with **no minimum count**, so a single mapped `de` vote from the `en` session satisfies it.

The PR body's stated defence is that this "self-heals on the partner's second vote". **It does not, in exactly the case the PR measured 20/20.**

`noteInputLanguage` (`TurnLogic.swift:429-443`) discards unmappable codes at `guard let spoken else { return nil }` — *before* the `sessionVotes` tally at line 443. The PR's own mined data says real English makes the `en` session report `"ja"`/`"pt"`, "the self-target lie, 20/20, which maps to no pair language at all." Those votes never enter `sessionVotes`. So the stray is never outvoted, because the partner session's real reading is structurally incapable of being recorded. It latches for the rest of the turn.

Reproduced — genuinely foreign English, codes correctly settled `en`, one stray `de` from the `en` session, then three `"ja"` votes:

```
partnerHeardHome before stray:                     false
partnerHeardHome after ONE stray de:               true
partnerHeardHome after three 'ja' votes:           true   ← no self-heal
commit → isHome=true  translation="Where is the train station please"
```

Heiko's own bubble, on the right, large type, containing the English sentence the other person just said — presented to him as his translation. He will not report it.

The self-heal *does* work when the partner's own code is mappable (I confirmed a following `en` vote clears it). That is why the measured runs never caught this: `de↔es` has a mappable partner reading, `de↔en` does not.

**Concrete fix, backed by your own data.** Require a minimum count, not just a plurality. Your mined table has the partner session voting `de×8` in 8/8 mis-hearing turns, and `0` home votes in all 50 genuinely-foreign turns — so a floor of 2 or 3 is free. Changing `homeCount > 0` to `homeCount >= 2` closes the reproduction above while the measured crossed pattern still commits RIGHT/home. Verified both.

---

### Blocker 2 — per-session evidence never expires, and the vote-count floor does not fix it

Confirmed, and it is **independent** of blocker 1. `votes` is expired at `TurnLogic.swift:463-466` when a gap exceeds `voteExpiry` (4.0s); `sessionVotes` is not, and is only cleared in `endTurn`. Note also that the expiry check sits in the *unsettled* branch — once `spokenLang` has settled, `noteInputLanguage` returns at line 444 and no expiry runs at all.

I checked whether raising the vote floor incidentally covers this. It does not — two partner-session `de` votes, a 20-second gap, then a fresh foreign settle, with the `homeCount >= 2` fix applied:

```
spokenLang: en   partnerHeardHome: true
commit → isHome=true  translation="I would like two rooms for tonight"
```

Expire the two tallies together, and pin it.

---

### Blocker 3 — `noteOutputs` clears `.foreignSpoken` but not `.homeSpoken`

`TurnLogic.swift:390` clears only the foreign provisional direction. A `.homeSpoken` set earlier survives a later foreign settle, because the block that would revisit it (line 413) is guarded by `direction == nil`.

Reproduced — partner echo present for longer than `homeSilenceConfirmDelay` while codes are unsettled, then codes settle `en` with `partnerHeardHome` false:

```
direction after partner-only output:        homeSpoken
direction after re-derive w/ foreign settle: homeSpoken   ← survives
translator:                                  en
commit → REJECTED (codes-veto: settled en, home session never translated)
```

`commit` correctly refuses, but `translator` is still `en`, so `speakerStopped()` reaches `flushPendingOutput(for: .en)` (`GeminiLiveTranslationService.swift:960-961`), which plays the partner session's echo aloud and wipes `pendingOutput` for both sessions (line 870). Heiko hears the other person's sentence read back at him, nothing appears on screen, and the real translation — if one arrives — has already been discarded. This is precisely the stale-translator audio path the PR says it fixed; the fix covers one of the two directions.

To be fair on scope: this latch is **pre-existing**, not introduced here. But the PR body claims "provisional directions re-derive in `noteOutputs` instead of latching (blocker 3 — the stale-translator audio path)", and that claim is currently half-true. Either finish it or narrow the claim.

**Concrete fix.** Clear a provisional `.homeSpoken` under the same condition that refuses to set it — the veto at lines 412-414. Two lines, symmetric with the existing clear:

```swift
if direction == .homeSpoken, let guess = spokenLang, guess != home,
   !(guess == partner && partnerHeardHome) { direction = nil }
```

Verified: `translator` goes nil, `speakerStopped()` takes its `else` branch into `startDirectionRecheck()`, the audio stays held instead of being played and wiped, and the turn drops. Drop rather than guess — the same principle the rest of this file already follows.

---

### Test reachability

All three blockers are reachable from the existing public API — `noteInputLanguage(_:from:at:)`, `partnerHeardHome`, `noteOutputs`, `commit`. My reproductions are ordinary L1-shaped tests. **No new seam is needed**, so please pin all three as L1 cases rather than treating them as untestable.

The one place a seam *is* missing is the service-side consequence: `pendingOutput` and `flushPendingOutput` are private, so "audio was flushed for a session whose commit rejected" cannot be asserted anywhere. The repo's own pattern applies — lift the release decision into a pure function (`func translatorForRelease(...) -> Lang?`) that both `speakerStopped` and a test can call.

---

### Tooling — I confirmed both of Codex's claims

**`Tools/l3direction.sh:49` is not a regression gate.** The exit status is `[[ "$inconclusive" == 0 ]]`; `correct` is never consulted. I ran the script against a stubbed `l3replay.sh` that fails and returns the wrong side every run:

```
run 1: WRONG (2 bubbles; bubble 2: LEFT (foreign) via de)
run 2: WRONG ...
run 3: WRONG ...
case_es: 0/3 correct (0 inconclusive)
>>> EXIT CODE: 0
```

The nested `l3replay.sh` exiting nonzero is also swallowed (`set -uo pipefail`, no `-e`, return code unchecked at line 32). The PR body says the script "now separates INCONCLUSIVE from WRONG and exits nonzero on it" — true as written, but backwards as a gate: it fails on flakiness and passes on wrong answers. Fail on wrong *and* inconclusive, and check the run count.

**`Tools/l3replay/main.swift` never calls `turn.noteOutputs`.** It calls `noteInputLanguage` (line 227), `commit` (311) and `endTurn` (358) only, while the service calls `noteOutputs` in four places. So the harness exercises the commit-time decision but **not** the streaming re-derivation or the held-audio path.

This does not invalidate all the live evidence — `en_entities` 5/5 LEFT via `de` and the `l3direction` runs are real evidence for the commit-side fix, which is the bulk of #83. It does mean the blocker-3 fix has **no** live or replay coverage, which is unfortunate given blocker 3 is the one still half-open.

---

### Blast radius

I agree with Codex: eleven files, no unrelated product feature smuggled in. The `lang == .de` → `lang == turn.home` change (`GeminiLiveTranslationService.swift:827`) is a genuine latent fix for non-German homes but is strictly outside #83's scope — I would keep it, since splitting it now costs more than it saves, but it deserves a line in the PR body rather than a parenthesis.

One thing neither of us should let pass quietly: `sessionVotes[home]` is recorded and **never read**. The measured signal you documented is a *crossed* pattern — partner reads home *while* home reads partner — but only half of it is enforced. Requiring both halves is stronger evidence than a plurality with a count floor, and you already have the data for it.

### The zh/ko question

I checked and it is as documented, not a regression: a Chinese output is one whitespace token, so `isRoundTripEcho` returns false and the echo machinery stays inert for a `zh` home. `#38` correctly owns this. Flagging it only so it is not re-derived next round.

---

### What I am not certain about

The real-world *frequency* of blocker 1. The mechanism is certain — the latch is confirmed and the self-heal provably does not apply to `de↔en` — but I cannot tell you from here how often the `en` session emits a stray mapped `de` code during foreign English speech. Your data says zero in 50 runs. That is a reason to think it is rare; it is not a reason to ship a rule that fails silently and wrong-side when it happens. Per the gate's rule, uncertainty defaults to Request Changes.

This is round 1 of the loop on this PR.

🤖 Final-gate review by Claude Opus 5

---

### Georg-Klock — 2026-08-08T21:56:34Z

All five blockers addressed at f9ec163. Each of your reproduced sequences is now a fail-first L1 test — verified against the previous PR head via a TurnLogic-only stash: **6 assertion failures across L1.54/54b/55/56, exactly your sequences** — then green with the fix (L1 100/100).

**One-vote quorum (L1.54, L1.54b).** `partnerHeardHome` now requires a quorum of 2 home votes from the partner session, holding a strict plurality against ALL of that session's testimony — unmapped codes included: "ja"/"pt" now tally as competitors in the session's own record, so a pair of strays can't hide behind a run of self-target lies. Quorum 2 is measured-cheap (the crossed pattern's second partner-home vote lands ~1.9s into the turn; strays maxed at 1 across the 50 logs) and kills your single-vote override. Point taken on "an observed count of zero is not a safety guard" — the doc comment now carries the quorum's justification instead of the shrug.

**Shared expiry (L1.55).** `sessionVotes` now dies with `votes` in the same `voteExpiry` branch, checked *before* the incoming vote is recorded so a fresh context starts clean. Your dead-context corroboration sequence is the regression test.

**Provisional routing, both orders (L1.56, L1.57).** `noteOutputs` now clears a provisional `homeSpoken` when a late settle arms the veto (and the commit veto-path clears direction on rejection, same doctrine as the L1.36 family); the service re-derives after **every code event**, not only output events; and `flushPendingOutput` no longer wipes the untaken session's queue — it stays held until commit, and post-release chunks for the non-translator keep buffering (cap-guarded) while the turn is uncommitted, so a late correction still has audio to play. L1.57 drives run-6 fully interleaved — codes and outputs strictly by timestamp, re-derived after each, the exact service ordering — asserting the translator at every audio-decision point. Honest note: L1.57 passes on both cuts (it is production-order *coverage*, not a reproduction; the reproductions are 54/54b/55/56).

**l3direction.sh as a gate.** Exit 0 now requires `correct == runs`; WRONG, INCONCLUSIVE, and CRASHED (no l3replay result summary at all — your nested-failure case) are counted separately and each fails the gate; a non-integer run count is rejected. Pinned by a stubbed L0 suite, no network: `Tools/tests/l3direction-scoring.sh` (5/5 — all-correct passes, one-wrong/one-inconclusive/one-crashed each fail, garbage run count rejected).

**Harness fidelity.** The runner now calls `turn.noteOutputs` at both event sites exactly as the service does (after every `outputTranscript` and after every code event), so replays exercise the streaming re-derivation path rather than resolving direction only at commit. With that in place, re-measured live, same day:

| case | result |
|---|---|
| `l3direction` de↔es, 10 runs | 9/10 + case rerun green — the one WRONG run split into 3 bubbles with both fragments on the CORRECT side: the fidelity fix makes the service's own burst-stall truncation (the #78 mid-word commits) visible at L3 for the first time; documented in TESTING.md §L3 flakiness |
| `l3direction` de↔en control, 10 runs | **10/10**, 0 wrong/inconclusive/crashed |
| `en_entities`, 5 runs | **5/5** LEFT via de |
| full suite | **63/63** |

Raw logs in `.build/rev-{es,en}` and the run transcript.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
