# pull #30 — Rescue short translations beside an echo; make a denied mic recoverable

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-05T01:22:03Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/30

---

Fixes #23. Fixes #25. Items three and four of the pre-trip audit. Independent of #29 — based on `main`, no overlap.

## #23 — short translations were being swallowed outright

`homeIsRealTranslation` returned early on the ratio branch whenever the partner session produced anything. Since an echo is the *common* case for foreign speech, the settled-codes bypass added in L1.26 was unreachable almost exactly when it was needed.

Concretely: `"14 Euro bitte"` (13 chars) against a 37-char echo scores 0.35, below the 0.4 floor — so the turn was **swallowed entirely**, no bubble and no audio, even with the language codes unanimously settled foreign. That's the same failure L1.26 was filed for, in the half of the space its fix couldn't reach.

Corroboration now *composes* with the ratio instead of being shadowed by it, and still respects the absolute floor — which is the load-bearing part: a 3-char false start beside a full echo (L1.22) must stay rejected whatever the codes say.

## #25 — a denied microphone was unrecoverable

`hasEverStarted` stays false on denial, so `"Zum Sprechen antippen"` sat on screen beside the permission error. One line saying tap to speak, the other saying tapping won't work — permanently, because iOS only prompts once.

That's the app's most likely first-run failure, in front of the user least equipped to recover from it.

Two changes. The hint is suppressed whenever an error is showing. And the denial is treated as the terminal state it actually is: **the one button opens this app's page in Settings** rather than re-requesting a permission iOS will never ask about again.

I considered adding a separate "open Settings" button and rejected it — a second control in a single-button app contradicts the governing rule, and `openSettingsURLString` lands directly on the app's own pane, so Heiko never has to find it by name in a Settings app he can't read. The German copy changed to say what the button now does, and went *through* the `GermanUITests` inventory rather than around it.

## Verification

Reintroducing the original early return fails **L1.31 with a nil bubble** — the swallowed turn, exactly as reported — while **L1.22, L1.22b, L1.26 and L1.26b all stay green**, confirming the false-start guard wasn't loosened to buy the fix.

L1 **52/52**.

One honest note: I tried to verify #25 visually by revoking the mic in the simulator, but the simulator wouldn't foreground the app afterwards (it launches cleanly — the log confirms no crash — the display just stays on the home screen). Rather than keep chasing a screenshot I pinned the behaviour with **L1.32**, which is a better artifact anyway: it's permanent, and it asserts the exact contradiction rather than my reading of a picture. The Settings-routing branch itself is a two-line guard and remains unexercised until someone denies the permission on a real device.

---

### Georg-Klock — 2026-08-05T01:52:42Z

## Adversarial review

Reviewed against the code at this branch's head, not just the diff. CI is green and the PR body is unusually candid about its own limits — the two things below are what it still misses.

### 1. The fix does not fix the case it was filed for (blocking)

`TurnLogic.homeIsRealTranslation`, the new echo branch:

```swift
if let spoken = spokenLang, spoken != home {
    return homeText.count >= minDecisiveHomeOutput   // 8
}
```

The doc comment **directly above it**, untouched by this PR, says:

> measured 2026-07-29: a spoken number's translation `"14 Euro"` (7 chars) fell under the 8-char floor and the turn was swallowed. **The floor applies only while the codes don't corroborate.**

That sentence is now false in the branch this PR adds. `"14 Euro"` is 7 chars. L1.26 pins it as accepted *with no echo*. Beside an echo — which this PR itself calls "the common case for foreign speech" — it is still rejected.

Concrete, still-broken repro:

```swift
var l = TurnLogic()
settle(&l, "en", at: t(0))
l.noteOutputs([.de: "14 Euro", .en: "That'll be fourteen euros."], at: t(3))
// 7/26 = 0.27 < 0.4          → ratio fails
// 7 >= 8 → false             → homeIsRealTranslation false
// commit() → "codes-veto: settled en, home session never translated" → nil bubble
```

Turn swallowed outright. No bubble, no audio — the exact symptom in #23, unchanged.

The test chose `"14 Euro bitte"` (13 chars). That's one word longer than the measured failure and sits safely over the floor. The verification argument ("reintroducing the early return fails L1.31") is sound, but it proves the branch is now *reachable* — not that the reported band is fixed. **The fix covers home outputs of 8+ chars beside an echo; the failure was reported at 7.** Prices and numbers — what Heiko will actually be doing at a Kasse — live squarely in the ≤7 band.

There is also an inconsistency this creates in the name of the false-start guard:

- **No echo** + settled foreign codes → floor waived entirely, so `"Ich"` (3 chars) is **accepted**.
- **Echo** + settled foreign codes → floor applies, so `"14 Euro"` (7 chars) is **rejected**.

The same guard, applied in opposite directions, in adjacent branches.

Suggested resolution: pick one rule for "codes settled non-home" and use it in both branches. L1.22's false start is 3 chars, so a shared floor of 4–5 keeps L1.22 / L1.22b / L1.26 / L1.26b green and rescues `"14 Euro"`. If 8 is genuinely load-bearing beside an echo, then the doc comment above needs rewriting to say so, and L1.26 needs a sibling pinning that `"14 Euro"` + echo is *deliberately* dropped. As it stands the code and the comment contradict each other.

### 2. `micPermissionDenied` is never cleared

Nothing sets it back to `false`, and `errorMessage` is not cleared on that path either (`start()` clears it, but `beginListening` returns before reaching `start()`). `handleScenePhase(.active)` only re-enters `beginListening` when `resumeWhenActive` is true, which the denial path never sets. So for the life of the process, `toggleButton` is permanently a Settings shortcut.

In practice iOS terminates an app when its microphone switch is toggled, which papers over this — but that is an undocumented dependency this PR rests on without stating. The case it does not cover: Heiko taps, lands in Settings, does not understand it, backs out. Same latched state, no way to retry, and the button now does nothing but send him back to the screen that confused him.

Fix is one branch in `.active`: re-check `AVAudioApplication.shared.recordPermission`, clear the flag and the error when granted. That also makes the Settings-routing branch reachable from a test, which answers the PR's own "remains unexercised" note.

### 3. Nit — `startHint`'s guard is broader than the bug

`guard errorMessage == nil` suppresses the hint for *any* error, not just denial. Currently unreachable in any other state (`hasEverStarted` is already true by the time connection errors fire), so harmless today — but L1.32 pins the broad behaviour, which locks in the over-reach. `guard !micPermissionDenied` says what you mean.

### 4. Merge conflict with #29

`git merge` of the two branches **conflicts in `TESTING.md`** — both append after L1.29e and both extend the "Beyond the numbered rows" block. The "no overlap" claim holds for code but not for docs; whichever lands second needs a rebase.

---

**Verdict:** should not merge as-is. Finding 1 means #23 stays open for the case that produced it, and closing the issue on this PR would bury it.
