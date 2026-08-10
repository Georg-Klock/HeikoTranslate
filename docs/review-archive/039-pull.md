# pull #39 — A denied microphone recovers when Settings grants it (#25)

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-05T20:43:45Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/39

---

Fixes #25. **Split out of #37** on that PR's review: this half is unrelated to the #23 threshold argument, was called clean and independently mergeable, and should not sit behind it. Based on current `main` (`408e886`), so no rebase needed.

L1 **66/66**.

## The denial never cleared

Nothing set `micPermissionDenied` back to false. Recovery depended entirely on iOS terminating the app when the microphone switch is toggled — which it usually does, but that was an undocumented dependency, and it misses the case that matters:

> Heiko opens Settings, does not understand it, backs out.

The one button was then a Settings shortcut forever, unable to start listening again. That is a permanent R8 violation for the app's most likely first-run failure, hitting the user least able to recover from it.

## The fix

`handleScenePhase(.active)` now re-reads `AVAudioApplication.shared.recordPermission` — free, and does not prompt — and folds it in through `noteMicPermission(granted:)`.

That method is **split out of the scene handler on purpose**: the branch was unreachable from a test before, which is exactly how it shipped unexercised — #30 said as much in its own description. `errorMessage` clears with the flag, or the start hint stays suppressed (L1.32) and the screen is simply blank.

## Tests

**L1.42** covers the sequence: denied → back from Settings still refused (nothing changes) → back from Settings granted (flag clears, error clears, "Zum Sprechen antippen" returns).

Two things the review of #37 raised, checked here:

- **The DEBUG helper cannot leak.** `forceMicPermissionDeniedForTesting()` is inside `#if DEBUG` and shipping builds are Release. Verified rather than asserted: `xcodebuild -configuration Release` builds clean, which it could not if shipping code referenced the helper.
- **`AVAudioApplication.shared.recordPermission` is available.** Deployment target is iOS 17.0.

## Known limit, stated rather than papered over

The `.active` scene-phase read itself is **not** covered by L1 — it needs a real permission state a test cannot set. What L1 covers is the decision the read feeds. TESTING.md says so in those terms rather than implying the whole path is tested.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
