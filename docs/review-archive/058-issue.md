# issue #58 — Expose the custom language wheels as semantic, adjustable VoiceOver controls

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:39:16Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/58

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `HeikoTranslate/LanguageSettingsSheet.swift:76-110`
- `HeikoTranslate/LanguageSettingsSheet.swift:200-295`

## What's wrong

Each language selector is a visual `ScrollView` containing 101 repeated turns of its language rows (roughly 500+ duplicate `Text` elements). It has no `Picker`, button semantics, accessibility label/value, selected trait, or `accessibilityAdjustableAction`. The only path to change a core language pair is therefore not exposed as a meaningful control to VoiceOver; users encounter repeated labels rather than a current selection they can adjust.

## Why it matters — moderate

Language selection is a primary app function. A blind or low-vision user cannot reliably discover the selected language or change it with standard adjustable-control gestures, even though the visual wheel works.

## Suggested fix

Keep the visual wheel if desired, but expose one semantic adjustable element per column and hide the duplicated visual rows from accessibility. Its label should use the column descriptor, its value the displayed selected language, and increment/decrement should cycle through `options` while preserving the existing distinct-pair rule.

A minimal shape is:

```swift
.accessibilityElement(children: .ignore)
.accessibilityLabel(descriptor)
.accessibilityValue(displayed(selection))
.accessibilityAdjustableAction { direction in
    adjustSelection(for: direction, within: options)
}
```

Alternatively, render a native `Picker` for VoiceOver users.

## Acceptance checks

- VoiceOver exposes exactly one adjustable element for each language column.
- The element announces its descriptor and current selected language.
- Increment/decrement changes only valid options and never leaves home and partner equal.
- UI/accessibility tests cover both columns, one full option cycle, and the excluded-partner behavior.
