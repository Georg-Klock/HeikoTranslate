# issue #20 — Events and timers carry no run/instance identity: a stale drop-reconnect timer or a zombie session can corrupt the current run

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-04T20:01:11Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/20

---

## Summary
Three manifestations of one architectural gap: **nothing that arrives asynchronously — session events, reconnect timers — can be distinguished as belonging to a previous run or a replaced session instance.**

**1. The drop-reconnect timer survives stopSession() and fires into the next run.** `scheduleDropReconnect` (added with #3) arms an untracked `Timer` whose body guards only `self.isRunning`. Sequence: abrupt drop → timer armed (1–10s) → user mutes (`stopSession`, timer NOT invalidated — it is never stored) → user unmutes (`start()` sets `isRunning = true`, resets `dead = []`, creates fresh sessions) → stale timer fires → `reconnect(lang)`'s guards (`isRunning`, `!dead.contains`, `activePair.contains`) **all pass** → a second session is created for a language that already has a healthy one, which is then replaced in the map without being closed (see the lifecycle ticket). Compare `scheduleSessionRetry`, whose timer additionally guards `self.dead.contains(lang)` — that guard fails after a restart, which is why the older path is safe. The new path lacks exactly that check.

**2. handle()'s pair guard is vacuous after stop.** `GeminiLiveTranslationService.swift:574`: `guard activePair.isEmpty || activePair.contains(lang)`. `stopSession()` sets `activePair = []` — so after stop, the `isEmpty` clause lets **every** late event from the closing sessions straight into the switch. The comment above the guard says leftover sessions "must not reach the turn logic"; the empty-pair clause defeats that in precisely the post-stop window it matters.

**3. A replaced session's late setupComplete marks its successor ready.** Events are routed as `handle(lang, event)` — keyed by language, not by session instance. A zombie's `setupComplete` inserts `lang` into `readySessions` and can `openMicIfReady()` even though the CURRENT session for that language has not completed setup — reintroducing the documented "mic opened early, first utterance silently lost" bug through the back door.

## Suggested fix
Give each start() run a generation token (an `Int` is enough). Capture it in every session callback and timer closure; `handle` and timer bodies drop anything whose generation ≠ current. This one mechanism fixes all three at once and makes the class robust against every future stale-async bug of this shape, instead of patching guards one at a time.

## Severity
**High** — (1) is reachable by an ordinary mute/unmute during flaky network, i.e. Heiko in a lift.

*From the 2026-08-04 architecture audit, hand-verified. Finding (1) is a defect in the #3 fix itself.*
