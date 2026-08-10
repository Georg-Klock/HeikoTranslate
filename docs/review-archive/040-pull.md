# pull #40 — Short answers really do survive an echo now (#23)

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-05T20:44:08Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/40

---

Fixes #23. **Replaces the #23 half of #37**, with that PR's blocking finding addressed. The #25 half is split out to #39. Based on current `main` (`408e886`), so the rebase #37 needed is not needed here.

L1 **67/67**. L3 **56/56**.

## The bug #23 was filed for survived its own fix

#30 kept the **uncorroborated** 8-char floor inside the echo branch:

```swift
if let spoken = spokenLang, spoken != home {
    return homeText.count >= minDecisiveHomeOutput   // 8
}
```

The measured failure was `"14 Euro"` — **7 characters**. So beside an echo, which #30 itself calls "the common case for foreign speech", the reported case stayed swallowed. `L1.31` passed only because its example is `"14 Euro bitte"` (13).

The echo branch now uses `minCorroboratedHomeOutput` (5), bracketed by the two measured points: the false start `"Ich"` (3, L1.22) and the real translation `"14 Euro"` (7, measured 2026-07-29).

## What changed since #37: the two branches stay asymmetric

#37 also applied the new floor to the **no-echo** branch, which had been a bare `return true`, for symmetry. Its review blocked that, and the objection is correct: it newly rejected 1–4 character corroborated outputs — in German `"Ja"` (2) and `"Nein"` (4) — producing a silently swallowed turn, *the exact shape of #23 itself*, traded for a no-echo false-start case with **zero observed instances**.

So the floor is confined to the echo branch, and the asymmetry is now documented as deliberate rather than left looking like an oversight:

| | no echo | partner echoed |
|---|---|---|
| codes settled foreign | any non-empty output — **unchanged** | `>= 5` |
| codes silent / settled home | `>= 8` | ratio, else reject |

The reasoning, in one line: a floor buys false-start rejection only where there is an echo to weigh against, and costs real short answers where there is not.

## Tests

- **L1.41** — the reported case verbatim: `"14 Euro"` against a 26-char echo, codes settled foreign, ratio 0.27.
- **L1.41b** — that the floor applies *only* beside an echo. Covers the short answers that must survive alone (`"Ja"`, `"Nein"`, `"Vier"`), the false start that must still die beside an echo, and the boundary itself (5 clears, 4 does not) so the constant cannot drift unnoticed. It is written to fail if someone "tidies" the two branches into one rule.

Both were verified by breaking the code, per this repo's habit rather than trusting green:

