# issue #6 — LanguageSettingsSheet and CostSheet re-export the full diagnostic log on every SwiftUI body evaluation

- **State:** closed
- **Opened by:** jctoledo on 2026-08-01T23:52:39Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/6

---

## Summary
Both `LanguageSettingsSheet.body` and `CostSheet.body` call `DiagnosticLog.shared.exportedFile()` directly inside the view's `body` computed property. `exportedFile()` calls `exportText()`, which calls `flush()` (a blocking `queue.sync` against the diagnostic log's serial dispatch queue) and then reads and concatenates up to 5 on-disk log files (up to 4 MB each) and writes the result back out to a temp file — all synchronously, on the main thread, every single time SwiftUI re-invokes `body`. Since both sheets observe `@Published`/`@ObservedObject` state that changes frequently while the sheet is open (language-wheel selection via `viewModel.homeLang`/`partnerLang`, `CostTracker`'s published token counts while a conversation is ongoing), `body` — and therefore this disk I/O — can re-run many times during a single settings interaction.

## Location
`HeikoTranslate/LanguageSettingsSheet.swift`, around line 130: `if let log = DiagnosticLog.shared.exportedFile() { ... }` inside `body`.
`HeikoTranslate/CostSheet.swift`, around line 54: same pattern.
`HeikoTranslate/Services/DiagnosticLog.swift`, `flush()`/`exportedFile()`/`exportText()` (around lines 112-140).

## Failure scenario
User opens Settings mid-conversation and scrolls the language wheel a few times to browse options. Each selection change publishes through `viewModel.homeLang`/`partnerLang`, re-invoking `LanguageSettingsSheet.body`, which re-runs the full export-and-flush every time — main-thread disk I/O and a queue-synchronization wait, on a view whose entire point is a lightweight, always-responsive picker.

## Suggested fix
Compute the exported file once (e.g. on sheet appearance, via `.onAppear`/`@State`), not on every `body` evaluation — or better, do the export lazily only when the `ShareLink`/`Button` is actually pressed, since the file's only consumer is the share action.

## Severity
**Low-Medium** — a performance/jank issue, not a correctness one, but it directly contradicts the project's "simplicity beats features, impossible to get wrong" ethos for a non-technical single user who will notice UI stutter.

*Found via code review (verified by direct reading of both view bodies and the DiagnosticLog implementation).*
