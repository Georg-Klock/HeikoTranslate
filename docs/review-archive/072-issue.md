# issue #72 — Separate translation languages from interface languages

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T23:16:07Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/72

---

## Summary
Adding a language currently means two things at once: a new translation target, and a new complete interface string set. Those have very different costs and very different risk profiles, and coupling them makes language coverage far more expensive than it needs to be.

## Current behaviour
Interface strings follow the **home** language (`HeikoTranslate/UIStrings.swift`), so every language offered in settings requires a full translated interface. #48 records that only German has been reviewed by a native speaker; the remaining five are complete and verified non-German, but unreviewed.

## The asymmetry worth exploiting
The two sides of a conversation use the app differently:

- The **home** speaker owns the phone. They open settings, read the status line, and act on error messages. They need the interface in their language.
- The **partner** speaker is being translated *for*. They speak, and they read one large line of translated text. They never navigate the interface.

A partner-side language therefore needs a working translation target and nothing else.

## Proposal
Split the language list into two sets:

- **Translation targets** — every language the model reliably supports. Cheap to add: an enum case plus a verified probe.
- **Interface languages** — the subset with a human-reviewed string set. Selectable as *home*.

A language in the first set but not the second remains fully usable by a visitor; it simply cannot be chosen as the phone owner's own language until its strings are reviewed.

## Effect
- Translation coverage can expand immediately without expanding unreviewed interface surface.
- #48 stops growing with every new language, and becomes a bounded piece of work against a fixed list.
- The home-language default (`ConversationViewModel.defaultHomeLang`) and the `-ResetLanguagePair` recovery hatch are unaffected.

## Design questions
- SPEC §4.4 currently guarantees any pairing in either direction. This introduces an asymmetry that needs writing down there, and L1.29* would need extending to cover a translation-only language on the home wheel.
- The settings UI shows two columns; the home column would draw from the smaller set. The existing `excludesOtherSide` asymmetry in `LanguageColumn` is a reasonable precedent.