| Reintroduce | Result |
|---|---|
| the 8-char floor in the echo branch | **L1.41 fails** (and L1.41b's boundary assertion) |
| the 5-char floor on the no-echo branch — #37's rejected design | **L1.41b fails** on `"Ja"`, `"Nein"`, `"Vier"` |

L1.22 / L1.22b / L1.26 / L1.26b / L1.31 / L1.31b all stay green, so the false-start guard was not traded away.

**L3 56/56**, full green — including `de_after_es`, the pair TESTING.md documents as failing ~2/3 of runs. One clean run of a known-flaky case is not proof it is fixed; recorded here only because this diff changes turn acceptance and L3 is where that shows up.

## Not fixed here: the floors are German-calibrated

Both constants are **character counts** measured against German, and `home` is user-selectable across all six languages (L1.29e) — Chinese and Korean say the same thing in far fewer characters, so the same floor is materially stricter there. Latent rather than urgent, since Heiko's home language is German.

Filed as #38 and named in the doc comments, so it is a tracked assumption rather than a silent one. The no-echo branch is language-independent by construction, having no floor at all.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

---

### Georg-Klock — 2026-08-05T21:13:39Z

## Final-Gate Review

Reviewed head: `2e8b957cb6f0d3d144bd915a4eac17e6102a93a4`

**Decision: Merge (recommend).** This is a recommendation only — I do not merge, and I have not enabled auto-merge. Georg merges, or the label-gated watchdog does.

I disagree with Codex's sole blocker. Details below; this is round 1 of that disagreement.

---

### What I verified independently

**The executable change is one comparison.** Diffing against `main` with comments stripped, the entire behavioural delta is `TurnLogic.swift:217`, `>= minDecisiveHomeOutput` → `>= minCorroboratedHomeOutput`, plus the new constant at line 97. Everything else in the diff is doc comments, tests, and `TESTING.md`.

**The bug diagnosis is correct, and I confirmed it rather than taking the PR's word.** Neither existing test covered the reported case:
- `L1.26` (`TurnLogicTests.swift:318`) calls `noteOutputs([.de: "14 Euro"])` with no partner key at all — that is the *no-echo* branch, which accepts unconditionally. It never touched the echo path.
- `L1.31` (`TurnLogicTests.swift:346`) uses `"14 Euro bitte"` — 13 chars, which clears the old 8-char floor on its own.

So the measured 7-char `"14 Euro"` beside an echo was in a gap between the two, and #23's fix did leave its own reported case swallowed. The PR's account of this is accurate.

**Tests assert the outcome, not an intermediate.** `L1.41` asserts the committed bubble (`isHome == false`, `translation == "14 Euro"`), not merely `direction` — that is the user-visible result. `L1.41b` pins the boundary from both sides (5 clears, 4 does not), so the constant cannot drift silently. Reachability is not a problem here: `homeIsRealTranslation` is an internal `static`, and `direction` is `private(set)` but readable, so no new seam is needed.

**I ran the suite and both mutations myself.**

| Check | Result |
|---|---|
| Full unit target at this head | **67/67 green** — matches the PR's claim |
| Restore the 8-char floor in the echo branch | `L1.41` **fails**, `L1.41b` boundary **fails** |
| Apply the 5-char floor to the no-echo branch (#37's rejected design) | `L1.41b` **fails** on `"Ja"`, `"Nein"`, `"Vier"` |

The tests genuinely catch the defect in both directions.

**Blast radius and safety.** Three files, all within the stated scope; no unrelated fixes bundled. No secrets, destructive operations, or swallowed errors. I grepped the app for any other length gate that could swallow a short translation downstream — there is none (the only other `.count` bounds are audio-chunk buffers in `GeminiLiveTranslationService`). This is the single gate, so the fix does reach the bubble.

---

### Where I disagree with Codex

> "the new five-character floor remains a correctness risk for supported non-German home languages… A valid concise CJK translation beside an echo can still be silently rejected."

Both sentences are individually true, but **"new" is doing false work**, and the conclusion does not follow.

The echo branch already had a floor on `main` — a *stricter* one, 8. This PR lowers it to 5. The function is therefore **monotonically more permissive**: every input `main` accepted, this accepts. Nothing that used to reach Heiko can now be swallowed, in any language. The CJK exposure Codex describes is pre-existing, and this PR strictly reduces it.

Transposing #23's own headline case — a 26-char English echo, codes settled foreign:

| home | rendering | Swift `.count` | on `main` (floor 8) | on this PR (floor 5) |
|---|---|---|---|---|
| `de` | `14 Euro` | 7 | swallowed | **shown** |
| `zh` | `14欧元` | 4 | swallowed | swallowed *(unchanged)* |
| `ko` | `14유로` | 4 | swallowed | swallowed *(unchanged)* |
| `zh` | `一共十四欧元` | 6 | swallowed | **shown** |

Every CJK row is unchanged or improved. Blocking here asks this PR to fix a pre-existing latent defect that it already partially mitigates and that is tracked in #38, with the constants now documented in-code as German-calibrated. That holds a real fix hostage to a larger one, for a configuration Heiko does not use.

**Findings I checked and am clearing, so Codex does not spend a round on them:**
- *"Constrain the feature to the measured German configuration"* — it is already narrower than before for every language. There is nothing to constrain.
- *"Tests do not cover the all-language home setting"* — true, but that is #38's scope. Nothing in this diff makes coverage worse, and `L1.29e` already pins the settings wheel.

---

### My own finding, which Codex did not raise

Lowering 8 → 5 is monotone in the *swallow* direction, but it does open a **new false-accept surface**. A home false start of 5–7 characters beside an echo more than 2.5× its length (i.e. below the 0.4 ratio floor) is now accepted as a translation where `main` rejected it — e.g. `.de: "Ich hab"` (7) beside a 30-char echo: `7/30 = 0.23`, so it falls to the floor, and `7 >= 5` now passes.

**I judge this acceptable, not blocking:**
- Every false start observed in this repo is 3 characters (`"Ich"` / `"Das"` / `"Und"`); 5 keeps two characters of margin, and `L1.22`, `L1.31b`, and `L1.41b` all still pin the 3-char rejection.
- Where the ratio is ≥ 0.4, a proportionally-large false start was **already** accepted on `main` by the ratio branch — the floor was never the primary guard against these.
- The cost asymmetry runs the right way for this app. A false accept is a visible and audible wrong bubble that Heiko can react to, and it is recoverable — a rejected commit *clears* a streaming-set direction (`L1.36b`/`L1.36c`). A false reject is a silent swallow he will never report. This repo's stated priority is the silent failure.

Worth adding to #38 as the accepted trade, since the doc comment at `TurnLogic.swift:186` currently argues only the swallow side of the ledger. Not a merge blocker.

**What I did not verify:** the L3 `56/56` claim — those are replay tests I did not run. The PR already says one clean `de_after_es` run is not proof that known-flaky case is fixed. I agree: treat that line as unproven rather than as evidence, and do not read it as a regression signal either way.

---

### Plain-Language Summary

**What changed?**
When the foreign speaker says something short, the app translates it for Heiko — but it also has a safety check that throws away very short results, because half-finished words like "Ich" are not real translations. That check was set too strictly. A real translation like "14 Euro" was being thrown away and never shown, which is the exact problem that was reported from the device. The cut-off has been lowered just enough to let short real answers through, while still throwing away the half-finished ones.

**What could break?**
The app is now slightly more willing to accept a short piece of text as a real translation. So in rare cases it might show a half-finished word as if it were a translation. That kind of mistake is one you can see and hear when it happens, and the app corrects itself when the full result arrives. The mistake it replaces — a real translation vanishing with nothing on screen — was invisible, so Heiko would never have known to mention it. This is a deliberate trade in the safer direction.

One thing to know: this cut-off counts *letters*, and it was measured against German. Chinese and Korean write the same meaning in far fewer letters, so the cut-off is effectively stricter in those languages. That is not made worse by this change — it is actually a little better than before — and it is written down as issue #38 for later. Heiko's language is German, so it does not affect him.

**What should you manually verify?**
On the device, have someone say a short thing to Heiko in the foreign language — a price like "that'll be fourteen euros", or a plain "yes" or "no". Check that the German translation actually appears on screen and is spoken, instead of the turn vanishing. Try it a few times, including when the other person speaks a long sentence and the German answer is very short — that is the specific case this fixes.

---

🤖 Final-gate review by Claude Opus 5
