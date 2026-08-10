# issue #59 — Do not forward mic audio to a replacement session before its new setup completes

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:39:20Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/59

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:462-475`
- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:590-620`
- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:651-666`
- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:770-783`
- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:311-320`

## What's wrong

`readySessions` is the documented setup-complete gate. On a post-handshake `.closed` (including the expected `goAway` renewal path), `reconnect(_:) ` replaces the session without removing that language from `readySessions`; it also does not add it to `dead`. `isSendingAudio` stays true, and the mic/tail-buffer loops send to every non-dead session.

As a result, the brand-new WebSocket receives `realtimeInput` before its own `.setupComplete`, precisely the premature-audio state that the code comments say must be prevented. This happens after every session renewal, not only on a rare first connection.

## Why it matters — moderate

The new session can reject or drop audio while it is still negotiating setup. That creates a mid-conversation speech loss or protocol failure during normal long-running use.

## Suggested fix

Clear readiness before replacing any session, and make the sending path test readiness rather than merely absence from `dead`. Preserve a bounded per-language queue for chunks captured while that replacement is not ready, then flush that language only after its new `.setupComplete`.

For example, the replacement path must do the equivalent of:

```swift
readySessions.remove(lang)
sessions[lang]?.close()
let replacement = makeSession(lang, apiKey: AppConfig.geminiAPIKey)
sessions[lang] = replacement
replacement.connect()
```

Then both live forwarding and pending flushing should select `readySessions.contains(lang)`, not `!dead.contains(lang)`.

## Acceptance checks

- A fake session that emits `.closed(expected: true)` is replaced, but receives no audio before its own `.setupComplete`.
- Chunks captured during that window are either explicitly and safely queued per language or intentionally documented as dropped; they must not be sent early.
- After the new setup completes, queued chunks are sent once and normal live forwarding resumes.
- Cover both expected goAway renewal and abrupt-drop reconnect paths.
