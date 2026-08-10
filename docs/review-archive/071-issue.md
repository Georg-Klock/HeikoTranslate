# issue #71 — App Store readiness: tracking issue for a DE + US launch (unlisted)

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T23:08:49Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/71

---

Umbrella for the 2026-08-07 readiness review. Georg's target: **available in DE and US, ideally unlisted** — a direct link rather than a discoverable listing.

**Assessment: not ready. One hard blocker, several gates.**

## Hard blocker
- **#53 — the Gemini API key ships inside the app bundle.** Extractable from any IPA in minutes. On TestFlight, with a capped audience, that is contained. Public distribution makes compromise a certainty, and the same key serves the public TestFlight link *and* Nonna-Phone: one extraction burns all three, and the free tier's hard $0 cap means Heiko's translator stops working mid-trip. Needs a proxy or per-install credentials — architectural, not a patch.

## Quality gates — things a stranger would hit
- **#45** — German heard as Swedish put home speech on the foreign side (observed on device 2026-08-07). Direction resolution is still the weak spot; the de↔es coin flip is the same family, and the referee experiment on #18 failed to fix it.
- **#38** — the home-output character floors are German-calibrated, so direction likely behaves differently in the languages nobody has tested.
- **#48** — five of six UI languages were written by Claude and never read by a speaker. Acceptable when the only user reads German. Not acceptable when a Spanish or Korean speaker installs it.

## Privacy and consent
- **#52** — automatic diagnostic transcript upload with no consent mechanism. The log contains *both* speakers' words.
- **#68** — App Privacy nutrition labels, which must agree with the privacy policy and `PrivacyInfo.xcprivacy`.
- Worth revisiting **#9** (closed): "rely on the iOS mic indicator" was decided for one man in a café. It is a weaker position when strangers use the app on conversations with people who never installed anything.

## Process
- **#69** — Unlisted App Distribution must be *requested*; it is not a setting. Start early; a refusal changes the plan.
- **#67** — EU DSA trader declaration, required for a DE launch, exempt on TestFlight. Blocks DE only.
- **#12** — case-study page SEO, if the marketing URL points there.

## Recommendation
**TestFlight's public link is the right venue today** and is already live. The App Store is a real possibility, but #53 alone is weeks of work done properly, and #45 means the app still sometimes attributes speech to the wrong person — the one failure a translator cannot have when the user has no way to detect it.

Sensible order: **#53 → #45/#38 → #52/#68 → #48 → #69/#67 → listing.**

---

### Georg-Klock — 2026-08-07T23:17:16Z

## Scope update — language coverage added to the launch plan

Goal restated (2026-08-07): reach the App Store as quickly as practical, limited scope acceptable, with enough language coverage that people nearby can actually try the app.

Four issues added, and the sequencing changes as a result.

- **#72** — separate translation targets from interface languages. This is the enabling change: it makes a new language cheap (one verified target) instead of expensive (a complete unreviewed interface), and stops #48 growing with every addition.
- **#73** — the output-substance thresholds are raw character counts calibrated on German. Chinese already ships and is affected, so this is a current issue rather than only a prerequisite for new scripts.
- **#74** — translation coverage for a California audience. Tagalog and Vietnamese are the two gaps in the state's top five; Russian, Hindi and Ukrainian are second-wave.
- **#75** — direction resolution for closely related language pairs, consolidating #45 and the de↔es measurements, and recording that the referee approach was measured and rejected.

## Revised order

1. **#69** — request unlisted distribution now. External latency, no dependencies, and a refusal would change the plan.
2. **#53** — the API key in the bundle. The one hard blocker for any public build, and the longest item.
3. **#73 → #75/#45** — thresholds first, then direction. Both are prerequisites for adding scripts, and both improve the app as it ships today.
4. **#72 → #74** — decouple, then add Tagalog and Vietnamese.
5. **#52, #68, #67, #70** — consent, privacy labels, DSA declaration, listing metadata.

Languages sit deliberately after the correctness work. Adding targets before #73 would multiply an already mis-calibrated threshold across more scripts, and adding them before #72 would multiply unreviewed interface strings.
