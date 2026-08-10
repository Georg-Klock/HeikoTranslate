# issue #56 — Preserve system Dynamic Type unless the user explicitly chooses an app override

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:39:05Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/56

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `HeikoTranslate/HeikoTranslateApp.swift:25-31`
- `HeikoTranslate/LanguageSettingsSheet.swift:341-345, 440-445`
- `HeikoTranslate/ChatBubbleShape.swift:90-99`

## What's wrong

An untouched install uses `TextSize.defaultStep == 3` (`.large`) and applies `.dynamicTypeSize(.large)` at the app root. That replaces the operating system Dynamic Type environment for every descendant. A user who has selected an accessibility text size in iOS is silently forced back to the app’s fixed default until they discover and operate the custom slider. The custom range also stops at `.xxxLarge`, omitting the larger accessibility categories.

The same forced size is reapplied by the settings sheet, so it is not limited to one screen.

## Why it matters — moderate

Text size is a core accessibility accommodation, especially for reading the live transcript. Overriding it at launch makes the app less usable for the people who already need large text and violates the expectation that an untouched app honors the system setting.

## Suggested fix

Make “use system text size” the default state and apply an app override only after an explicit user choice. A sentinel or optional persisted value keeps this simple:

```swift
enum TextSize {
    static let system = -1

    static func override(for step: Int) -> DynamicTypeSize? {
        guard steps.indices.contains(step) else { return nil }
        return steps[step]
    }
}

@AppStorage(TextSize.key) private var textSizeStep = TextSize.system
```

Use a small view modifier that applies `.dynamicTypeSize` only when `override(for:)` returns a value; otherwise leave the inherited system environment untouched. Add a visible “Use system text size”/reset choice in settings. Apply the same logic to the presentation sheet rather than forcing it to a fixed size.

## Acceptance checks

- On a fresh install, an iOS accessibility Dynamic Type setting reaches the transcript and settings sheet unchanged.
- Selecting an explicit in-app size applies a deliberate override and survives relaunch.
- Resetting to system size removes the override.
- Add UI/snapshot coverage for a large accessibility category and for the custom-override path.
