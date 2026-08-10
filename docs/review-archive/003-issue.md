# issue #3 — Reconnect after a post-handshake session close has no backoff or attempt cap, unlike a pre-handshake error

- **State:** closed
- **Opened by:** jctoledo on 2026-08-01T23:52:34Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/3

---

## Summary
`GeminiLiveSession` reports **any** unintentional post-handshake transport teardown — the deliberate `goAway` duration-limit close *and* an abrupt network drop/flap — identically as `.closed`. `GeminiLiveTranslationService.handle(_:_:)` reconnects on `.closed` immediately, with no delay and no attempt cap, unlike the `.error` path (pre-handshake failures), which goes through `scheduleSessionRetry` (2s/5s/10s backoff, capped at 3 attempts). A connection that keeps completing its WebSocket/TLS handshake and then dropping — a flapping Wi-Fi/cellular handoff, not just the ~9 minute `goAway` case — reconnects instantly and repeatedly with no cooldown.

## Location
`HeikoTranslate/Services/GeminiLiveSession.swift`, `didCompleteWithError` around lines 335-362 (branches only on `intentionalClose`/`hasOpened`, never on whether this was actually a `goAway`).

`HeikoTranslate/Services/GeminiLiveTranslationService.swift`, `handle(_:_:)`:
```swift
case .closed:
    // The Live session hit its duration limit and closed. Reconnect
    // so the conversation keeps working.
    reconnect(lang)          // <- no backoff, no cap, no distinction from goAway
...
case .error(let message):
    ...
    scheduleSessionRetry(lang)   // <- 2s/5s/10s backoff, capped at 3 attempts
```

## Failure scenario
Marginal connectivity (elevator, moving vehicle, cell handoff) causes the socket to complete its handshake and then drop repeatedly. Each drop is reported as `.closed` (since `hasOpened` was true), and each is met with an immediate, uncapped `reconnect(lang)` — a fresh handshake attempt with zero cooldown, for as long as the flakiness continues. This is not a CPU busy-loop (each cycle is bounded by real handshake latency), but it is an unbounded reconnect *storm*: no cooldown, no cap, and no distinction from the intended "reconnect promptly after a graceful `goAway`" case — burning battery/data and risking a rate-limit response from Google, exactly the failure mode `scheduleSessionRetry` exists to prevent on the `.error` side.

## Suggested fix
Distinguish an actual `goAway`-driven close (already detected server-side in `GeminiLiveSession.handleServerMessage`'s `goAway` branch) from an abrupt post-handshake failure, and route the latter through the same backoff/cap machinery as `.error` — or at minimum give `.closed`-triggered reconnects their own small cooldown so a flapping connection can't spin freely.

## Severity
**Medium** — real on any unreliable connection, with battery/data and possible-rate-limit consequences, though self-healing once the network stabilizes.

*Found via code review; independently re-verified before filing, including confirming no other throttle exists on this path.*

---

### Georg-Klock — 2026-08-02T03:25:11Z

Fixed in 4c2fbd8.

`GeminiLiveSession` now tracks whether it saw `goAway` and reports `.closed(expected: Bool)` instead of collapsing both cases into one event. A planned close still reconnects immediately — that one is the duration limit, and any delay there is dead air mid-conversation. An abrupt post-handshake drop goes through a new `scheduleDropReconnect` with a 1s/2s/5s/10s cooldown, reset on a clean `setupComplete` so one bad tunnel doesn't leave a language slow for the rest of a trip.

**One deliberate deviation from the suggestion.** You offered routing the abrupt case "through the same backoff/cap machinery as `.error`", and I took the backoff but not the cap.

The two failures aren't the same shape. A pre-handshake failure usually means something permanently wrong — bad key, no route — so giving up after three attempts and surfacing it is right. A socket that completes its handshake and *then* dies means the network is there and intermittent. Capping that would mean the app stops trying after ~17 seconds and stays stopped, and the person holding this phone is abroad using it to order lunch; a translator that gave up in a lift and never resumed would be worse than one that retries slowly. So the delay escalates and then holds at 10s indefinitely. No storm, but it always recovers when the network does.

Worth noting the interaction with #4: had I capped this, that fix would have been carrying much more weight than it should.

L1 43/43, L3 56/0 — the latter matters here since it exercises real session lifecycles against the live API.
