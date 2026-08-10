# issue #67 — EU App Store: declare DSA trader status before a German launch (TestFlight is exempt, the App Store is not)

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T23:08:07Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/67

---

## Summary
`docs/testflight.md` records — correctly, and verified against Apple's own wording — that **EU Digital Services Act trader requirements do not apply to TestFlight**. That conclusion was scoped to TestFlight and does not carry over. Distributing on the **App Store in the EU** requires a trader-status declaration, and Germany is the target territory.

## Why the earlier research does not settle this
Apple: *"If you don't distribute apps on the App Store in the EU (for example you only distribute apps through alternative distribution, or TestFlight, or on the App Store only outside the EU), you're not acting as a trader on the App Store."* Every exemption in that sentence is one we currently rely on. A DE App Store launch removes it.

This applies to **unlisted** distribution too — unlisted changes discoverability, not the legal basis of distribution.

## What is needed
- Declare trader status in App Store Connect before the app can be made available in the EU.
- **If a trader:** Apple verifies and then publishes name, address, phone and email on the public product page. For a personal project run from a home address, that is a real decision, not a checkbox.
- **If not a trader:** Apple's own example fits well — *"if you're a hobbyist and you developed your app with no intention of commercialising it, you may not be considered a trader"* — no revenue, no IAP, no ads, no paid-apps agreement signed. The declaration still has to be made deliberately and is subject to Apple's verification.

## Open question for Georg
Whether the non-trader declaration is the honest one here. It looks right on the facts, but it is a legal statement about you, not a build setting, and I am not in a position to make it for you.

## Reference
<https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/>

*Filed from the 2026-08-07 App Store readiness review. Blocks DE only; a US-only launch is unaffected.*
