# issue #48 — Five of the six UI languages have never been read by a speaker

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T20:23:51Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/48

---

## What

Every string Heiko can see now follows the **home** language (the right-hand bubble), so the app has six full string sets in `HeikoTranslate/UIStrings.swift`: German, English, Spanish, French, Korean, Chinese.

Only **German** has been reviewed by a human. `Tests/GermanUITests.swift` (L1.43) pins the German wording so it cannot drift unnoticed, and L1.44 proves the other five are *complete* and *not still German* — but "not German" is a very long way from "correct". Every non-German string was written by Claude and shipped unread.

## Why it matters

The whole point of the language switch is that someone who reads no German can pick up the phone and use it. If the Spanish is stilted or the Korean is wrong, that person gets a worse experience than the German speaker the app was built for — and nobody currently in the loop would know.

Low urgency: German and English cover the trip. This is a debt to pay before anyone else actually uses it.

## One known defect, already visible

The two column descriptors are grammatically inconsistent across languages, and this one is Claude's error rather than a translation subtlety:

- Korean uses **noun phrases**
- Chinese uses **verb phrases**

They should match in kind, whatever kind is right for each language.

## Also pending

`sendLogSubtitleFormat` is new German copy — "Falls etwas nicht klappt · 2.3.40" — introduced with the settings refinements. It is pinned by L1.43 but has not had Georg's eye yet.

## Done when

A speaker of each language has read that language's set, and the ko/zh descriptor grammar agrees.
