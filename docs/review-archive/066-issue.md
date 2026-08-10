# issue #66 — Cover Korean and Chinese in the language-pair invariant test

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:41:10Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/66

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `Tests/LanguagePairTests.swift:321-335`
- `HeikoTranslate/Models/TurnLogic.swift` (defines the selectable `Lang.allCases` set)
- `HeikoTranslate/LanguageSettingsSheet.swift:97-100` (uses all selectable languages)

## What's wrong

`testL1_29e_pairIsAlwaysTwoDistinctLanguages` claims to verify the pair invariant whichever wheel moves, but loops only over `de`, `en`, `es`, and `fr`. The picker exposes `ko` and `zh` as selectable languages, and neither direction is exercised by this test.

## Why it matters — minor

The current implementation is likely uniform, but the test does not cover the complete product state space it claims to cover. A future special case or ordering change for Korean/Chinese could violate the distinct-pair invariant while L1 remains green.

## Suggested fix

Drive the test from the source of truth rather than maintaining a partial hand-written list:

```swift
for lang in TurnLogic.Lang.allCases {
    let (vm, _) = makeViewModel()
    vm.partnerLang = lang
    XCTAssertNotEqual(vm.homeLang, vm.partnerLang)

    let (vm2, _) = makeViewModel()
    vm2.homeLang = lang
    XCTAssertNotEqual(vm2.homeLang, vm2.partnerLang)
}
```

## Acceptance checks

- The test runs all six current selectable languages on both home and partner changes.
- Adding a future `Lang` case automatically expands this invariant coverage.
- L1 continues to assert that the two active sessions can never target the same language.
