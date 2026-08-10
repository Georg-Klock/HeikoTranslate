# issue #28 — UI/view-model small fixes: stale resume flag, ignored .shouldResume, tint keyed to German copy, stale CostSheet comment

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-04T20:02:56Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/28

---

## Summary
Four small verified-or-plausible issues, bundled:

1. **Warning tint is keyed to the German copy** (`ContentView.swift:146`): `warning.hasPrefix("Schlechte") ? .orange : .red`. Reword the string in `ConversationViewModel` and the degraded-connection warning silently turns red. The view model should publish the `ConnectionQuality` enum (or a severity) alongside the text; copy must not be a control channel. *(Verified.)*
2. **`CostSheet.swift:3` comment is false**: claims the sheet is "reached by tapping the version number… deliberately not discoverable", but it is presented from the visible **Nutzung** row in `LanguageSettingsSheet`. If discoverability still matters, that is a design decision to revisit; either way the comment lies to the next reader. *(Verified.)*
3. **Stale `resumeWhenActive`**: suspected path where the flag set by a system interruption survives a manual state change and auto-restarts listening the user believes they stopped. Needs a trace through `scenePhase`/interruption handlers; pin with a test or a documented invariant on who clears the flag. *(Plausible, unverified.)*
4. **Interruption-ended handling ignores `AVAudioSession`'s `.shouldResume` option** — the app resumes on its own policy where iOS explicitly signals whether resuming is appropriate (e.g. after a phone call vs. Siri). Worth honouring the hint. *(Plausible, unverified.)*

## Severity
**Low.** (1) and (2) are five-minute fixes; (3) and (4) are an hour with the interruption matrix in front of you.
