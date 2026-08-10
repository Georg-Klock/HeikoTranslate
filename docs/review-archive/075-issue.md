# issue #75 — Direction resolution needs a strategy for closely related language pairs

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-07T23:16:47Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/75

---

## Summary
The app decides which side of the conversation a turn belongs to primarily from which session translated substantially, with detected language codes acting as a veto. Two measurements show this is unreliable when the spoken language closely resembles another:

- **#45** — German transcribed as Swedish/Danish (`language code sv`, `language code da`), so home speech was translated as foreign and placed on the left. Observed on device, build 2.3.39.
- **de↔es** — German spoken immediately after Spanish is attributed to the wrong side in roughly half of L3 replays, with turn boundaries otherwise clean.

## What has been ruled out
A third "referee" session was implemented and measured on branch `feat/de-es-referee-session` (unmerged, deliberately). The hypothesis was that the session whose target matches the spoken language contributes an unreliable vote, leaving a 1–1 tie that a neutral third voter could break.

Measurement did not support it: 6/10 correct against a 5/10 baseline, and the verbose codes show why —

```
es:de@11.7s  referee:de  de:de@11.8s  de:de@12.9s  es:de@12.9s  referee:de
```

All sessions report `de`, correctly. There is no tie to break, so additional voters cannot change the outcome. The branch is kept so the result is reproducible.

## What this implies
Since the codes are correct in the failing case, the misattribution is in **direction resolution**, not in the language vote. The likely site is the home-silence confirmation path: with codes settled on the home language, `homeSpoken` requires `homeSilenceConfirmDelay` (1.2s) of home-session quiet while the partner translates. Any output from the home session during that window — a false start or an echo fragment — fails the confirmation and the turn resolves as foreign.

That is the same machinery as `homeIsRealTranslation` and the thresholds in #73.

## Suggested next step
Instrument the confirmation window on a failing replay: what the home session emitted, and when, between the start of the turn and the resolution. That distinguishes "the confirmation window is too short" from "an echo fragment is being counted as a translation", which imply different fixes.

## Relevance to language expansion
This should be understood before Russian and Ukrainian are offered as a pair (#74), since they present the same similarity that produced #45.
