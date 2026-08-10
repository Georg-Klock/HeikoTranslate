# issue #73 — Output-substance thresholds are measured in characters and are not comparable across scripts

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T23:16:10Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/73

---

## Summary
`TurnLogic` decides whether a session produced a real translation or a false start by counting **characters**:

- `minDecisiveHomeOutput = 8` — absolute floor
- `homeOutputRatioFloor = 0.4` — home output as a fraction of the partner echo

Both constants were calibrated on German against English (the comments cite measurements from 2026-07-29). Character counts carry very different amounts of meaning in the scripts the app already ships.

## Why this is a current issue, not only a future one
Chinese is already an offered language. Eight characters of German is one short word; eight characters of Chinese is a substantial clause. The same constant therefore encodes a much stricter test in one language than another, in a decision that determines which side of the conversation a turn lands on.

The ratio floor has the same problem in the other direction: a Chinese translation of an English sentence is legitimately much shorter than its source, so a genuine translation can score below 0.4 on length alone.

This is closely related to #38 and to the direction failures in #45.

## Proposal
Replace raw character counts with a per-script normalisation — a weight per language, or a measure less sensitive to script density (word count, or characters normalised by a per-language factor established by measurement rather than estimate).

Whatever is chosen should be **derived from replay measurement**, as the original constants were, not assumed.

## Verification
- L1 coverage per script, in the style of L1.22/L1.26/L1.41, so each language's floor is pinned by a test rather than by one shared number.
- L3 replays for at least one non-Latin pair before and after, to confirm the change moves the measured direction-accuracy figure.

## Dependency
This should land **before** any additional script is added (#67-series language work). Devanagari and Cyrillic would each add another calibration to a constant that currently assumes one.

---

### Georg-Klock — 2026-08-08T17:36:49Z

**Merged #38 into this issue** (triage, 2026-08-08). Same problem stated twice; this is the broader framing, so it survives and #38 is closed.

One thing #38 carried that this issue does not name — worth folding in, because a fix that misses it is incomplete:

> `TurnLogic.minCorroboratedHomeOutput` (**5**) is a third character-counted constant with the same flaw, alongside `minDecisiveHomeOutput` (8) and `homeOutputRatioFloor` (0.4).

And #38's calibration evidence, which is the concrete case for why these are German-shaped numbers:

> Both were calibrated against German output: the false start `"Ich"` (3 characters) and the measured real translation `"14 Euro"` (7).

#38's framing was also more careful about scope than "future problem": home is user-selectable, `LanguageSettingsSheet` offers all six on the home wheel, and **L1.29e pins that**. So the assumption is already reachable by a user today, not only after new languages ship.

So the full set to fix is **three** constants, not two.
