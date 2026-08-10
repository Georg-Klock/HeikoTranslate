# issue #5 — GermanUITests' golden-inventory scan has a blind spot for Text(String(format:...)) — a live string is unchecked

- **State:** closed
- **Opened by:** jctoledo on 2026-08-01T23:52:37Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/5

---

## Summary
`Tests/GermanUITests.swift`'s whole purpose (per its own doc comment) is to make sure every user-visible string Heiko can see is inventoried and reviewed as German — "any new or edited string fails here until a human looks at it." Its `userFacingStrings(in:)` regex only matches a string literal that appears *directly* after `Text(`/`Label(`/etc. It misses `LanguageSettingsSheet.swift`'s `Text(String(format: "%.0f Min gehört · %.0f Min gesprochen", ...))`, because `Text(` here is followed by `String(`, not a quote. That string is also absent from `reviewedStrings`. The test currently passes only because that particular string happens to already be German — a future accidental English (or malformed) string introduced through the same `Text(String(format:...))` shape would silently pass this test with zero warning, defeating the test's stated guarantee.

## Location
`Tests/GermanUITests.swift`, `userFacingStrings(in:)` (around lines 61-77) and `reviewedStrings` (around lines 25-51).

`HeikoTranslate/LanguageSettingsSheet.swift`, around line 161 — the string that currently evades the scan:
```swift
Text(String(format: "%.0f Min gehört · %.0f Min gesprochen",
            tracker.audioMinutesIn, tracker.audioMinutesOut))
```

## Verified
Confirmed by direct trace: the regex `(?:Text|Label|Button|TextField|navigationTitle|accessibilityLabel)\(\s*"..."` requires the literal immediately after the call's opening paren. `viewModelStrings()` only scans `ConversationViewModel.swift`, so it provides no second line of defense for `LanguageSettingsSheet.swift`. No other mechanism in the test suite covers this call shape. It is currently the only instance of this exact pattern in the three scanned files, but the shape itself — any function call wrapped inside `Text(...)` — is exactly the kind of code a future edit is likely to reintroduce.

## Suggested fix
Either widen the regex to also match one level of nested `String(format: "...")`/similar wrapper calls, or add an explicit assertion enumerating known call shapes the scanner must catch, or simplest: add the literal to a small, explicitly-commented "hand-reviewed, scanner doesn't reach this" list that the test cross-checks against actual call sites so a genuinely new nested string can't slip through silently.

## Severity
**Medium** — not a shipping-today bug (the current string is correct German), but a silent gap in the one guardrail this project built specifically because a wrong-language string once shipped undetected (see the test's own doc comment referencing the 2026-07-30 incident).

*Found via code review; independently re-verified before filing, including confirming no other instance of the blind spot exists elsewhere in the scanned files today.*
