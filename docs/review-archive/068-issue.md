# issue #68 — App Privacy nutrition labels must be completed, and must match what the app actually does

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T23:08:08Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/68

---

## Summary
A public App Store listing requires **App Privacy** ("nutrition label") answers, which appear on the product page before anyone installs. TestFlight never asked for these, so they do not exist yet.

## What has to be declared
The app streams microphone audio to the Google Gemini API for translation. At minimum:

- **Audio Data** — collected, linked to the user? No. Used for tracking? No. Purpose: App Functionality.
- **Third-party disclosure** — the audio leaves the device to a third party (Google), and on the **free tier Google may use submitted data to improve its products**. That is materially different from "processed and discarded", and the label must not imply otherwise.
- The privacy policy URL is already live at `www.georgklock.com/heiko-translate-privacy` and says this plainly, so the label needs to agree with it rather than soften it.

## Why it needs care rather than a form-fill
`PrivacyInfo.xcprivacy` already declares required-reason APIs and *no tracking*, which is accurate. The nutrition label is a different, more public artifact, and a mismatch between it, the privacy policy and `PrivacyInfo.xcprivacy` is exactly the kind of inconsistency App Review notices.

There is also a **dependency on #52**: while automatic diagnostic transcript upload exists with no consent mechanism, the honest label is harder to write — the transcripts include the other speaker's words. Settle #52 first, then declare.

*Filed from the 2026-08-07 App Store readiness review.*
