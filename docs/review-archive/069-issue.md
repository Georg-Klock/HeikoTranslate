# issue #69 — Unlisted App Distribution has to be requested from Apple — it is not a switch in App Store Connect

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T23:08:10Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/69

---

## Summary
Georg's stated preference (2026-08-07) is **"ideally unlisted but available"** — a direct link, not discoverable by search or browsing. Apple supports exactly that via **Unlisted App Distribution**, but it is a request, not a setting, and it changes less than it sounds like it does.

## What it gives
- A permanent direct link; the app does not appear in search results, charts, categories, or recommendations.
- Available in the territories chosen, to anyone with the link, with no tester cap and no 90-day expiry — the two things that make the current TestFlight link a poor long-term home for a portfolio piece.

## What it does NOT change
- **Full App Review still applies**, against the same guidelines as any listed app. Unlisted is about discoverability only.
- The complete listing metadata is still required: screenshots, description, keywords, support URL, category, age rating.
- EU distribution still triggers the DSA trader declaration (separate issue).

## Process
Request unlisted distribution through App Store Connect. Apple reviews the request separately from App Review, and it is not instant — this should be started before the build is otherwise ready, not after.

## Sequencing note
This is the *cheapest* item on the readiness list and the one most likely to be started too late. It is also worth confirming the request is granted **before** investing in listing screenshots, since a refusal would change the plan entirely.

*Filed from the 2026-08-07 App Store readiness review.*
