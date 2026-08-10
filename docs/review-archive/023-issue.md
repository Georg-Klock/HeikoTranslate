# issue #23 — TurnLogic.homeIsRealTranslation: the codes-corroboration bypass is unreachable whenever the partner session echoes

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-04T20:01:58Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/23

---

## Summary
`TurnLogic.swift`, `homeIsRealTranslation`:

```swift
let partnerCount = text(partner).count
if partnerCount > 0 {
    return Double(homeText.count) / Double(partnerCount) >= homeOutputRatioFloor
}
if let spoken = spokenLang, spoken != home { return true }   // ← unreachable if echo present
```

The early `return` on the ratio branch means the settled-codes bypass — added so short outputs like "14 Euro" stop being swallowed (L1.26) — only runs when the partner session produced **nothing**. But an echo from the partner session is the *common* case for foreign speech (the codebase documents this extensively). Whenever there is an echo, the decision is ratio-only, and the corroboration that codes settled foreign can never rescue it.

## Concrete failure
Foreign speaker says a short thing verbosely echoed: home translation "14 Euro bitte" (13 chars) vs a partner echo of the full spoken sentence (~40 chars) → ratio ≈ 0.33 → below the floor → turn swallowed, **even though the language codes are unanimously settled foreign**. Same family as the device bug that motivated L1.26 — the fix just doesn't cover the echo half of the space, and L1.26 as written appears to test only the `partnerCount == 0` path.

## Suggested fix
Decide the intended semantics and make the ratio and corroboration branches compose rather than shadow: e.g. pass the floor **or** (codes settled non-home **and** homeText ≥ a small absolute minimum). Then extend L1.26 with the echo-present variant so the ordering can never silently regress.

## Severity
**Medium-high** — live translation quality on short utterances, the exact class of failure Georg kept hitting on device.
