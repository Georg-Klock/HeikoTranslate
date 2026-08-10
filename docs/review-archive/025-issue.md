# issue #25 — Microphone permission denial leaves two contradictory instructions on screen, permanently

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-04T20:02:52Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/25

---

## Summary
`ConversationViewModel.beginListening()`:

```swift
guard granted else {
    errorMessage = "Bitte erlaube Mikrofonzugriff in den Einstellungen."
    return
}
hasEverStarted = true      // ← only reached on grant
```

On denial, `hasEverStarted` stays `false`, so `startHint` — `"Zum Sprechen antippen"`, shown whenever `!isListening && !hasEverStarted && !isLaunching` — remains on screen **next to** the error telling the user the tap will not work without a Settings change. Two instructions, one contradicting the other, and the state is permanent: iOS only prompts once, so every further tap re-runs the denied path.

## Why this one matters more than its size
This is the most likely first-run failure for the app's actual user — a non-technical German speaker who taps "nicht erlauben" once. SPEC R8's own language: never sit in a state where the obvious action does nothing; recover, or say so. The screen currently says both "tap to speak" and "tapping will not help".

## Suggested fix
Denial is a first-class state, not a transient error: suppress `startHint` while the mic-permission error is active (one condition), and consider making the button itself open `UIApplication.openSettingsURLString` in that state — for this user, "tap the same button again" is far more plausible than finding Einstellungen → Apps → Heiko Translate → Mikrofon unaided. New German copy, if any, goes through the `GermanUITests` inventory.

## Severity
**Medium** — trivial fix, but it is the app's worst first impression and its target user is the person least equipped to recover from it.
