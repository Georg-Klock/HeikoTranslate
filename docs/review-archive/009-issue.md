# issue #9 — No notice or consent mechanism for the conversation partner whose speech is sent to Google and retained on-device

- **State:** closed
- **Opened by:** jctoledo on 2026-08-02T00:01:13Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/9

---

## Summary
The privacy policy (`docs/privacy-policy.md`) is written for, and only ever seen by, **Heiko** — it's linked from App Store Connect/TestFlight metadata, external to the app itself. But every conversation involves a **second person** who never sees that policy, never installed the app, and by the product's own design (SPEC §2: "it may lie on a table between two people") may not even be looking at the phone. That second person's voice is nonetheless: (1) streamed live to Google's Gemini API for transcription/translation, and (2) written verbatim (truncated to 60 chars) into an on-device log that persists across multiple conversations and can be shared off the phone at any time by Heiko — all with no notice to them at all.

## What's actually happening, with evidence

1. **Every utterance from either party is sent to Google.** This is inherent to how the app works (not optional), and is honestly disclosed in the privacy policy — but only to Heiko.

2. **The on-device diagnostic log stores verbatim conversation content from both speakers, unconditionally**, regardless of whether the (opt-in, off-by-default) `DIAGNOSTIC_UPLOAD_URL` auto-upload feature is ever configured:

   `HeikoTranslate/Services/GeminiLiveTranslationService.swift:977`
   ```swift
   diag("turn", "commit \(bubble.isHome ? "RIGHT/home" : "LEFT/foreign") via \(turn.translator?.rawValue ?? "?") | \(bubble.original.prefix(60)) → \(bubble.translation.prefix(60))")
   ```
   `bubble.original`/`bubble.translation` are the actual spoken words of *whichever* party spoke that turn — including the counterpart's. This is written to `Documents/heiko-diagnostics.log` on the device (`TESTING.md`: "written every launch," 4MB cap, previous run kept as `.log.1`), independent of the upload switch.

3. **The project is already aware of this exact tension for the upload feature** — `HeikoTranslate/Services/AppConfig.swift`'s own comment on `diagnosticUploadURL` says: *"Heiko's log contains the transcript of every conversation he has — his words and the words of whoever he was talking to. Set `DIAGNOSTIC_UPLOAD_URL`... only after telling Heiko the app does this."* That awareness stops at the upload boundary — it doesn't extend to the fact the same third-party transcript content is already retained **on-device**, or that the base Gemini transmission (required for the app to function at all) has no in-app disclosure to the second speaker either.

4. **Nothing in the UI itself indicates to a bystander that the conversation is being processed by a cloud AI service.** The one-button, minimal-UI design (deliberately, per SPEC) has no equivalent of "this call may be recorded" — no icon, no line of text, nothing a person glancing at the screen (or having the phone lie on the table facing them) would see.

## Why this is worth a deliberate decision, not just a code fix
I'm not asserting a specific legal conclusion — that genuinely depends on jurisdiction (many places, including Germany, have rules around recording/processing another person's spoken words without their knowledge; whether live transcription without persistent recording counts, and whether visible use of a translation app implies some form of consent, is disputed and fact-specific). What's unambiguous is the **product gap**: right now there is no mechanism at all — UI, verbal, or otherwise — through which the second party is ever told their voice is leaving the device, and their words are retained (in the diagnostic log) longer and more durably than a live conversation would suggest.

## Suggested directions (for you to weigh, not a prescription)
- A small, persistent on-screen indicator while listening/translating that makes the "this is processed by an AI translation service" fact visible to *both* people looking at the screen, not just describable in a policy page only Heiko ever opens.
- Consider whether the diagnostic log's transcript content needs the same explicit-disclosure treatment `AppConfig.swift` already gives the upload feature, even though it's on-device-only — e.g. a shorter retention window, or truncating/redacting the log's turn-commit line further than the current 60-char preview.
- None of this needs to fight the "simplicity beats features" ethos — a single small, unobtrusive, always-present visual cue would do it without adding any interaction.

## Severity
**Medium** — no code defect, but a real gap between what the app actually does (send a third party's voice to a cloud service and retain their words on-device) and what that third party has any way of knowing, raised because the project has otherwise been unusually careful about exactly this kind of thing for Heiko himself.

*Raised during code review at the user's request; grounded in the specific `diag()` call and `AppConfig.swift` comment cited above, not speculation.*

---

### Georg-Klock — 2026-08-04T16:39:51Z

Decided (Georg, 2026-08-04): **rely on the iOS microphone indicator** rather than adding app-level disclosure UI.

The reasoning holds up. iOS shows a system-guaranteed orange dot whenever the mic is live — an app cannot suppress it, it is universally recognised, and it appears without this app having to be trusted to draw it. For a one-button app whose governing rule is *"if a choice is between more capable and impossible to get wrong, choose the latter"*, adding custom chrome to signal something the OS already signals is the wrong trade.

Recording the limits honestly, since the issue asked a narrower question than "is the mic on":

- The dot says **the microphone is active**. It does not say the audio leaves the device, reaches Google, or is retained. Someone who sees it learns less than the issue was asking to convey.
- It renders in the status bar of **Heiko's** phone. In the table-between-two-people posture this app is designed around, the partner is usually looking at Heiko rather than at the screen edge.

So the accepted position is: the OS discloses that recording is happening, the beta description and privacy policy disclose where the audio goes, and the partner relies on the visible social context of someone holding up a translator. That is a deliberate choice, not an oversight.

**Left open deliberately:** the diagnostic log still stores 60 characters of both speakers' verbatim words. Untouched here because it is a separate question — that data never leaves the phone unless shared, and reading what was actually said has repeatedly been what made a bug obvious. Worth revisiting only if `DIAGNOSTIC_UPLOAD_URL` is ever set while the public link is live, which `release.sh` now refuses outright.
