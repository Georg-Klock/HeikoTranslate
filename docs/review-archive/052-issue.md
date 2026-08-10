# issue #52 — Require explicit consent before automatic diagnostic transcript uploads

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:37:23Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/52

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `HeikoTranslate/ConversationViewModel.swift:398-409`
- `HeikoTranslate/Services/LogUploader.swift:31-56`
- `HeikoTranslate/Services/AppConfig.swift:9-27`
- `HeikoTranslate/Services/GeminiLiveTranslationService.swift:1110-1116`
- `docs/privacy-policy.md:134-139`
- `HeikoTranslate/PrivacyInfo.xcprivacy:11-29`

## What's wrong

When `DIAGNOSTIC_UPLOAD_URL` is populated, every background transition calls `LogUploader.uploadCurrentLog`. That reads the log and POSTs it automatically, with no persisted user consent, in-app disclosure, revocation control, or runtime kill switch. The log includes both sides of a conversation: the commit log line records `bubble.original` and `bubble.translation`.

The source comment asking the operator to tell Heiko is not an enforcement mechanism. It also contradicts the privacy policy, which says the app does not send the transcript/log on its own and that a log leaves only through user sharing. The privacy manifest likewise says nothing is stored off-device, despite this configured upload path.

## Why it matters — critical

A production build with that URL set can silently transmit private conversations, including speech from people who never agreed to it. The public privacy disclosure is false in that configuration, which creates a user-consent and release-compliance blocker.

## Suggested fix

Prefer removing automatic transcript upload from production entirely and retaining the existing explicit Share Sheet route. If automatic upload must remain, make it opt-in at runtime and default-off even when an endpoint is configured:

```swift
enum DiagnosticUploadConsent {
    static let key = "diagnostics.uploadConsent"

    static var isGranted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}

// First gate in LogUploader.uploadCurrentLog(reason:):
guard DiagnosticUploadConsent.isGranted else { return }
```

Add a settings control that explains exactly what is sent, when it is sent, and to whom; make revocation immediately stop future uploads. Do not treat a build-time `ALLOW_UPLOAD_URL=1` override as user consent. Update the privacy policy and App Store/privacy declarations to match the final behavior before release.

## Acceptance checks

- With a valid `DIAGNOSTIC_UPLOAD_URL` but no consent, a test URL protocol observes zero requests.
- Granting consent permits an upload; revoking it prevents the next background-triggered upload.
- The shipped disclosure accurately describes the final data flow, or automatic upload is absent from production.
- Add a release/configuration check that rejects a production automatic-upload endpoint unless the consent implementation and disclosure review are intentionally enabled.
