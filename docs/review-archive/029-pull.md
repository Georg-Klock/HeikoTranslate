# pull #29 — Invalidate URLSessions, close replaced sessions, pin async work to a token

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-05T01:00:02Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/29

---

Fixes #19. Fixes #20. First two of the pre-trip audit items, in the agreed order.

## #19 — every session object was immortal

A `URLSession` strongly retains its delegate until invalidated. This class **is** its session's delegate, and nothing ever invalidated it — no `deinit`, no `invalidate` call anywhere in the file. Separately, `reconnect()` replaced sessions in the map without closing the instance it dropped, so on the `.error` path (an error frame is not a closed socket) the orphan kept whatever transport state it had.

Live sessions end on a ~9 minute duration limit, so this leaked dozens of instances across an afternoon — the usage pattern this app is built for.

`close()` now invalidates; `didCompleteWithError` self-invalidates for server-initiated teardown the orchestrator hasn't replaced yet; `reconnect()` closes before it replaces.

## #20 — async work carried no identity

Events route by **language**, and timers were armed per language. Neither could tell which *run* or which *instance* it belonged to. Three bugs, one shape:

1. **The drop-reconnect timer from #3 guarded only `isRunning`.** Mute during its delay, unmute, and `isRunning` is true again while `start()` has also reset `dead` — every guard passed, and the stale timer replaced a healthy session. The older retry path was safe only *by accident*: its `dead`-guard happens to fail after a restart. This one had no such accident. **This is a defect in my own #3 fix.**
2. **`handle()`'s `activePair.isEmpty ||` clause was vacuous exactly when it mattered** — `stopSession()` sets `activePair = []`, so every late event sailed through in the post-stop window the guard exists for.
3. **A replaced session's late `setupComplete` marked its successor ready**, which can open the mic before the current session finished setup — the documented "first utterance silently lost" failure, by the back door.

One mechanism now covers all three: `SessionRegistry` mints a token per registered session; every callback and timer captures the token current when it was created and checks it before acting.

## Why the rule is a separate pure type

`CLAUDE.md`'s reasoning for `TurnLogic`, applied one layer up. The service needs audio hardware and a network, so logic living inside it is untestable at L1 — which is precisely how #20 shipped *inside* the #3 fix. `SessionRegistry` is pure bookkeeping, so L1.30–L1.30f cover it.

## Verification, including what the tests do NOT prove

Reintroducing the naive `tokens[lang] == token` comparison fails **L1.30d on both assertions** — `nil == nil` is true after a `clear()`, which would wave through the exact stale continuations the type exists to stop.

Being straight about the rest: **L1.30 itself passes against that naive version.** It documents the semantic the service now relies on rather than catching a registry defect — the original bug was the *absence* of any token, which no registry-level test can reproduce. That's noted in `TESTING.md` rather than left implied.

L1 **49/49**. No L3: nothing here changes turn decisions, and the session-lifecycle paths L3 exercises are better checked on device — which is the next step for these two.

---

### Georg-Klock — 2026-08-05T01:52:41Z

## Adversarial review

Reviewed against the code at this branch's head, not just the diff. The `SessionRegistry` mechanism is right, and being explicit that L1.30 does *not* catch the original bug is the correct call — that note belongs in TESTING.md exactly where it is. Two things this breaks or leaves behind.

### 1. Cost tracking now silently undercounts

`handle()`'s guard has an `else` branch that exists for exactly one purpose:

```swift
guard activePair.contains(lang) else {
    if case .usage(let usage) = event { CostTracker.shared.record(usage: usage) }
    return
}
```

The token check in `makeSession` now drops those events **before `handle` is ever called** — in both cases this branch was written for:

- post-`stopSession()` — the registry is cleared, so every late event is inert;
- post-`reconnect()` — the old instance's token is superseded.

A pair change routes through `start()` → `stopSession()` → `clear()`, so there is no surviving path into it. That branch is dead code now.

`CostTracker.record` is additive (`+=`), so every mute and every ~9-minute goAway reconnect loses whatever usage frames were in flight. Small per event, but it accumulates in the least helpful direction: free tier, hard 20K TPM window, and the number on the dev sheet drifts low as session count grows.

Fix: record `.usage` in the `makeSession` callback ahead of the token check, or apply the token check only to non-`.usage` events.

### 2. `finishTasksAndInvalidate()` quietly makes `GeminiLiveSession` one-shot

Safe today — every instance gets exactly one `connect()`. But `connect()` now carries an invisible precondition: calling it a second time on the same instance creates a task on an invalidated `URLSession`, which fails and surfaces as `"connection failed before handshake"` — the error that drives the retry loop. That is a nasty shape to debug from a device log.

One line on `connect()` ("single-use; construct a new instance to reconnect"), or a `guard !isInvalidated`, costs nothing.

Related: the comment asserts "Invalidating twice is a no-op." True in practice, but Apple documents neither the case nor the guarantee, and this repo normally footnotes claims like that with a measurement. It *is* hit on the normal path — goAway self-invalidates, then `reconnect()`'s `close()` invalidates again.

### 3. Nits

- `checkStartupHealth` still does `sessions[lang]?.close()` immediately before `reconnect(lang)`, and `reconnect()` now closes too. Redundant as of this PR — delete it, or the next reader will assume it is load-bearing.
- The event callback still hops via `Task { @MainActor }`, which does not guarantee ordering — including for `.audioChunk`. Pre-existing, not this PR's doing, but this PR moves that exact closure into `makeSession`, so it is the last convenient moment to note it.

### 4. L3

"No L3: nothing here changes turn decisions" is *almost* right — the `handle` guard change does alter what reaches `TurnLogic` at run boundaries, and the reconnect paths are what the L3 replay harness exercises. More to the point, the PR names device testing as the next step, and the standing rule since 2026-07-29 is **L1 and L3 before every device deploy**. So L3 is owed before that deploy regardless of whether it gates this merge.

### 5. Merge conflict with #30

`git merge` of the two branches **conflicts in `TESTING.md`** — both append after L1.29e and both extend the "Beyond the numbered rows" block. Whichever lands second needs a rebase.

---

**Verdict:** close — fix the usage drop (1) and this is mergeable.
