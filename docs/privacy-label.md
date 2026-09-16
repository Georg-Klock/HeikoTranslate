# App Privacy "nutrition label" — the answers, and why they are true

The label Apple asks for in App Store Connect, mapped to what the app
actually does (GitHub #24). Every claim cites the mechanism that makes it
true. Reviewed the way a careful reader would: each Apple question, the
answer, the code-level fact behind it, and the edge that could make it
false. **This document is engineering's truthful account for Georg's
submission — it is not legal advice, and the submitting party owns the
final answers.**

## The app's data flows, exhaustively

1. **Microphone audio** is streamed to Google's Gemini Live API for
   translation while the mic is open, over TLS. Two sessions per
   conversation (one per language). No audio is stored by the app.
2. **Transcripts** (both sides) are rendered on screen and written to a
   diagnostic log **on the device only** (`Documents/`, 4 MB cap, five
   runs). Since 2026-08-12 there is **no code path that transmits the log
   automatically** — the automatic-upload feature was deleted (#8). The
   log leaves the phone only when a human sends it: the in-app share row,
   or the USB cable.
3. **Settings** (language pair, text size) live in UserDefaults, on
   device.
4. **Usage counters** (audio token totals, for cost estimation) live in
   UserDefaults, on device. The UI showing them was removed (#7); the
   counters remain local.
5. **No accounts, no analytics SDK, no ads, no tracking identifiers, no
   third-party SDKs beyond Apple's frameworks.** The only network peer the
   app's own traffic reaches is the Gemini API endpoint.
6. **On-device speech recognition** (iOS 26+, #135) listens to the same
   microphone audio during a translation, only to check which language was
   spoken. It runs on the phone — Apple's `SpeechTranscriber` has no server
   mode, and L1.120/120b fail the build on a server-capable recognition API.
   Its audio never leaves the phone; what it produces is written only to the
   on-device diagnostic log of item 2. A missing speech model may be
   downloaded from Apple once, by the OS at the app's request, and only on a
   network known to be unmetered (Wi-Fi, not Low Data Mode); that download
   carries no user audio or text.

## The label answers

| Apple's question | Answer | Why it is true |
|---|---|---|
| Data used to track you | **None** | No identifiers, no ad/analytics SDKs, one first-party API peer |
| Data linked to you | **None** | No accounts; the API is keyed by the developer's key, not a user identity |
| Data not linked to you — **Audio Data** | **Collected: App Functionality** | Mic audio is processed by the Gemini API to produce the translation; that processing is the product |
| Data not linked to you — anything else | **None** | Transcripts/settings/counters never leave the device by any automatic path (#8) |

## The two disclosures that must accompany the label

- **Third-party processing:** speech is processed by Google's Gemini API.
  Google's free-tier terms permit use of submitted content for service
  improvement — the privacy policy already states this caveat, and the
  label's "Audio Data / App Functionality" row is what it maps to. If the
  app moves to a paid tier with different terms, revisit this row.
- **Ephemerality claim:** the app stores nothing off the device. True by
  construction since #8's removal; the policy and this file must change
  the same day that ever changes.

## Edges checked, lawyer-style

- *Could any build configuration re-enable automatic upload?* No — the
  code is deleted, not switched off. A future PR reintroducing it must
  change the policy, this file, and the label together (#8's record says
  so).
- *Does the manual share count as "collection"?* No — user-initiated
  sharing via the system share sheet is the user's own transmission, not
  app collection, under Apple's definitions.
- *Does on-device speech recognition "collect" Audio Data?* No — Apple
  defines collection as transmitting data off the device. The recognizer's
  audio and text stay on the phone (item 6), so the Audio Data row is
  unchanged and still describes Gemini alone. A change that let recognition
  leave the device would have to change the policy, this file and the label
  together.
- *Does the speech-model download send user data?* No — it is the OS
  fetching Apple's model for a locale, the same assets system dictation
  uses; it carries no audio and no transcript.
- *Do crash logs leak transcripts?* The system crash reporter captures
  stack traces, not the app's log file contents.
- *Is the developer's API key "user data"?* No — it identifies the
  developer's account, ships in the app bundle, and is a #9 risk item,
  not a privacy-label item.
