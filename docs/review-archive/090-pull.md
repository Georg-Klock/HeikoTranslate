# pull #90 — App Store paperwork drafts: listing, privacy labels, age rating, unlisted, EU trader, screenshots

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-08T19:33:55Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/90

---

## Summary

Draft-only paperwork for the four App Store readiness items (#67, #68, #69, #70), tracked under #71. Per the brief that started this: **draft everything, submit nothing** — nothing here has touched App Store Connect or any of Apple's own forms. Every file is text for Georg to read and paste himself.

- [`docs/appstore/listing.md`](docs/appstore/listing.md) — German-first listing copy (app name, subtitle, promotional text, description, keywords), written distinct from `docs/testflight-public-link.md`'s beta description rather than reusing it — that one leads with what doesn't work yet, which is right for a tester and wrong for a storefront. Support/marketing URL: options presented, not decided.
- [`docs/appstore/privacy-labels.md`](docs/appstore/privacy-labels.md) — App Privacy answers, cross-checked against `PrivacyInfo.xcprivacy` and the live privacy policy. Flags a real limitation: the nutrition-label checkbox format has no field for "a named third party may retain data for model improvement" (the Gemini free-tier caveat #68 calls out), so that has to keep living in the privacy policy and review notes.
- [`docs/appstore/age-rating.md`](docs/appstore/age-rating.md) — draft questionnaire answers, and a specific answer to whether Apple's new social-media questions (announced 2026-07-09) apply here: no, because the trigger is redistribution/amplification through a social feed, not "sends data to a third-party backend."
- [`docs/appstore/unlisted-request.md`](docs/appstore/unlisted-request.md) — draft request text. Verifying Apple's current page against issue #69's summary found a real sequencing correction: unlisted distribution can only be requested *after* the app is submitted to App Review, so it can't be literally the first step of the plan, as #69/#71's comment currently has it.
- [`docs/appstore/eu-trader.md`](docs/appstore/eu-trader.md) — facts laid out, a non-trader recommendation given no revenue/IAP/ads, and explicit that the declaration itself is Georg's legal call, not something this drafts around.
- [`docs/appstore/screenshots.md`](docs/appstore/screenshots.md) + `Tools/appstore_screenshots.sh` — reuses the existing headless simulator-capture recipe at the size Apple currently requires (1320×2868, the 6.9" bucket). Actually **ran** the script rather than just writing it: caught a blank-screenshot race on cold launch and an alpha-channel issue that would have been rejected at upload, fixed both, and committed the four verified captures in `design/appstore/` so Georg can look at them without re-running anything.

## Worth reading before anything else

Issue #71's own recommendation is that an App Store submission isn't ready today — the hard blocker is #53 (the Gemini key ships inside the app bundle, extractable from any public IPA). This PR doesn't change that assessment or work around it; the paperwork can be finished in parallel without implying submission is imminent.

## Test plan

- [x] Ran `Tools/appstore_screenshots.sh` end-to-end against a real simulator (not just written, actually executed)
- [x] Verified all four screenshots: 1320×2868px, no alpha channel (`sips -g pixelWidth -g pixelHeight -g hasAlpha`)
- [x] Read each screenshot's actual image content to confirm it shows the intended state (not just a non-error exit code — the first run silently produced a blank PNG)
- [x] Cross-checked privacy label answers against `PrivacyInfo.xcprivacy` and the live privacy policy text
- [x] Verified Apple's current requirements via their own pages rather than trusting the brief's summary (screenshot sizes, unlisted-distribution process, DSA trader page, age-rating questionnaire) — one of these checks changed the recommended sequencing in #69

🤖 Generated with [Claude Code](https://claude.com/claude-code)

---

### Georg-Klock — 2026-08-08T19:37:54Z

Closing — this was meant to stay internal/local, not go through GitHub. Pulled the content off into local-only files instead.
