# pull #91 — Log both session transcripts at commit

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-08T21:45:04Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/91

---

Fixes #81

## What changed
- Logs one stable, full input-transcript snapshot for both active sessions immediately after each successful turn commit.
- Keeps empty session transcripts visible and escapes quotes, backslashes, and line breaks so a transcript cannot split or forge diagnostic-log lines.
- Adds L1.54/L1.54b against the real live service and documents the diagnostic contract.

## Why
A remote log can now distinguish a transcript-selection failure (the sessions disagreed) from a shared audio/model mistranscription (they agreed on the same wrong text). This unblocks evidence-based work on #80 and #85 without changing audio, selection, or user-visible behavior.

## Validation
- `xcodegen generate`
- `xcodebuild test -project HeikoTranslate.xcodeproj -scheme HeikoTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet` — passed (92 XCTest cases)
- `git diff --check`

L3 was not run: this is a diagnostic-only change and no device deployment was performed.
