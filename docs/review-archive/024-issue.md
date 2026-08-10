# issue #24 — GeminiLiveSession: lifecycle flags are written on the main thread and read on the URLSession delegate queue with no synchronization; one pre-handshake failure can emit up to three .error events

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-04T20:02:00Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/24

---

## Summary
Same family as #2 — concurrency the compiler can't check under `SWIFT_VERSION 5.0` minimal checking — one layer down.

**1. Cross-thread flag races.** `hasOpened`, `isClosing`, `intentionalClose`, `sawGoAway` are plain `Bool`s. `close()` writes `intentionalClose` on the **main thread** (line 118); `urlSession(_:task:didCompleteWithError:)` reads it on **URLSession's private delegate queue** (line 365, `delegateQueue: nil` → session-owned serial queue); `didOpen`/`didClose` write `hasOpened`/`isClosing` on that queue while `closeTransport()` writes `isClosing` from wherever it is called. Beyond being UB by the memory model, the *ordering* race is real: a `close()` interleaving with `didCompleteWithError` can misclassify our own intentional close as server-initiated → a spurious `.closed` → a reconnect nobody asked for.

**2. One failure, three .error emissions.** A single pre-handshake connection failure can fire `.error` from three sites: the setup-message send failure (line 182), the receive-loop failure (line 197), and `didCompleteWithError` (line 372). Each one drives the orchestrator's `dead.insert` + `scheduleSessionRetry`, so one transient refusal can burn the entire 3-attempt retry budget instantly — and with #4's fix, prematurely trip `failIfPairIsDead`.

**3. Related cleanup, same file family:** the `AVAudioPCMBuffer` capture warning in the service's `convert()` (surfaced by CI on every PR since #17) is a false positive — the converter's inputBlock runs synchronously — but it should be *deliberately* silenced (`@preconcurrency import AVFoundation` or a `nonisolated(unsafe)` wrapper with a comment) so real Sendable warnings stay visible.

## Suggested fix
Route all flag access through one serial context (confine the flags to the delegate queue and hop `close()` onto it, or a small lock à la `MicConverterBox`), and collapse the error paths behind a `didReportFailure` latch so a session reports terminal failure exactly once.

## Severity
**Medium** — subtle misbehaviour rather than crashes today, but it sits under every connection the app makes, and it is the code strict-concurrency migration will flag first.

---

### Georg-Klock — 2026-08-06T16:24:54Z

## Verified against `main` (`4e1ce51`) — one of these is worse than filed, one is inert

Traced all three claims through the source. Summary: **fix item 2, it is a live user-facing bug. Item 1 is real UB whose stated consequence is already prevented — it is hygiene, not a defect.** That reordering matters, because item 1 reads like the scarier one and is the one that would eat a refactor.

### Item 2 — confirmed, and the consequence is worse than "burns the retry budget"

The triple emission is real, and `closeIsExpected` is why it is specific to the pre-handshake window:

```swift
private var closeIsExpected: Bool { isClosing || hasOpened }   // line 142
```

Post-handshake `hasOpened` is true, so the send and receive failure paths downgrade to `.debug` and only `didCompleteWithError` reports. **Pre-handshake both are false**, so one failed connection reports from all three sites (line 187, line 202, line 372).

The orchestrator's `.error` handler calls `scheduleSessionRetry`, which *increments the counter and schedules a timer every time*:

```swift
let attempts = retryAttempts[lang, default: 0]
guard attempts < sessionRetryDelays.count else { failIfPairIsDead(); return }
retryAttempts[lang] = attempts + 1
```

With `sessionRetryDelays = [2.0, 5.0, 10.0]`, a single pre-handshake failure walks the counter 0 → 3 in one burst and schedules three timers. `retryAttempts` is reset **only** on `.setupComplete` (line 615), so a second failure finds the budget already spent and goes straight to `failIfPairIsDead()`.

**Designed behaviour:** 4 attempts — t=0, +2s, +5s, +10s, giving up at ~17s.
**Actual behaviour:** 2 attempts, giving up at ~2s.

That is the exact scenario `failIfPairIsDead`'s own comment names — *"no network at launch, which for this app means the moment Heiko lands."* He opens the app before the network attaches and it stops trying after two seconds. Not a subtle misbehaviour; the retry ladder is effectively not there when it matters most.

(If the setup send happens to buffer rather than fail, it is two `.error`s instead of three. Barely better — the budget still goes 0 → 2 on the first failure.)

**The suggested `didReportFailure` latch is the right shape**, and note it is the missing half of a pattern already here: `closeIsExpected` was clearly meant to prevent exactly this double-reporting and simply does not cover the pre-handshake case.

### Item 1 — the race is real; the harm it describes is not reachable

The unsynchronized access is exactly as described. `intentionalClose` is written on the main thread in `close()` (line 118) and read on URLSession's delegate queue in `didCompleteWithError` (line 373), and the four flags are plain `Bool`s. By the memory model that is UB, and it is what strict-concurrency migration will flag first. All true.

But the stated consequence — *"a spurious `.closed` → a reconnect nobody asked for"* — **cannot happen on this code**, because it is defended twice over by the #20 fix:

```swift
// makeSession, line 69
GeminiLiveSession(...) { [weak self] event in
    Task { @MainActor in
        guard let self, self.registry.isCurrent(token, for: lang) else { return }
        self.handle(lang, event)
    }
}
```

1. Every session event hops to the **MainActor** before the orchestrator sees it. `stopSession()` is also MainActor, so a `.closed` racing with a mute serializes *after* it rather than interleaving.
2. `stopSession()` calls `registry.clear()` (line 372) before returning, so the token check drops the event at the door — `handle()` is never reached. And `reconnect()` independently guards on `isRunning`, `dead` and `activePair`.

So a misclassified `.closed` produces nothing. Worth keeping the issue open for the concurrency hygiene, but it should be **re-scoped to "make the flags sound before strict concurrency"** rather than carrying a user-facing failure story it cannot cause. Anyone fixing it should also know the registry already makes the ordering safe, so the fix does not need to be defensive on top of that.

### Item 3 — confirmed as described

`convert()` (line 569) captures `buffer` and mutates `delivered` inside the converter's input block, which `AVAudioConverter.convert(to:error:withInputFrom:)` invokes **synchronously**. The Sendable warning is a false positive, and silencing it deliberately — rather than living with it on every PR — is right, or the first genuine Sendable warning gets lost in the noise.

### Recommendation

Split this. Item 2 is a small, self-contained fix with a real user-facing payoff and should go on its own; a latch plus an L1 test that one pre-handshake failure produces exactly one `.error` and leaves `retryAttempts` at 1. Items 1 and 3 are concurrency hygiene with no behavioural symptom and belong together, ahead of any strict-concurrency migration but not ahead of anything Heiko can feel.

**Severity:** item 2 is **high**, not medium — it silently removes the retry ladder in the one situation it exists for. Items 1 and 3 are **low**.

Method note: verified by reading `main`, not by running the app or the suite. The timings above are read off `sessionRetryDelays` and the reset site, not measured on a device.

🤖 Final-gate review by Claude Opus 5
