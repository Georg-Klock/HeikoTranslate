# issue #70 — App Store listing metadata does not exist yet (screenshots, description, support URL, age rating)

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T23:08:47Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/70

---

## Summary
TestFlight needed a beta description and a feedback email. A store listing — **including an unlisted one** — needs a full set of metadata that has never been produced.

## Missing
- **Screenshots** for every required device size. `Tools/make_case_study_images.py` and the headless capture recipe exist, so this is mechanical rather than hard — but the App Store's framing rules differ from the case-study page's.
- **Description, subtitle, keywords, promotional text.** The 4000-character beta description is a good starting point but is written for testers ("was noch nicht rund läuft"), not for a product page. The candour is right for TestFlight and reads differently on a storefront.
- **Support URL** — required. Currently nothing; the privacy URL is live but is not a support page.
- **Marketing URL** — optional, and the natural answer is the case-study page once it is published (#12).
- **Age rating questionnaire.**
- **Category** — already set (Dienstprogramme / Reisen).
- **Primary language** — already German; worth confirming that is right for a US listing too.

## The one real decision
The app is one button and a transcript, in six languages, built for one person. **A store listing invites judgement as a general translator app**, against Google Translate and Apple Translate. The description has to be honest about what it is without either overselling it or reading as an apology.

Worth writing after #45 and #38 are resolved, since what the app reliably does is currently a moving target.

*Filed from the 2026-08-07 App Store readiness review.*
