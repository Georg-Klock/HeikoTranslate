# issue #63 — Make L3 replay fail on unrecognized Gemini server frames

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:40:58Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/63

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `HeikoTranslate/Services/GeminiLiveSession.swift:221-325`
- `Tools/l3replay/main.swift:88, 230-233, 350-355, 390-408`

## What's wrong

`GeminiLiveSession` deliberately surfaces unknown or malformed server message shapes as `.raw(...)` so protocol drift is visible. The L3 replay runner records those frames in `rawMessages`, but at the end it only prints a warning. It never calls `check`, increments `totalFailed`, or returns nonzero. The release L3 gate can therefore pass while the production parser has discarded a new Gemini response shape.

## Why it matters — moderate

L3 is the live final verification of the API contract. Treating a parser mismatch as success defeats the reason the raw-frame path exists and lets protocol drift reach users without blocking release.

## Suggested fix

Make nonempty raw messages a failed assertion by default:

```swift
check(runner.rawMessages.isEmpty,
      "no unrecognized server messages" +
      (runner.rawMessages.isEmpty ? "" :
       ": \(runner.rawMessages[0].prefix(200))"))
```

If there is a known benign frame that needs investigation, use a narrowly scoped, explicit allowlist or an opt-in diagnostic flag such as `L3_ALLOW_RAW=1`; it must not silently make a normal release gate green.

## Acceptance checks

- A synthetic replay runner containing one `.raw` event exits nonzero.
- Known supported frames continue to pass.
- The failure output includes a bounded sample of the unexpected frame for diagnosis.
