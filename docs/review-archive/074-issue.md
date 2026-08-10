# issue #74 — Expand translation coverage for a California audience: Tagalog and Vietnamese first

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T23:16:45Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/74

---

## Goal
Make the app usable by visitors who do not speak any currently supported language, so that a public build can actually be tried by the people around it.

## Current coverage against the target audience
Supported today: German, English, Spanish, French, Korean, Chinese.

California's most-spoken languages after English, by speakers at home:

| Language | Approx. speakers | Supported |
|---|---|---|
| Spanish | ~10.5M | ✅ |
| Tagalog | ~646k | ❌ |
| Chinese | ~641k | ✅ |
| Vietnamese | ~556k | ✅ ❌ |
| Korean | ~370k | ✅ |

**Tagalog and Vietnamese are the two gaps in the top five**, and Tagalog has recently overtaken Chinese for second place. Adding them covers roughly 1.2M additional speakers in California alone.

Hindi, Russian and Ukrainian were also proposed. They are outside the state top five, though Russian and Ukrainian have a genuine regional concentration — the Sacramento area has one of the largest Slavic communities in the United States — so they are reasonable second-wave candidates rather than first.

## Suggested order
1. **Tagalog, Vietnamese** — largest coverage gain per language.
2. **Russian** — meaningful nationally and regionally concentrated near the Bay Area.
3. **Hindi, Ukrainian** — smaller populations; Ukrainian additionally carries the pairing risk below.

## Prerequisites
- **#72** (separate translation targets from interface languages) — otherwise each addition also adds an unreviewed interface string set, compounding #48.
- **#73** (script-aware output thresholds) — Devanagari and Cyrillic each add a script to a threshold that currently assumes one.
- **Target support must be verified, not assumed.** Every current language was confirmed against the live model by a target probe (SPEC records the 2026-07-28 run). #65 tracks restoring `Tools/targetprobe.sh`; that should run for each candidate before it is offered.

## Known risk: mutually intelligible pairs
Russian and Ukrainian are closely related, as are Hindi and Urdu. #45 documents German being transcribed as Swedish and landing on the wrong side of the conversation — the same failure mode. A Russian↔Ukrainian pair should be measured explicitly via L3 before being offered, rather than assumed to work because each language works separately.

## Sources
- [Axios San Francisco — Tagalog tops California languages after English and Spanish](https://www.axios.com/local/san-francisco/2025/06/11/tagalog-tops-california-languages-after-english-and-spanish)
- [California Immigrant Data Portal — Languages Spoken](https://www.immigrantdataca.org/indicators/languages-spoken)
