# issue #60 — Make AVAudioEngine startup/restart idempotent and roll back partial setup

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:39:24Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/60

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:381-480`
- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:517-529`
- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:559-567`
- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:287-304`

## What's wrong

Every `startAudioIO()` calls `audioEngine.attach(playerNode)` and connects the same persistent node. `stopAudioIO()` stops the engine/player but never detaches the node or records that it is already attached. The watchdog explicitly calls stop/start to rebuild audio, and normal mute/unmute starts the same service again, so the code repeatedly attempts to attach an already-attached node.

Startup is also non-transactional. After activating the audio session and attaching/connecting the node, a converter or engine-start failure throws without a unified teardown. The next attempt inherits a partially configured graph/session.

## Why it matters — moderate

This makes normal recovery paths fragile: repeated start/stop or the watchdog’s intended rebuild can fail or trap, and a transient startup failure can leave the app in an unsafe partial-audio state.

## Suggested fix

Choose one ownership model and enforce it consistently:

- Attach/connect `playerNode` once for the service lifetime with an `isPlayerAttached` guard, or detach it during a unified teardown before any future attach.
- Make `startAudioIO()` transactional: on any failure after activation, remove an installed tap, stop the player/engine, clear converter state, deactivate the audio session, and rethrow.
- Reuse the same teardown for regular stop and watchdog recovery.

For example:

```swift
var setupSucceeded = false
defer {
    if !setupSucceeded { stopAudioIO() }
}
// configure/attach/start/install tap
setupSucceeded = true
```

Do not make `stopAudioIO()` silently assume that all setup stages completed.

## Acceptance checks

- A start → stop → start sequence attaches/connects the player exactly once per chosen lifecycle model and remains usable.
- A watchdog rebuild follows the same safe path.
- Forced converter creation and engine-start failures leave no tap, active audio session, or partially attached graph behind.
- Introduce a small audio-graph seam/fake so these transitions are covered without requiring live hardware.
