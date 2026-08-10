# issue #42 — A failed automatic resume tells Heiko nothing he can act on

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-06T15:40:00Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/42

---

## Summary

Follow-up to #28 / #41. Honouring the decision to resume after an interruption **regardless** of iOS's `.shouldResume` hint made the failure path reachable: the app can now try to restart listening on its own and not manage it. Today that produces `"Mikrofon konnte nicht gestartet werden."` plus a muted status line — a statement of failure with no action, for the one user least able to infer one.

Approved copy, from Georg, 2026-08-06:

> **Mikrofon ist aus — bitte antippen.**

## Scope: the automatic path only

Set it in the failure branch that already exists:

```swift
// ConversationViewModel.swift — noteAutomaticResumeFinished(started:)
guard started else {
    diag("app", "automatic resume after interruption did NOT start — no notice shown")
    return          // <- the copy goes here
}
```

That function is already the tested seam for this rule (**L1.41e** drives both outcomes), so this is a one-line change inside something with a regression test rather than a new branch to cover.

**Deliberately not the manual path.** A start that fails right after the user tapped the button leaves them looking at the control they just pressed; "bitte antippen" reads as a non-sequitur there. `"Mikrofon konnte nicht gestartet werden."` stays as it is for manual starts.

**Deliberately not the permission denial** (`ConversationViewModel.swift:352`). That case has its own copy and a *different action* — the button opens Settings, it does not start listening — so `"bitte antippen"` would be actively misleading. Leave `"Kein Mikrofonzugriff. Zum Öffnen der Einstellungen antippen."` alone.

## The constraint that will bite whoever implements this

**It cannot be a `micNotice`.** The precedence in `bottomNotice(muted:warning:micNotice:)` is muted > warning > notice, and a failed resume means `isListening == false` with `hasEverStarted == true`, so `statusShowsMuted` is true and the notice slot returns `nil`. A mic notice here would never render. The success notice works only because a *successful* resume leaves the app listening.

So this belongs in the `errorMessage` layer, alongside the copy it replaces.

## Acceptance

- [ ] A failed automatic resume shows `"Mikrofon ist aus — bitte antippen."`
- [ ] A failed **manual** start still shows `"Mikrofon konnte nicht gestartet werden."`
- [ ] A denied permission still shows the Settings copy, unchanged
- [ ] A **successful** automatic resume shows the `.info` notice and no error — L1.41e already asserts the notice half; extend it to assert the error is absent
- [ ] The line does not survive a subsequent successful start (see below)
- [ ] The new string is added to `reviewedStrings` in `Tests/GermanUITests.swift:26`, or **L1.27 fails** — that golden inventory is the point of the test

## A stale-error concern, raised and then checked — there is nothing to fix

An earlier revision of this issue asked whether `errorMessage` survives the retry that fixes it. **It does not.** Traced: `start()` opens with `errorMessage = nil` (`ConversationViewModel.swift:704`) before it touches the translator, so every start — manual or automatic — clears the previous failure first. The permission branch never reaches `start()` and is cleared by `noteMicPermission(granted:)` or by the next successful start.

So the new copy needs no extra teardown: whatever ends this state clears the line on its way through. Recorded here so it is not re-investigated.

## Severity

**Low-moderate.** Nothing is broken; the button works and R8 holds. But the whole point of the #28 decision was that a silent stop Heiko does not notice is worse than an unexpected start he can see — and a failed resume is currently exactly that silent stop, with an error line that does not tell him what to do about it.

---

### Georg-Klock — 2026-08-06T15:44:09Z

Corrected the body: the stale-`errorMessage` concern I raised does not hold. `start()` clears `errorMessage` at its first line (`ConversationViewModel.swift:704`), so a failed start's line cannot survive the retry that fixes it. No separate issue needed, and the acceptance item about it is dropped — the new copy needs no teardown of its own.
