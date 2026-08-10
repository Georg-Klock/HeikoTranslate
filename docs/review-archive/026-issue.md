# issue #26 — TurnLogic edge cases: five verified or suspected gaps, each needing an L1 test to pin intended semantics

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-04T20:02:53Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/26

---

## Summary
Bundle of small state-machine findings from the 2026-08-04 audit. Two are verified defects; three are plausible and cheap to pin with a test either way. None is urgent alone; together they are exactly the drift TESTING.md exists to prevent.

**Verified:**
1. **`pluralityVote` breaks ties by `Lang.allCases` order** (strict `>` while iterating `allCases`): a 2–2 vote settles on whichever language enumerates first — an arbitrary settle that then arms the commit veto. Rare (votes accrue ~1/s), but the tie-break should be deliberate: prefer the incumbent `spokenLang`, else no winner until the tie breaks.
2. **`endTurn`'s "contained anything" guard omits `firstPartnerOutputAt`** even though the reset list clears it: a turn with only partner-session output (echo, no codes, no commit) never stamps `lastTurnEnd`, so the next turn's straggler grace is never armed and stragglers from the echo are admitted as fresh votes.

**Suspected — pin with a test, fix if it fails:**
3. `commit` appears to mutate `direction` even when it rejects the bubble, which can block `noteOutputs`' later homeSpoken resolution for the same turn.
4. `noteOutputs` can flip `translator` after `hasCommitted` — direction changing between commit and endTurn, exactly when held translation audio is being played.
5. `staleCodeGrace` (2.5s) exceeds `settleWindow` (1.5s), so a lie-only tally can settle entirely inside the grace period. Partially mitigated by the service's `speechHeardThisTurn` mic-energy gate — the L1 test should encode whichever behaviour is intended *at the TurnLogic layer*, since CLAUDE.md says decisions live there.

## Suggested approach
One PR: five L1 tests first (they document intent even where the code turns out right), then fix whichever fail. TurnLogic is pure, so each test is a few lines.

## Severity
**Low** individually; the value is closing the gap between the state machine and its safety net.

---

### Georg-Klock — 2026-08-05T20:32:42Z

## Reopened for **item 2 only** — the fix that landed is inert

#35 closed this as completed. Post-merge review found that item 2 does not fix the defect it describes. Items 1, 3, 4 and 5 are genuinely done and are **not** in scope here:

- [x] 1 — `pluralityVote` tie-break. Correct: returns `nil` exactly when the top count is shared, and a later higher count clears the flag. (Note it did *not* take this issue's suggestion to prefer the incumbent — there is never one, since both callers reach it only while `spokenLang` is nil. The PR documents that at the call site.)
- [ ] **2 — `endTurn` / `firstPartnerOutputAt`. See below.**
- [x] 3 — rejected `commit` leaving a `direction`. Fixed properly on the second pass: cleared, not restored. L1.36b covers the streaming path.
- [x] 4 — `noteOutputs` flipping `translator` after `hasCommitted`. Fixed, L1.37.
- [x] 5 — `staleCodeGrace` > `settleWindow`. Verified intended, pinned by L1.38.

### Why item 2's fix does nothing

`endTurn` now stamps `lastTurnEnd` for an echo-only turn. But the same branch also sets:

```swift
previousSpokenLang = spokenLang ?? pluralityVote()
```

which for such a turn is `nil ?? nil` = `nil`. The straggler filter is the only consumer of either field:

```swift
// TurnLogic.swift:233
if let ended = lastTurnEnd, now.timeIntervalSince(ended) < Self.staleCodeGrace,
   spoken == previousSpokenLang { return nil }
```

`spoken` is a non-optional `Lang`, so it can never equal `nil`. The grace that was "armed" filters nothing.

This is provable, not probable. The only turns the new `firstPartnerOutputAt != nil` clause newly admits are turns with no `spokenLang`, no `direction`, no commit and **no votes** — every other case was already caught by the old guard. `pluralityVote()` over empty votes is always `nil`. So in 100% of newly-admitted cases `previousSpokenLang` is `nil` and the filter is provably inert. The behaviour this issue describes — "stragglers from the echo are admitted as fresh votes" — is unchanged.

L1.35 passes because it asserts the intermediate state (`lastTurnEnd == t(1)`) rather than the outcome. A test asserting that a straggling code is actually *rejected* would have caught it.

### What a real fix has to answer first

**Do not just re-do this one.** The obvious repair — also set `previousSpokenLang` for an echo-only turn — has nothing to set it *to*. By definition this turn produced no codes, so there is no language to filter the next turn's stragglers against. The premise may be wrong.

Two candidate outcomes, and the work is deciding which:

1. **The straggler filter is the wrong layer for this.** What actually needs suppressing is late codes from an echo, and the filter keys on language identity, which an echo-only turn cannot supply. If so, the mechanism needs to key on something else (time since the echo, or the partner session's own output window) — a real design change, not a one-line guard.
2. **The original guard was right and this is a non-defect.** If a turn genuinely produced no codes, there is nothing to carry forward, and letting the next turn vote freely is correct behaviour rather than a leak. If so: close as a non-defect and keep a test pinning *why*, the way L1.38 does for item 5.

Either way the existing L1.35 should be rewritten to assert the behaviour rather than the timestamp, so the next attempt cannot pass without working.

### Severity

Unchanged — low, and nothing is broken by the merged change. It stamps a timestamp that gates nothing. No revert needed.
