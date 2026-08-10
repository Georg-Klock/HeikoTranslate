# pull #35 — TurnLogic edge cases: four defects, one documented non-defect

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-05T17:59:31Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/35

---

Fixes #26.

Five L1 tests, written **before** any fix as the issue asked, so they document intended semantics whether or not the code turns out right. Four of them failed. The fifth passed, and that is the interesting one.

L1 **54/54**.

## The four defects

### L1.34 — a tied vote settled by enum declaration order

```swift
for lang in Lang.allCases {
    if count > 0, count > (best?.count ?? 0) { best = (lang, count) }
}
```

Strict `>` while iterating `de, en, es, fr, ko, zh` means a 2-2 tie goes to whichever language comes first in the enum. That settle is not cosmetic — it arms the commit veto, so an arbitrary winner can swallow a turn outright.

A tie means "the codes do not agree yet", which is precisely what `spokenLang == nil` already represents. It now doesn't settle; the next vote breaks it. (The issue suggested preferring the incumbent — there is never one here: both callers reach `pluralityVote` only while `spokenLang` is nil, so "no winner" is the whole rule. Noted at the call site so nobody adds the dead branch back.)

### L1.35 — an echo-only turn never ended a turn

`endTurn`'s guard checks `spokenLang`, `direction`, `hasCommitted`, `votes` — but not `firstPartnerOutputAt`, which it nevertheless clears. A turn where only the partner session spoke (it echoes foreign speech; no codes, no commit) counted as empty, so `lastTurnEnd` was never stamped, the next turn's straggler grace was never armed, and that echo's late codes arrived as fresh votes for the following turn.

### L1.36 — a rejected commit left a side behind

`direction` was assigned before the empty-original / empty-translation guards, so a `commit` that returned nil still reported a direction — and `translator` follows `direction`, which is what the service uses to decide whose held audio to play.

Worth flagging for review: the assignment is **load-bearing**. `bestTranscript` prefers the translator's transcript, and `translator` derives from `direction`, so simply moving the assignment after the guards would silently change which transcript gets picked. It is therefore still set first and *put back* on rejection.

### L1.37 — output after the commit could move the bubble

`noteOutputs` had no `hasCommitted` guard. A late, substantial home-session transcript for an already-committed homeSpoken turn flipped `direction` to `foreignSpoken`, moving `translator` from partner to home — while the service was flushing held audio for the session that actually translated. R1 says a turn commits once; its side is decided with it.

## The non-defect, and why the test stays

### L1.38 — `staleCodeGrace` (2.5s) > `settleWindow` (1.5s)

This looks like a hole: a tally can settle entirely inside the grace window that follows a turn. It passed, because the grace only ever filtered the **previous turn's language** — a code for a *different* language is a fast reply and should count immediately, which is what the constant's own comment says.

The test pins that, so the asymmetry is not "fixed" later by someone reading the two constants side by side. It also keeps the two layers distinct: the service's `speechHeardThisTurn` mic-energy gate is a second, independent line of defence and should not be mistaken for this one.

## Note for whoever merges

`TESTING.md` will conflict with #30 and #31 — all three append after L1.29e. Test IDs were chosen to avoid collision (#30 uses 31/31b/32, #31 uses 33-33e, this uses 34-38), so the conflict is textual only.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

---

### Georg-Klock — 2026-08-05T20:25:31Z

## Post-merge finding — L1.35 does not fix the defect it describes

This merged before the final gate reviewed it. Reviewing it after the fact: three of the four fixes are correct, one is inert. Nothing here is harmful and I would **not** revert — but the L1.35 item of #26 is not actually done and should be reopened.

### The three that hold up

`pluralityVote`'s tie handling is correct. Traced across leader-changes, three-way ties, and ties among non-leaders: it returns `nil` exactly when the top count is shared, and a later higher count correctly clears the flag rather than leaving a stale `tied`.

