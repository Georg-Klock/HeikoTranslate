# issue #19 — GeminiLiveSession instances are never deallocated: URLSession(delegate: self) is never invalidated, and reconnect() replaces sessions without closing them

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-04T20:01:10Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/19

---

## Summary
Two related lifecycle holes that together leak a session object — and potentially a live WebSocket — on every reconnect and every goAway cycle.

**1. The URLSession retain cycle.** `GeminiLiveSession.swift:101` creates `URLSession(configuration: .default, delegate: self, delegateQueue: nil)`. A URLSession **strongly retains its delegate until invalidated**, and nothing in the class ever calls `invalidateAndCancel()` / `finishTasksAndInvalidate()` — there is no `deinit` at all (verified by grep: zero hits for `invalidate` in the file). Every `GeminiLiveSession` ever constructed is therefore immortal.

**2. reconnect() drops the old instance without closing it.** `GeminiLiveTranslationService.swift` `reconnect(_:)` builds a new session and does `sessions[lang] = session` — the previous instance is neither `close()`d nor cancelled. On the `.error` path the old transport is not necessarily dead (an error frame ≠ a closed socket). Combined with (1), the orphan is retained forever with whatever transport state it still has, and its event callback keeps firing (see the companion identity ticket).

## Why it matters here specifically
Live sessions hit the server's duration limit roughly every 9 minutes → `goAway` → reconnect. Two sessions × an afternoon of Heiko using this in California is dozens of leaked instances per conversation session, plus every flaky-network reconnect. This app is expected to run for hours on a phone.

## Suggested fix
- `close()` calls `urlSession.invalidateAndCancel()` after cancelling the task (this also breaks the retain cycle; note `invalidateAndCancel` fires one final `didCompleteWithError` — the `intentionalClose` flag already covers that path).
- `reconnect(_:)` closes the instance it is replacing: `sessions[lang]?.close()` before reassignment — the same one-line discipline #1's fix added to `start()`.

## Severity
**High** — unbounded resource growth in the app's core loop, invisible in short test sessions.

*From the 2026-08-04 architecture audit (adversarially verified by hand after the automated verifiers hit a session limit).*
