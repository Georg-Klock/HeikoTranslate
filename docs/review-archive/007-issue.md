# issue #7 — README.md and CLAUDE.md's ARCHITECTURE.md pointer still describe the old fixed three-session (de/en/es) design

- **State:** closed
- **Opened by:** jctoledo on 2026-08-01T23:52:41Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/7

---

## Summary
The 2026-07-28 language-pair redesign replaced the fixed three-session (de/en/es) architecture with an explicit two-session home/partner pair (confirmed in code: `GeminiLiveTranslationService.start()` sets `activePair = [home, partner]` and only ever creates sessions `for lang in [home, partner]`). Several docs weren't fully updated to match, which the project's own `CLAUDE.md` explicitly calls out as a rule to avoid: "When behavior changes, update SPEC.md / TESTING.md / ARCHITECTURE.md in the same session. Drifted docs are worse than no docs."

## Locations and specifics

1. **`README.md`, "Project layout" section (around lines 79-103)**: references `Models/ConversationPartner.swift`, which no longer exists (superseded by the pair design), describes `GeminiLiveTranslationService.swift` as "Runs the de/en/es sessions concurrently" (the old fixed design), and omits several files that exist today: `Models/FillerWords.swift`, `Services/CostTracker.swift`, `Services/DiagnosticLog.swift`, `Services/LogUploader.swift`, `LanguageSettingsSheet.swift`, `CostSheet.swift`, `ChatBubbleShape.swift`.

2. **`CLAUDE.md`**'s own "Read first" pointer describes `docs/ARCHITECTURE.md` as covering "why three concurrent sessions" — but `docs/ARCHITECTURE.md` itself now documents the three-session design as historical only (its own "## Why three concurrent sessions (historical)" section), with the current design explicitly being two sessions ("One session per side... exactly TWO sessions run").

3. **`docs/ARCHITECTURE.md` is internally inconsistent** — despite demoting three sessions to a clearly-marked historical section, its own "Turn lifecycle" (line 64: "Mic chunks... stream to all three sessions... the mic 'opens' only when **all** sessions are ready") and "Wire protocol" (line 123: "...even unanimously across all three sessions") sections — which describe *current*, actively-tested behavior (cross-referenced to L1.15–L1.18, live passing tests) — still say "three sessions" rather than "both sessions"/"the pair." Since `docs/ARCHITECTURE.md` is explicitly positioned as "current technical truth... this file wins where they disagree," a factual error inside its own non-historical sections is the highest-value fix of the three.

## Suggested fix
Update README's project layout to the current file tree and description; update CLAUDE.md's one-line description of ARCHITECTURE.md's contents; fix "three sessions"/"all three sessions" to "both sessions"/"the pair" in ARCHITECTURE.md's Turn lifecycle and Wire protocol sections (leaving the explicitly-dated historical device measurement in the Failure Handling section as-is, since it's a direct quote of a specific past observation, not a description of current behavior).

## Severity
**Low** — documentation only, no runtime impact, but exactly the kind of drift this project's own CLAUDE.md flags as actively harmful, especially for AI-assisted sessions that treat these docs as ground truth.

*Found via code review, cross-referencing README.md/CLAUDE.md/docs/ARCHITECTURE.md against the actual current source tree and `GeminiLiveTranslationService.start()`.*