The rejected-commit fix is sound, and the reasoning in its comment checks out at the source: `hasCommitted = true` is set **only** on the success paths, and both recoverable rejections (`codes-veto`, `no session produced any translation`) return before any `direction` assignment. So clearing `direction` outright is safe as claimed, and the new `guard !hasCommitted` in `noteOutputs` cannot freeze a rejected turn with a nil direction — a re-derive is still reachable. L1.36b closes the gap the first version had.

L1.37 and the L1.38 non-defect are both fine.

### L1.35 is inert

`endTurn` now stamps `lastTurnEnd` for an echo-only turn. But the same branch sets:

```swift
previousSpokenLang = spokenLang ?? pluralityVote()
```

which for such a turn is `nil ?? nil` = `nil`. The straggler filter is the **only** consumer of either field:

```swift
// TurnLogic.swift:233
if let ended = lastTurnEnd, now.timeIntervalSince(ended) < Self.staleCodeGrace,
   spoken == previousSpokenLang { return nil }
```

`spoken` is a non-optional `Lang`, so it can never equal `nil`. The grace that was "armed" filters nothing.

This is provable rather than probable. The only turns the new `firstPartnerOutputAt != nil` clause newly admits are turns with no `spokenLang`, no `direction`, no commit and **no votes** — every other case was already caught by the old guard. `pluralityVote()` over empty votes is always `nil`. So in 100% of newly-admitted cases `previousSpokenLang` is `nil` and the filter is provably inert. The stated defect — "that echo's late codes arrived as fresh votes for the following turn" — is unchanged.

The test passes because it asserts the intermediate state (`lastTurnEnd == t(1)`) rather than the behaviour. Rewriting it to assert that a straggling code is actually rejected would have caught this — and it is the same failure mode this same batch is blocking #36 for: asserting the mechanism instead of the outcome.

### Suggested follow-up

Reopen the L1.35 item of #26. Whatever fix lands needs to decide what `previousSpokenLang` should be for a turn that produced output but no codes — there is no language to filter against, so "arm the grace" may not be a coherent goal for this case, and the honest answer might be that the original guard was right and the issue should be closed as a non-defect with a test pinning why.

Method note: reviewed by reading the diff and the merged source, not by running `xcodebuild test`. The finding above does not depend on the suite.

🤖 Post-merge review by Claude Opus 5

---

### Georg-Klock — 2026-08-05T20:31:39Z

## Technical Verdict
**Block** — post-merge review confirms the L1.35 change does not establish the behavior it claims to fix.

### Spec correctness
`endTurn` now stamps `lastTurnEnd` for an echo-only turn, but also assigns `previousSpokenLang = spokenLang ?? pluralityVote()`. For the documented echo-only case there are no language codes, so this remains `nil`. The straggler guard filters only when an incoming non-optional language equals `previousSpokenLang`; it therefore cannot reject the delayed language code that the change is supposed to suppress. The original late-code defect remains.

### Blast radius
Changed files: `HeikoTranslate/Models/TurnLogic.swift`, `TESTING.md`, and `Tests/TurnLogicTests.swift`. The affected behavior is shared turn classification and can misattribute a later turn.

### Security and safety
No secret, credential, destructive-write, or swallowed-error finding. The unresolved safety risk is incorrect cross-turn state: late codes can still be treated as fresh evidence for the next utterance.

### Test coverage
L1.35 asserts only that `lastTurnEnd` was set. It never sends a delayed code after the echo-only turn and verifies that it is rejected. The test passes while the claimed protection is absent.

**Recommendation: not ready to merge. Track and fix this post-merge defect before relying on the straggler guarantee.**

## Handoff Notes for Opus
- Reproduce echo-only output → `endTurn` → delayed partner-language code inside `staleCodeGrace`.
- Define what language identity can safely be retained for an echo-only turn; a nil value cannot drive the current filter.
- Add a behavioral regression test before selecting the fix.
