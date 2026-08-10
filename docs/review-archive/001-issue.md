# issue #1 — Picking the same language for home/partner while listening can crash the app and leaks a WebSocket session

- **State:** closed
- **Opened by:** jctoledo on 2026-08-01T23:52:23Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/1

---

## Summary
Selecting a partner language equal to the current home language (or vice versa) in the settings sheet while the app is actively listening triggers `persistAndApplyLanguages()` **twice** for one user gesture, due to a nested `didSet` re-entrancy bug. Each call independently restarts the translator without a guaranteed teardown in between, which can crash via a duplicate `AVAudioEngine` tap install and/or leaks a live (billed) Gemini WebSocket session.

## Location
`HeikoTranslate/ConversationViewModel.swift:20-50`

```swift
@Published var homeLang: TurnLogic.Lang {
    didSet {
        if homeLang == partnerLang { partnerLang = oldValue }
        persistAndApplyLanguages()
    }
}
@Published var partnerLang: TurnLogic.Lang {
    didSet {
        if partnerLang == homeLang { homeLang = oldValue }
        persistAndApplyLanguages()
    }
}
private var applyingLanguages = false
private func persistAndApplyLanguages() {
    guard !applyingLanguages else { return }
    applyingLanguages = true
    defer { applyingLanguages = false }
    ...
    if isListening {
        stop()
        Task { await self.beginListening() }
    }
}
```

## Failure scenario
Start with `homeLang = .de`, `partnerLang = .en`, `isListening = true` (a normal active conversation). Open Settings and pick German on the **partner** wheel (colliding with home):

1. `partnerLang = .de` fires `partnerLang`'s `didSet` (`oldValue = .en`).
2. `partnerLang == homeLang` is now true → executes `homeLang = .en` (the swap).
3. That nested assignment fires `homeLang`'s `didSet` synchronously, which calls `persistAndApplyLanguages()` — **call #1**. Because of the `defer`, `applyingLanguages` is back to `false` the moment call #1 *returns*, not when the outer `didSet` finishes.
4. Control returns to `partnerLang`'s `didSet`, which then runs its own trailing, unconditional `persistAndApplyLanguages()` — **call #2**, not blocked by the guard (already reset).

Both calls see `isListening == true` and each independently does `stop(); Task { await self.beginListening() }`. Both `beginListening()` tasks run on the MainActor and each awaits `translator.requestPermissions()` almost immediately; when both resume, both call `start()`. `GeminiLiveTranslationService.start()` does not call `stopSession()` internally and does not guard on `isRunning` — so the second `start()` calls `startAudioIO()` (and `installTap(onBus: 0, ...)`) while the first start's engine/tap may still be live. `AVAudioEngine.installTap` on a bus that already has a tap installed is documented to trap. Even when the crash doesn't trigger, the second `start()` overwrites `sessions[lang]` for both languages without ever calling `.close()` on the sessions the first `start()` just created — those WebSocket sessions are orphaned, still streaming and billed, with no code path left that will ever close them.

## Suggested fix
Either scope `applyingLanguages` around the *entire* outer property-observer chain (e.g. do swap-detection and persistence as one atomic operation instead of via two independently-observed `@Published` properties), or make `persistAndApplyLanguages()`'s restart coalesced (a single pending-restart flag consumed once per run-loop turn), and make `GeminiLiveTranslationService.start()` defensively call `stopSession()` first (or refuse to run when `isRunning` is already true) so a duplicate `start()` can never install a second tap or leak a second set of sessions.

## Severity
**High** — reachable via a single, ordinary settings interaction while the app is in active use (SPEC §4.4 explicitly documents "selecting the same language on both sides swaps them" as expected behavior), with a real crash risk and a real cost/privacy leak (an unclosed, untracked session keeps streaming Heiko's audio to Google after the UI believes the pair changed).

*Found via code review; independently re-traced and confirmed (including the crash-risk consequence) before filing.*

---

### Georg-Klock — 2026-08-02T03:24:43Z

Fixed in b76e656.

Re-traced and confirmed exactly as described, including the `defer` timing: the flag went false when the *inner* call returned, so the outer observer's trailing call ran unguarded.

Took both halves of the suggested fix, since they fail independently:

- The re-entrancy guard now wraps **only** the nested swap assignment (`withPairAdjustment`), so the swap cannot trigger a second apply. One gesture, one apply.
- `GeminiLiveTranslationService.start()` now tears down a previous run before doing anything, so a duplicate `start()` is redundant rather than destructive no matter what the caller does. That covers the leak path as well as the `installTap` trap.

Regression coverage is L1.29/29b/29d/29e in a new `Tests/LanguagePairTests.swift`. These drive the real `ConversationViewModel` rather than a mirror, because the bug was in the observer wiring and no pure-logic test could have seen it — that needed a small `languageApplyCount` on the view model to make "how many times did this apply" observable at all.

Verified the tests actually catch it by reinstating the original observers: both colliding cases fail with `2` applies, both non-colliding cases stay green. With the fix, L1 43/43 and L3 56/0.
