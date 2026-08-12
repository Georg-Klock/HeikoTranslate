# Privacy policy for Heiko Translate

Needed as the **Datenschutz-URL** in App Store Connect → TestFlight →
Testinformationen. The form does not mark it required, which is misleading:
since 3 October 2018 Apple has required a privacy policy for external TestFlight
distribution. Internal testers do not need one; a public link is external
testing by definition, so this is a **hard blocker**, not a nicety.
<https://developer.apple.com/help/app-store-connect/test-a-beta-version/enter-test-information>

## Where it lives

Built as a Webflow page on the georgklock.com site, slug
`heiko-translate-privacy`, styled to match the portfolio (black background,
Soehne Buch, `#ffffff` headings, `#86868b` body, 640px measure). **Live since
2026-07-31** at:

> **https://www.georgklock.com/heiko-translate-privacy**

Use the `www.` form in App Store Connect — the apex redirects to it, and there
is no reason to make Apple's fetcher follow a hop.

## The case-study page is now a draft — read this before publishing

Webflow **single-page publishing is not available on this plan** (passing a
`pageId` to the publish endpoint returns `400 Invalid parameter: pageId`), so
publishing georgklock.com publishes every non-draft page at once. Releasing the
privacy page alone therefore required marking the case-study page
`heiko-translate` as `draft: true`. Product decision, 2026-07-31: hold the case
study back until it has real photography and the TestFlight public link.

Two consequences that will bite if forgotten:

1. `georgklock.com/heiko-translate` now returns **404** (verified). It had never
   been live there, so nothing was taken away.
2. **Draft excludes a page from *all* publishing, staging included.** The case
   study still sits on `kloeckwork-22.webflow.io/heiko-translate` only because
   staging was last published before the draft flag was set. The next staging
   publish will drop it. To review it after that, un-draft it first — or open it
   in the Designer, which always shows drafts.

Going live with the case study is one flag flip plus a publish, and it takes the
privacy page along with it, which is harmless.

Everything below is true of the app as built. If any of it stops being true —
particularly the "stores nothing off the device" line — this file and the page
must change on the same day. Since 2026-08-12 that sentence is true BY
CONSTRUCTION: the automatic diagnostic-upload path was removed entirely
(GitHub #8, Georg's decision), so no configuration of the app can send a log
anywhere on its own — the manual share row and the cable are the only routes,
both human-initiated.

---

## German (primary — the app's own language)

**Datenschutzerklärung — Heiko Translate**

Stand: 31. Juli 2026

Heiko Translate ist eine private, nicht-kommerzielle App. Sie wurde von Georg
Klock für den persönlichen Gebrauch gebaut und über TestFlight verteilt.

**Welche Daten verarbeitet werden**

Während einer Übersetzung nimmt die App über das Mikrofon Sprache auf und
sendet diese zur Übersetzung an die Google Gemini API. Zurück kommen der
erkannte Text und die Übersetzung. Mehr wird nicht übertragen: kein Name, keine
E-Mail-Adresse, kein Standort, keine Kontakte, keine Geräte- oder Werbe-ID.

Das Mikrofon ist nur aktiv, solange eine Übersetzung läuft. Wird die Taste
nicht gedrückt, nimmt die App nichts auf.

**Wo die Daten hingehen**

Die Übersetzung läuft über die Google Gemini API auf deren kostenloser Stufe.
Google kann die dort übermittelten Daten verwenden, um seine Produkte zu
verbessern. Für diese Verarbeitung gilt Googles eigene Datenschutzerklärung:
https://policies.google.com/privacy

Wer damit nicht einverstanden ist, sollte die App nicht benutzen. Ohne diese
Übertragung kann die App nicht übersetzen; einen Offline-Modus gibt es nicht.

**Was auf dem Gerät bleibt**

Der Gesprächsverlauf und ein technisches Protokoll (Zeitstempel, Zustände,
Fehler) werden ausschließlich auf dem iPhone gespeichert und beim Deinstallieren
mit gelöscht. Die App sendet diese Daten von sich aus an niemanden. Ein
Protokoll verlässt das Gerät nur, wenn die Nutzerin oder der Nutzer es in den
Einstellungen der App aktiv teilt.

**Kein Tracking**

Keine Analyse-Werkzeuge, keine Werbung, keine Drittanbieter-SDKs, keine
Profilbildung. Es gibt keine Nutzerkonten und keine Anmeldung.

**Kinder**

Die App richtet sich nicht an Kinder und erhebt wissentlich keine Daten von
Kindern.

**Rechte und Kontakt**

Da keine personenbezogenen Daten gespeichert werden, gibt es kein Konto, das
gelöscht werden könnte — das Deinstallieren der App entfernt alle lokalen
Daten. Fragen, Auskunfts- oder Löschwünsche: hi@georgklock.com

---

## English

**Privacy Policy — Heiko Translate**

Last updated: 31 July 2026

Heiko Translate is a private, non-commercial app. It was built by Georg Klock
for personal use and is distributed through TestFlight.

**What data is processed**

While a translation is running, the app captures speech through the microphone
and sends it to the Google Gemini API to be translated. The recognised text and
its translation come back. Nothing else is transmitted: no name, no email
address, no location, no contacts, no device or advertising identifier.

The microphone is active only while a translation is running. If the button is
not pressed, the app records nothing.

**Where the data goes**

Translation runs on the Google Gemini API on its free tier. Google may use data
submitted there to improve its products. That processing is governed by
Google's own privacy policy: https://policies.google.com/privacy

If that is not acceptable to you, please do not use the app. Without this
transmission the app cannot translate; there is no offline mode.

**What stays on the device**

The conversation transcript and a technical log (timestamps, states, errors)
are stored only on the iPhone and are deleted when the app is deleted. The app
does not send this data anywhere on its own. A log leaves the device only if
the user actively shares it from the app's settings.

**No tracking**

No analytics, no advertising, no third-party SDKs, no profiling. There are no
user accounts and no sign-in.

**Children**

The app is not directed at children and does not knowingly collect data from
children.

**Rights and contact**

Because no personal data is stored, there is no account to delete — removing
the app removes all local data. Questions, access or deletion requests:
hi@georgklock.com
