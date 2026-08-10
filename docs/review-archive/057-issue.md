# issue #57 — Serialize and cancel pending microphone starts across rapid taps and backgrounding

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:39:10Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/57

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `HeikoTranslate/ConversationViewModel.swift:331-348`
- `HeikoTranslate/ConversationViewModel.swift:372-386`
- `HeikoTranslate/ConversationViewModel.swift:396-409`
- `HeikoTranslate/ContentView.swift:605-690`
- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:252-261`

## What's wrong

Every tap while `isListening == false` starts an unstructured `Task { await beginListening() }`. Neither `toggleButton()` nor `beginListening()` guards `isLaunching`, owns/cancels the task, or invalidates it after a scene transition. The UI shows a spinner but leaves the button enabled.

Two rapid taps can therefore await permission concurrently. If both are granted, both call `start()`; the service handles the second call by tearing down the first live run, producing an avoidable reconnect and potentially losing the beginning of speech. If the app backgrounds while a permission request is in flight, `handleScenePhase(.background)` stops only an already-listening session; the pending request can return and start audio/sockets while the app is backgrounded.

## Why it matters — moderate

The single primary control can create duplicate connection work, lost initial audio, and unnecessary billed sessions. Starting a microphone/session after the app has been backgrounded is a lifecycle and user-intent violation.

## Suggested fix

Give the view model one owned pending-start task (or a monotonically increasing start generation). Reject or intentionally cancel a second start while one is pending, invalidate/cancel it on background, and re-check both cancellation and active-scene state after permission returns.

For example, use a generation token:

```swift
private var startGeneration = 0
private var startTask: Task<Void, Never>?

private func invalidatePendingStart() {
    startGeneration &+= 1
    startTask?.cancel()
    startTask = nil
    isLaunching = false
}
```

Capture the generation before awaiting permission, then guard `!Task.isCancelled`, a matching generation, and an active scene before calling `start()`. Clear launch state with `defer`. Disable the microphone button while launch is in flight, or explicitly make a second tap cancel the pending launch; do not leave it ambiguous.

## Acceptance checks

- Two taps during a delayed permission response produce exactly one service `start()`.
- Backgrounding before permission resolves produces zero service starts; returning active requires a fresh valid start/resume path.
- A denied permission clears launching state and preserves the existing Settings guidance.
- Add an injected permission/service seam so these cases run as deterministic L1 tests.
