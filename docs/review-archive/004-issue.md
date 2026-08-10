# issue #4 — App can get stuck showing "Verbinde…" forever if both sessions in the pair permanently fail

- **State:** closed
- **Opened by:** jctoledo on 2026-08-01T23:52:35Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/4

---

## Summary
If both sessions in the active language pair fail before ever reaching `setupComplete` (e.g. no network at launch), `openMicIfReady()` permanently no-ops once both languages are `dead`, and nothing else in the file ever resets `currentActivity`/`isRunning` in that state. The UI is left showing a permanent connecting spinner simultaneously with an error message, with no automatic recovery — only an unlabeled "tap to mute, tap again to retry" as the actual fix.

## Location
`HeikoTranslate/Services/GeminiLiveTranslationService.swift`, `openMicIfReady()` (around line 614) and `scheduleSessionRetry()` (around line 628), cross-referenced with `ConversationViewModel.swift`'s `isConnecting`/`statusText`.

```swift
private func openMicIfReady() {
    let required = sessions.count - dead.count
    guard !anySessionReady, required > 0,
          readySessions.subtracting(dead).count >= required else { return }
    ...
}
```

## Failure scenario
Both sessions error out pre-handshake (total network loss at launch is the realistic trigger, given this project's own context of Heiko/Georg travelling). Both land in `dead`; `sessions.count` never shrinks (`.error` doesn't remove from `sessions`), so `required` hits `0` and `openMicIfReady()` no-ops forever. `checkStartupHealth()`'s one-shot 3.0s watchdog only opens the mic with "partial readiness" when `!readySessions.isEmpty`, which is false here — and its own `reconnect(lang)` calls are guarded out while the language is still `dead`. `scheduleSessionRetry` exhausts its 3 attempts (~17s of backoff) and then permanently stops retrying. No remaining code path calls `setActivity()` outside of states this scenario never reaches. Net UI: `isConnecting` (`isListening && activity == .connecting`) stays true forever — the spinner never clears — while `errorMessage = "Verbindungsfehler. Bitte nochmal versuchen."` is shown at the same time. The two signals contradict each other ("still connecting" vs. "failed, retry"), and nothing indicates that tapping the (visually "connecting") button is the fix.

## Suggested fix
When every session in the pair is `dead` and no more retries are scheduled, explicitly reset activity/`isRunning` (or auto-invoke the equivalent of a mute) so the UI honestly reflects "stopped" rather than "still connecting," per SPEC R8 ("the app must never sit in a state where speaking does nothing... it recovers or says so").

## Severity
**Medium** — realistic trigger (no connectivity at launch) given the app's own travel-abroad use case, and a direct instance of the R8 invariant SPEC.md itself calls non-negotiable.

*Found via code review; independently re-verified before filing, including cross-checking that no other code path resets the UI state in this scenario.*

---

### Georg-Klock — 2026-08-02T03:25:13Z

Fixed in 5bbee3e.

Confirmed the whole chain, including that `sessions.count` never shrinks so `required` reaches 0 and `openMicIfReady()` no-ops permanently.

`scheduleSessionRetry` now calls a new `failIfPairIsDead()` when it exhausts its attempts. That checks the whole pair is dead with no retries left, tears the run down, and notifies the view model through a new `onSessionsExhausted` callback; the view model drops to the muted state.

The result is the honest state you asked for: "Mikrofon pausiert" next to the existing error line, with the button visibly not-listening so tapping it is the obvious move.

**No new user-facing string, on purpose.** The existing `Verbindungsfehler. Bitte nochmal versuchen.` already tells Heiko to try again — the problem was never the wording, it was the spinner contradicting it. Adding German copy here would have meant a new entry in the `GermanUITests` golden inventory for no gain. (Related: #5 is about a gap in exactly that guardrail.)

L1 43/43, L3 56/0.
