# issue #38 — The home-output character floors are German-calibrated but home is user-selectable

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-05T20:39:28Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/38

---

Split out of the review of #37, where it was a non-blocking finding. Not a live defect — Heiko's home language is German — but it is currently an unstated assumption in the code, which is the part worth fixing.

## The assumption

`TurnLogic.minDecisiveHomeOutput` (8) and `TurnLogic.minCorroboratedHomeOutput` (5) are **character counts**, and both were calibrated against German output: the false start `"Ich"` (3) and the measured real translation `"14 Euro"` (7).

But `home` is not always German. `LanguageSettingsSheet` offers all six languages on the home wheel, and L1.29e pins that. Chinese and Korean express the same content in far fewer characters, so the same floor is materially stricter there.

Transposing #23's own headline case — a 26-char English echo, codes settled foreign:

| home | plausible translation of "That'll be fourteen euros" | chars | verdict at floor 5 |
|---|---|---|---|
| `de` | `14 Euro` | 7 | accepted |
| `zh` | a natural rendering runs ~4–6 | ~4 | **rejected** |
| `ko` | `14유로` | 4 | **rejected** |

Those row lengths are illustrations, not measurements — which is rather the point. A character floor has to be measured per home language before it can be trusted as one.

The failure mode if this is wrong is the one #23 and #26 were both filed for: a silently swallowed turn, with nothing on screen to say it happened.

## Scope

Only the branch where the partner session echoed. #37's follow-up deliberately leaves the no-echo branch with no floor at all, so it is language-independent already.

## Possible directions, in rough order of appetite

1. **Measure.** Run the six home languages through `Tools/livetest.py` on a set of short real answers and record the character lengths, the way the other tuning constants in this file were derived. Then either confirm 5 travels, or make the floor per-language.
2. **Count something less language-dependent** than characters — for CJK, one character carries far more.
3. **Do nothing but say so.** Keep the constants, and keep the doc comments that now name them as German-calibrated. Defensible while Heiko is the only user.

Documented in `TurnLogic.swift` and `TESTING.md` as of the #23 follow-up, so this issue is the tracking half of an assumption that is at least no longer silent.

---

### Georg-Klock — 2026-08-08T17:36:50Z

Superseded by #73, which states the same problem in its general form (character counts are not comparable across scripts). #38's two unique contributions — the third constant `minCorroboratedHomeOutput` (5), and the German calibration evidence ("Ich" = 3, "14 Euro" = 7) — have been folded into #73 so nothing is lost. Closing as a duplicate, not as rejected: the problem is real and tracked at #73. Triage 2026-08-08.
