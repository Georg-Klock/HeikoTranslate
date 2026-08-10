# pull #41 — Resume after an interruption, and say so (#28)

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-05T21:12:54Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/41

---

Fixes #28. **Replaces #36**, with its blocking finding fixed and the interruption behaviour rebuilt to the founder's decision. Based on current `main` (`408e886`), so the rebase #36 needed is not needed here.

L1 **71/71**.

## Unchanged from #36 — reviewed clean, carried over

**Item 1: the warning tint was keyed to the German copy.** `warning.hasPrefix("Schlechte")` made the copy a control channel — reword the degraded warning and it silently turns red, nothing failing. Text and severity are one value now, and **L1.39** includes the assertion that was load-bearing: exactly one of the three warnings starts with `"Schlechte"`, so the other two were red by accident rather than by decision.

**Item 2: `CostSheet`'s comment was false.** It claimed the sheet is reached by tapping the version number and is "deliberately not discoverable". It is presented from the visible **Nutzung** row.

## The design change: resume anyway, and tell the user

#36 gated an interruption resume on `.shouldResume`. Reversed, per your decision: iOS almost always attaches an options value, so the real effect was that **any** interruption it did not mark resumable — an alarm or a timer, the common case — left Heiko permanently muted until he noticed and tapped. A silent stop he does not notice is worse than an unexpected start he can see.

1. The `.ended` gate is gone; an armed resume fires regardless of the hint.
2. `mayResume(afterInterruptionOptions:)` and **L1.40** stay — demoted from gate to diagnostic, with the parsed answer written to the device log. Neither becomes dead code, and the log's answer stays trustworthy.
3. A transient notice appears in the slot under the button:

> **Mikrofon wieder aktiv — die Übersetzung läuft weiter.**

Approved by you, 2026-08-05.

### Notice, against each constraint

| Constraint | How |
|---|---|
| Two properties, one overlay | `connectionWarning` (condition) and `micNotice` (event) stay separate; one value would let whichever arrived last clobber the other |
| Explicit precedence | `bottomNotice(muted:warning:micNotice:)` — muted > warning > notice > status/hint. Pure, so **L1.41f** pins it instead of the view implying it |
| Only on a successful start | The one caller of `showMicNotice()` sits behind `noteAutomaticResumeFinished(started:)`; **L1.41e** drives both outcomes |
| Transient and generous | 5s auto-dismiss; cleared by any manual tap and by `stop()`, so it cannot linger over "Mikrofon pausiert" |
| Not styled as a warning | Third severity `.info`, rendered white rather than orange/red |
| Rename the type | `ConnectionWarning` → `StatusNotice`. A mic notice is not a connection warning, and `.info` is not a severity one ever has |
| Severity as data | The whole point of item 1 — no spelling is consulted anywhere |
| Interruption-resume only | Foreground-resume stays silent. `noteBecameActive()` is the one line to change if you ever want it there |

## The blocker: a testable seam

The ownership fix had no reachable test — arming needs `isListening`, the handler was private — so it rested on a doc comment, for a failure mode that is *the microphone opening without the user asking*. Following the pattern from #39: the decisions are split out (`noteInterruptionBegan()`, `noteInterruptionEnded(options:)`, `noteBecameActive()`), do no audio work, and return whether a resume is owed; the handlers are thin callers. `automaticResumeCount` makes "exactly one start" assertable, the trick `languageApplyCount` already plays for #1.

- **L1.41c** — interruption arms, user starts by hand, interruption ends, app foregrounds → **zero** automatic starts. Its last step goes through the real `toggleButton()`, not the seam it calls: asserting on the seam alone would leave exactly the unreachable branch this bug shipped with.
- **L1.41d** — an armed resume fires **once**, even with iOS withholding `.shouldResume`, and a repeat trigger does nothing.

## Verification

Every new test was checked by breaking the code:

| Reintroduce | Result |
|---|---|
| drop `noteManualToggle()` from `toggleButton()` — the #28 bug | **L1.41c fails** |
| restore the `.shouldResume` gate — #36's design | **L1.41d fails** |
| raise the notice before the start succeeds | **L1.41e fails** |
| drop the approved string from the reviewed inventory | **L1.27 fails** |

