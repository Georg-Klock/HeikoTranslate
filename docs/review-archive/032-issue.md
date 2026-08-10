# issue #32 — CostTracker undercounts: the token check drops late .usage events before handle() can record them

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-05T16:39:35Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/32

---

Introduced by #29 (merged), and flagged in review there.

## What happened

`handle()`'s pair guard has an `else` branch whose only job is to keep counting cost for events from sessions outside the current pair:

```swift
guard activePair.contains(lang) else {
    if case .usage(let usage) = event { CostTracker.shared.record(usage: usage) }
    return
}
```

#29 added a `SessionRegistry` token check inside `makeSession`'s callback, which drops stale events **before `handle()` is ever called**. That covers both situations this `else` branch existed for:

- post-`stopSession()` — `registry.clear()` invalidates every token from the run;
- post-`reconnect()` — the replaced instance's token is superseded.

A pair change routes through `start()` → `stopSession()` → `clear()`, so there is no surviving path into the branch. It is dead code.

## Impact

`CostTracker.record` is additive (`audioInputTokens += input`), so every teardown loses whatever usage frames were in flight — each mute, and each ~9-minute goAway reconnect. Small per event; it accumulates in the direction that matters least helpfully, since the free tier has a hard TPM ceiling and the dev sheet number is what says how close the app is to it.

## Suggested fix

Record `.usage` ahead of the token check in the `makeSession` callback, or apply the token check only to non-`.usage` events. Either way the `else` branch in `handle()` should then be deleted or re-justified, since as written it documents an intent the code no longer implements.

## Severity

**Low** — accounting only, no user-visible misbehaviour. Worth closing because the dead `else` branch will read as live protection to the next person.
