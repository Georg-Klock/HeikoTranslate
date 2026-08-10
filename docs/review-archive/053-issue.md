# issue #53 — Contain the risk of the embedded Gemini key: separate key, usage monitoring, scripted rotation, in-app recovery

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:37:27Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/53

---

## Decision (2026-08-07): no proxy. Contain the risk instead.

The original framing of this issue was to stop shipping the key by routing traffic through a server. That has been reconsidered and rejected for this project, deliberately rather than by omission.

## Why a proxy is not the right answer here

- **No financial exposure.** The key is on the Gemini free tier, which is a hard $0 cap. There is no bill to be surprised by; the worst outcome is exhausted quota.
- **Blast radius is already contained.** Nonna-Phone uses its own key, so abuse affects this app alone.
- **A proxy is not free.** It is a bidirectional streaming relay that must not add latency to a live conversation, plus authentication that is genuinely hard to do properly on iOS (App Attest — otherwise the proxy key simply replaces the Gemini key as the extractable secret). It also becomes a service that has to stay up while the app is being used abroad, and it puts conversation audio through infrastructure we control, which changes the privacy position described in `docs/privacy-policy.md`.
- **App Review does not require it.**

The residual risk is that someone extracts the key and consumes the quota, and the app stops working until the key is rotated. That is the same failure mode as unexpected popularity, and it is survivable if it is *detected* and *recoverable*.

## What replaces it

**1. A separate key for public builds.** Distinct from the key used for local development, so rotation never disturbs the development loop.

**2. Usage monitoring.** Gemini usage is backed by Cloud Monitoring; `serviceruntime.googleapis.com/api/request_count` breaks down by API, response code and credential, so request volume and 429 rate per key are queryable. A scheduled job checks daily and reports only on anomaly.

The signal is unusually high-contrast here: expected traffic is tens of requests a day in a single timezone, while abuse is thousands around the clock. The strongest single tell is **429s rising while our own installs are quiet**.

Requires a GCP service account with `monitoring.viewer`.

**3. Scripted rotation.** A `Tools/` script that mints a replacement key, writes `Secrets.plist`, and runs the existing release path, so rotation is a short procedure rather than an improvised one.

**4. In-app recovery — the part that makes rotation safe.** Tracked separately.

## Rotation order

Conventional advice is to create the new key, ship, wait for adoption, and only then revoke — because revoking first breaks every install in the field.

**That constraint disappears once the app explains the failure and offers the fix.** A revoked key produces `API_KEY_INVALID`, which is unambiguous: this build cannot work again. If the app recognises that and offers an update, revocation degrades into a two-tap recovery instead of a silent failure.

So the order becomes: **revoke immediately on detected abuse → ship the replacement → users update from the in-app prompt.**

## Scope

- [ ] Separate key for public builds; document which is which
- [ ] Cloud Monitoring query + scheduled anomaly check
- [ ] `Tools/` rotation script
- [ ] In-app recovery for a revoked key — see the error-differentiation issue
- [ ] Record the approach and the rotation runbook in `docs/release.md`

## Residual risk, stated plainly

Detection is same-day, not immediate. Recovery requires an App Store update, so users on an older build are unavailable until they take it. Both are acceptable for a free-tier, unlisted application; neither would be acceptable for a paid or billed one, and this decision should be revisited if the tier ever changes.