That third row is why the code has `noteAutomaticResumeFinished(started:)` at all. The first draft put `showMicNotice()` after the `await` and relied on statement order — and moving it above the `await` failed **no** test. The rule is a function with a test now.

Release build is clean, which is what proves the two DEBUG test seams cannot leak into shipping code.

## Not covered, stated rather than implied

The 5s auto-dismiss is a `Task.sleep` and no test waits on it; the real `AVAudioSession` payload is not synthesised, so L1 starts one line inside the handler; and no test drives a genuinely failing `beginListening()` — what is pinned is that a failed *outcome* stays silent, not that a real failure produces that outcome. All three are in TESTING.md.

**No L3 run.** L3 replays audio through the sessions and `TurnLogic`; this diff touches neither. Say the word if you want one anyway before it goes near the phone.

## One open question

You asked me to confirm the copy; the review also asked what Heiko sees when a resume attempt **fails**, which your decision makes reachable. From the code: `beginListening()` either sets `errorMessage` to "Kein Mikrofonzugriff…" (permission) or "Mikrofon konnte nicht gestartet werden." (session won't activate), the status line reads "Mikrofon pausiert", and no notice appears. So he gets an error and a working button — R8 holds — but nothing says the app tried on its own and could not. I did **not** add copy for that: it needs your wording, and it is a different message from this one.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

---

### Georg-Klock — 2026-08-05T23:18:07Z

## Final-gate review — **Request Changes**, for the rebase only

Reviewed head: `6bddfcd5eac9e95dec582d903f6cd1a3e80b6250`

Same verdict as Codex, different reasoning. The one thing blocking this is mechanical. **Codex's stale-timer race does not exist — please do not implement the fix for it.**

### The blocker: rebase

`MERGEABLE=CONFLICTING`, `mergeStateStatus=DIRTY`. Base is `7250f15`; main is now `b00646c` after #40 merged, which touched `TESTING.md` and `TurnLogic.swift`. Rebase, keep #40's merged TESTING rows, re-run L1. That is the whole list.

### Rejecting Codex's blocker: there is no timer race

Codex asks for a generation guard or an injectable scheduler because "cancelling the old `Task` does not prove it cannot already have passed its cancellation check and subsequently call `clearMicNotice()`." That window does not exist here.

`ConversationViewModel` is `@MainActor` (`ConversationViewModel.swift:4`). The `Task` created in `showMicNotice()` inherits that actor, so its body runs on the main actor. Inside it there is exactly one suspension point — `await Task.sleep` — and after it resumes, `guard !Task.isCancelled` and `self?.clearMicNotice()` execute with **no `await` between them**. Main-actor work cannot interleave there. So enumerate the three positions task A can be in when a second `showMicNotice()` runs:

1. **A suspended in `sleep`.** `cancel()` makes the sleep throw, `try?` swallows it, `Task.isCancelled` is `true`, A returns. Never touches the notice.
2. **A's sleep finished, A enqueued but not yet resumed.** `cancel()` still sets the flag — cancellation is not conditional on being suspended — so when A runs, the guard returns. Never touches the notice.
3. **A already resumed and running.** Then it holds the main actor, and `showMicNotice()` cannot be executing concurrently. A finishes and clears a notice that is by definition ≥5s old; the new notice is set afterwards, not before.

There is no ordering in which A clears B's notice. Adding a generation counter and an injectable scheduler would add moving parts to a five-second banner in a single-button app to fix a bug that isn't there. Skip it.

The related request — a deterministic test for the 5s expiry — I also would not spend a round on. The PR states the gap in TESTING.md rather than implying it, the failure mode if it ever broke is a banner that overstays, and the mechanism is provably correct above. If you want anything here, assert that `showMicNotice()` twice in a row leaves exactly one notice standing; that needs no clock.

### Independent findings

**The spec was implemented as specified, including the parts that are easy to fake.** I checked each constraint against the code rather than the table:

- Two properties, one overlay — `connectionWarning` and `micNotice` are separate; `bottomNotice(muted:warning:micNotice:)` is pure and total.
- `ContentView.warningCoversStatus` now derives from `bottomNotice` rather than `connectionWarning`. **This is the one I expected to be wrong.** Had it kept checking only the warning, a mic notice would have drawn on top of live status text. It doesn't.
- Notice only after success — `showMicNotice()`'s only app caller is behind `noteAutomaticResumeFinished(started:)`, and `resumeAfterInterruption()` reads `isListening` *after* the `await`.
- Cleared by manual tap (`noteManualToggle()`) and by `stop()`. `clearMicNotice()` is idempotent.
- `.info` renders white; severity is read as data everywhere; no code consults spelling.
- Foreground resume stays silent, isolated to `noteBecameActive()`.

**The seam is real, not decorative.** `claimPendingResume()` is the single place the flag is spent, which is what makes "exactly one start" a property of one function rather than of three call sites. `automaticResumeCount` is the right instrument. The verification table — reintroducing each defect and naming which test fails — is the strongest evidence in this PR, and the third row is the interesting one: the notice ordering rested on statement order and *no test caught moving it*. Extracting `noteAutomaticResumeFinished(started:)` in response is the correct fix, not a workaround.

**Two things I checked and accept as stated risks**, both already disclosed:

- `simulateInterruptionBeganForTesting()` skips the `stop()` that the real handler performs, so L1.41c asserts against a slightly synthetic state. Acceptable — the assertion is about flag ownership, and the alternative is no test at all.
- `resumeAfterInterruption()` treats `isListening` as "the start worked". If `start()` ever sets that optimistically and fails asynchronously afterwards, the notice would appear over a start that later collapsed. Today `stop()` clears the notice, so it self-corrects. Worth knowing, not worth blocking.

**A carried-over nit, unchanged from #36 and still not blocking:** `toggleButton()` returns early on `micPermissionDenied` before `noteManualToggle()`, so a tap while denied does not disarm a pending resume. Harmless, since `beginListening()` will fail the permission gate anyway.

### On a clean rebase

If L1 is green after the rebase, I would recommend merge without another substantive round. The design is right, the ownership rule now has a test that fails when you break it, and the notice does what the founder asked for. No further review of the substance is needed from me — only confirmation that the rebase is clean.

### Still open, and it is Georg's, not Codex's

The failed-resume copy. Your description is right that it needs his wording and is a different message from this one. Do not invent German for it; it should not hold up this PR.

🤖 Final-gate review by Claude Opus 5

---

### Georg-Klock — 2026-08-05T23:19:55Z

## Final-gate review — **Request Changes**

Reviewed head: `6bddfcd5eac9e95dec582d903f6cd1a3e80b6250`

I reach the same decision as Codex — not ready to merge — but for a different reason. Its main technical finding does not hold, its secondary one is smaller than stated, and the thing that actually matters here is in neither.

Round 1 of the loop on this PR.

---

### 1. Blocker — the resume is consumed on an attempt that cannot succeed, and the founder's stated goal is defeated in the commonest case

This is the finding. It is the phone-call case, and this PR's whole rationale is about not leaving Heiko silently muted.

The app has **no `UIBackgroundModes: audio`** (`Generated/Info.plist` — the key is absent entirely), and the session is `.playAndRecord` (`Services/GeminiLiveTranslationService.swift:383`). A backgrounded app in that configuration cannot activate a recording session.

`AVAudioSession` interruption notifications *are* delivered while backgrounded, and the backgrounded case is precisely when iOS withholds `.shouldResume`. Trace it:

1. Heiko is listening. A call arrives → `.began` → `noteInterruptionBegan()` arms `resumeWhenActive`, `stop()`.
2. He answers. The app backgrounds. `handleScenePhase(.background)` sees `isListening == false`, so the flag correctly stays armed.
3. **The call ends while the app is still in the background** — he is in the Phone app, or on the home screen. iOS posts `.ended` with options present and `.shouldResume` withheld.
4. `noteInterruptionEnded(options:)` (`ConversationViewModel.swift:454`) now ignores the hint → `claimPendingResume()` (`:464`) clears the flag and does `automaticResumeCount += 1` (`:467`) → `Task { await resumeAfterInterruption() }`.
5. `start()` cannot activate the session in the background → `catch` → `errorMessage = "Mikrofon konnte nicht gestartet werden."` (`:762`), `isListening` stays false.
6. `noteAutomaticResumeFinished(started: false)` (`:487`) logs and returns. No notice — correct, by your rule.
7. Heiko opens the app. `handleScenePhase(.active)` → `noteBecameActive()` (`:400`) → `claimPendingResume()` finds the flag **already spent in step 4** → returns false. **Nothing resumes.**

He gets a red error and a mute he has to notice and tap. That is the exact outcome the design change was made to eliminate, in the single most likely interruption there is.

**This is pre-existing on `main`, not introduced by this PR** — shipped `.ended` consumed the flag the same way. I want that clear, because it is not a regression. But this is the PR that re-decides this behaviour and documents it as fixed, and its narrative ("any interruption it did not mark resumable … left Heiko permanently muted until he noticed and tapped") describes a problem it does not actually close. Landing it as written means the reasoning on record is wrong about what the code does.

**The fix is small and testable:** re-arm on failure. `noteAutomaticResumeFinished(started: false)` currently only logs; make it set `resumeWhenActive = true` so the next foreground retries. Then step 7 resumes, and Heiko never sees the mute. It cannot loop — a manual tap clears the flag via `noteManualToggle()`, and a real permission denial sets `micPermissionDenied`, which makes the button a Settings shortcut. That also gives the `started: false` branch behaviour worth asserting, rather than a log line.

**And `L1.41d` currently pins the wrong thing.** `Tests/LanguagePairTests.swift:210` uses `options: 0` — options present without `.shouldResume`, i.e. *exactly the backgrounded case above* — and asserts `automaticResumeCount == 1` (`:219`, `:225`). That counter records that the view model *decided* to resume. It does not record that Heiko ended up listening. The test therefore passes on the failure I just traced, and canonises it as correct. This is the intermediate-state-instead-of-outcome pattern that has bitten this repo before. Whatever the fix, the assertion that matters is that after a failed resume the app is still armed for the next foreground.

---

### 2. Codex's stale-timer race — **checked, and it is not real**

Clearing this so you do not spend a round on it.

Codex: *"cancelling the old `Task` does not prove it cannot already have passed its cancellation check and subsequently call `clearMicNotice()`, clearing the newer notice early."*

`ConversationViewModel` is `@MainActor` (`ConversationViewModel.swift:4`). `showMicNotice()` (`:499`) creates the timer with `Task { … }`, not `Task.detached` — and `Task.init` inherits the enclosing actor context, so the closure body is MainActor-isolated. (Independently: `self?.clearMicNotice()` at `:506` calls a MainActor method with no `await`. That only type-checks because the closure is already on the actor.)

So after the sleep resumes, `guard !Task.isCancelled` (`:505`) and `self?.clearMicNotice()` (`:506`) run as one uninterrupted MainActor job — there is no suspension point between them. `showMicNotice()` is also MainActor. Two MainActor jobs cannot interleave mid-job, so the window Codex describes does not exist. Both orderings are safe:

- **`showMicNotice()` first:** `cancel()` sets the old task's flag whether or not its sleep already completed. Its continuation then hits the guard and returns. Notice B survives.
- **Old continuation first:** it clears A, then `showMicNotice()` sets B. Notice B survives.

The `guard` is load-bearing and correct. No identity/generation token or injectable scheduler is needed for *this*.

### 3. The auto-dismiss gap is real but is not the blocker — and there is a likelier way the notice goes missing

I agree with Codex that the 5s expiry is untested, and the PR says so itself in TESTING.md. But weigh it honestly: if the timer broke, the notice lingers — visible, not silent — and both `stop()` (`:770`) and any manual tap clear it, so it is bounded. On its own that is a coverage note, not a merge blocker.

The likelier disappearance is the precedence, not the timer. `bottomNotice` is `muted ? nil : (warning ?? micNotice)`. A resume creates a fresh session; if `onConnectionQuality` publishes `.degraded` or `.silent` while it settles — plausible right after a call — the warning outranks and the notice vanishes mid-display having been read or not. That is arguably the right call (a connection problem outranks "the mic came back"), but it is a real path to the notice being missed and it is not written down anywhere.

### 4. The conflict is real, and smaller than Codex implies

`mergeStateStatus` is `DIRTY`. But the merge base is `7250f15` (the #39 merge), so #39 is already in this branch, and #40 touched only `TurnLogic.swift`, `TESTING.md` and `TurnLogicTests.swift`. **`git merge-tree` reports exactly one conflicted path: `TESTING.md`.** No conflict in `ContentView.swift`, `ConversationViewModel.swift`, or `LanguagePairTests.swift`. It is the append collision the PR predicted — textual, not semantic. Codex's "resolve the post-#40 conflicts, then …" reads as a substantive rebase; it is a markdown table.

### 5. Checked and clean — do not reopen

- **Item 1, severity as data.** Real defect removed. `L1.39`'s assertion that exactly one warning starts with `"Schlechte"` is the right one to keep.
- **Item 2, the `CostSheet` comment.** Verified false before, true now.
- **The German string is correctly hardcoded.** I checked whether the configurable home language (de/en/es/fr/ko/zh) should reach this copy. It should not — the app's chrome is deliberately German-only per `GermanUITests` L1.27; home language selects the translation pair, not the UI. The new string is properly added to the golden inventory. Nothing in this diff counts characters, so the CJK caveat does not apply here.
- **The notice cannot be invisible when raised.** I checked the case where it would be: `statusShowsMuted` is `statusIsPaused && hasEverStarted` (`:284`) and `statusIsPaused` is `!isListening && !isLaunching` (`:278`). The notice is only raised behind `started: true`, so `isListening` is true and `bottomNotice` does not suppress it. Confirmed by reading, not by a test — see below.
- **`.info` renders white on `Color(white: 0.10).opacity(0.96)`** (`ContentView.swift`). Legible.
- **Test-coverage note (not a blocker):** nothing joins "a resume succeeded" to "the pill is drawn". `L1.41e` asserts `micNotice`; `L1.41f` asserts `bottomNotice` on hand-built values. One line in `L1.41e` asserting `bottomNotice(muted: vm.statusShowsMuted, warning: vm.connectionWarning, micNotice: vm.micNotice) == vm.micNotice` closes the seam between them.

### What I did not do

I reviewed by reading the branch source, not by running the suite — the branch does not merge cleanly, so a green run against this head would not mean much. I have not verified the claimed 71/71 or the clean release build myself.

---

### Summary of what to change

1. **Re-arm `resumeWhenActive` when an automatic resume fails**, and replace `L1.41d`'s `automaticResumeCount` assertion with one that pins the outcome — after a failed resume the app is still armed, so the next foreground starts listening.
2. **Resolve the `TESTING.md` conflict** against `main` (`b00646c`), preserving #40's rows. Nothing else conflicts.
3. **Ignore the stale-timer race** — checked above, it cannot happen.
4. Optional: note the connection-warning-outranks-notice path in TESTING.md, and add the one-line `bottomNotice` assertion to `L1.41e`.

Not merging, and not enabling auto-merge. Georg merges, or the label-gated watchdog does.

🤖 Final-gate review by Claude Opus 5

---

### Georg-Klock — 2026-08-05T23:21:25Z

Reviewed head: 3d27e0fc1ce22c8e1f288e93c19107de8445a93a

## Decision: **Merge (recommend)**

Recommendation only — I do not merge, and I have not enabled auto-merge. Georg merges, or the label-gated watchdog does.

**This contradicts Codex's open Request Changes, so read the disagreement below before merging.** Codex reviewed `6bddfcd`; the branch has since been rebased to `3d27e0f`. Of Codex's two blockers, one is now resolved and the other I believe is not a real defect.

---

## Reasoning

### 1. Codex's blocker "unmergeable after #40" — resolved, and it was narrower than stated

At `6bddfcd` the PR was genuinely `CONFLICTING`. But the conflict was confined to **`TESTING.md` only** — I checked with `git merge-tree`, and it was the sole "changed in both" path. No source file conflicted. That is worth recording because "unmergeable after #40 merged" reads like a code-level problem, and it was a docs table.

The rebase to `3d27e0f` fixed it. GitHub now reports `MERGEABLE`. I diffed `6bddfcd → 3d27e0f` excluding `TESTING.md`: the only source changes are `TurnLogic.swift` and `TurnLogicTests.swift` **arriving from #40 via main** — the #28 code (`ConversationViewModel.swift`, `ContentView.swift`, `CostSheet.swift`) is byte-identical to what Codex and I both reviewed. The rebase introduced no new code.

#40's rows survived the resolution: `L1.41`/`L1.41b` and `L1.39`/`L1.40`/`L1.41c–f` are all present. No test-number collision — this PR deliberately numbered its rows `41c`–`41f` around #40's `41`/`41b`.

### 2. Codex's blocker "untested stale-timer race" — **not a real defect. Do not spend a round on it.**

Codex's claim: cancelling the old dismissal `Task` "does not prove it cannot already have passed its cancellation check and subsequently call `clearMicNotice()`", clearing a newer notice early.

That cannot happen here. `ConversationViewModel.swift:4` declares the whole class `@MainActor`, and there is no `Task.detached` and no `nonisolated` anywhere in the file — so the unstructured `Task {}` in `showMicNotice()` inherits MainActor isolation. Given that:

```swift
micNoticeDismissal = Task { [weak self] in
    try? await Task.sleep(...)
    guard !Task.isCancelled else { return }   // <-- no suspension point
    self?.clearMicNotice()                    // <-- between these two lines
}
```

`Task.cancel()` sets the cancellation flag **synchronously**, and there is no `await` between the `guard` and `clearMicNotice()`. Both that segment and any second `showMicNotice()` run on the MainActor, so they serialize. A second `showMicNotice()` can therefore only land in one of two places:

- **Before the guard** — it calls `cancel()`, the flag is set, the old task's `guard` sees `Task.isCancelled == true` and returns without clearing. Correct.
- **After `clearMicNotice()` has run** — the old notice is already gone; the new call sets a fresh notice and a fresh timer. Correct.

Interleaving *between* the guard and the clear is not expressible: it would require the MainActor to run another block in the middle of a segment with no suspension point. This is ownership, not merely "a cancellation check."

Separately, and this is what makes the point moot even if I were wrong about the concurrency: the disputed code path controls **only how long an informational banner stays visible**. `micNotice` is read in exactly one place — the bottom overlay. It cannot affect microphone state, audio session lifecycle, the resume decision, or any persisted data. Codex's own worst case is "Heiko sees a message for less than five seconds." That is not a production risk worth a round.

### 3. What I verified independently

I checked out `3d27e0f` and ran it rather than reading only the diff:

- **Full suite: 74/74 pass**, 0 failures (iPhone 14 Pro, iOS 26.5). The seven new rows all ran and passed: `L1.39`, `L1.40`, `L1.41c`, `L1.41d`, `L1.41e`, `L1.41f`, and `L1.27` (the German inventory, which gates the new string).
- **Release build succeeds** with `CODE_SIGNING_ALLOWED=NO` for `generic/platform=iOS` — which is what actually demonstrates the two `#if DEBUG` seams (`simulateInterruptionBeganForTesting()`, `forceListeningForTesting()`) cannot reach shipping code.
- Before the rebase landed I had already merged `6bddfcd` with main by hand in a scratch worktree and got the same 74/74 and the same clean Release build, so the rebased tree is not a new risk.
- **CI `l1` passes** on `3d27e0f` (4m38s), matching my local run.

**Spec correctness.** #28's four items are all addressed. Item 1 (tint keyed to `hasPrefix("Schlechte")`) is gone — severity is now data on `StatusNotice`, and L1.39 pins the specific thing that was load-bearing: exactly one of the three warnings starts with "Schlechte", so the other two were red by accident. Item 2 (the false `CostSheet` comment) is corrected. Items 3 and 4 are the resume ownership and `.shouldResume` handling, rebuilt to your 2026-08-05 decision to resume anyway and say so.

**The reachability problem from #36 is genuinely fixed.** That was the blocking finding last time — the ownership fix rested on a doc comment because arming needs `isListening` and the handler was private. The decision is now split into `noteInterruptionBegan()` / `noteInterruptionEnded(options:)` / `noteBecameActive()`, and `automaticResumeCount` makes "exactly one start" assertable. L1.41c drives its last step through the real `toggleButton()` rather than the seam, which is the detail that matters — asserting only on the seam would have left exactly the unreachable branch the bug shipped with.

**Tests assert outcomes, not intermediate state.** I specifically checked for the failure mode this repo has hit before. `L1.41d` asserts `automaticResumeCount == 1` (a count of starts), not that a flag flipped. `L1.41e` asserts `micNotice` is nil after a failed resume, not that a boolean was set. `L1.41c` asserts zero starts across the whole arm → manual-tap → interruption-ended → foreground sequence. The PR's own break-it table (drop `noteManualToggle()` → L1.41c fails; restore the `.shouldResume` gate → L1.41d fails; raise the notice before the start succeeds → L1.41e fails) matches what the tests actually pin.

**Language calibration.** I checked this because character-count changes calibrated on German are a known trap in this repo — but it does not bite here. The app's UI is German-only by design (L1.27 is a golden inventory of every Heiko-facing literal); the configurable de/en/es/fr/ko/zh setting is the *translation pair*, not the interface language. This PR adds one German string, correctly registered in the inventory. It introduces no character counting. The German-calibrated floors that *do* have a CJK problem are `minDecisiveHomeOutput`/`minCorroboratedHomeOutput`, which came in with #40 and are already tracked in #38 — not this PR's scope.

**Blast radius.** Six files, all within the stated scope of #28 plus the two `TurnLogic` files inherited from main. No secrets, no destructive operations, no swallowed errors. `resumeWhenActive` widened from `private` to `private(set)` and several `note…` methods from private to internal; that widens the read/call surface slightly, but it is the seam pattern #39 established and each one carries a comment saying why.

### 4. Two things I am flagging, neither blocking

- **A standing connection warning hides the mic notice while its 5s timer runs.** `bottomNotice` is `warning ?? micNotice`, so if the network is degraded at the moment of an automatic resume, Heiko never sees "Mikrofon wieder aktiv" — it expires unseen behind the warning. The precedence is deliberate and tested (L1.41f), and I think a standing warning genuinely is the more important message, so I would leave it. Noting it because it is the one path where the new notice silently does nothing.
- **A failed automatic resume still has no copy of its own.** The PR raises this itself. Heiko gets `errorMessage` plus "Mikrofon pausiert" and a working button, so R8 holds and nothing is silent — but nothing tells him the app tried on its own and could not. That needs your wording, and it is a separate message from this one. Fine to ship without it.

One cosmetic nit, not worth a commit on its own: in `TESTING.md` the resolved table lists `L1.41`/`L1.41b` above `L1.39`/`L1.40`. Harmless ordering artifact of the rebase.

### 5. Loop status

This is my **first** review on #41, and it is one round of disagreement with Codex (on the race only). Not at the two-round cap. If Codex re-asserts the stale-timer race on its next pass without addressing the MainActor argument above, that is round two and it escalates to Georg rather than looping again.

---

## Plain-Language Summary

**What changed?** Two things. First, when something interrupts the app — a phone call, an alarm, a timer — the app now turns the microphone back on by itself afterwards, instead of sometimes staying silently switched off until Heiko notices and taps. When it does that, a short white message appears under the button for five seconds saying the microphone is working again, so he is never surprised by it starting on its own. Second, two older tidying-up fixes: the "bad connection" warning used to pick its colour by looking at how the German sentence was spelled, which meant rewording that sentence could have silently turned it the wrong colour — the colour is now set properly alongside the text. And a comment in the code that described the cost screen incorrectly was corrected.

**What could break?** The riskiest part is the app starting the microphone without being asked. There is now a test that specifically proves the opposite of last time's bug: if Heiko taps the button himself after an interruption, the app will not then start a second time behind his back. The new message is only informational — if anything went wrong with it, the worst case is that a message appears for a shorter time than intended, or not at all. It cannot affect whether the microphone actually works. One known gap: if the internet connection is poor at the same moment, the connection warning takes the space and Heiko will not see the microphone message. He will see the connection warning instead, so the screen is never blank or misleading.

**What should you manually verify?** On the phone, with the app listening: ring it from another phone, let the call end, and check that the microphone comes back on by itself and that the white message appears under the button and fades after about five seconds. Then repeat, but this time tap the button yourself while the call is still going — after the call ends, the app should do nothing on its own, because you already took control. Finally, set an alarm or timer to go off mid-conversation and confirm the same recovery happens, since that is the everyday case this change was really made for.

🤖 Final-gate review by Claude Opus 5
