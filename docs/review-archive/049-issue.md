# issue #49 — CostSheet is unreachable — the token breakdown and the cost reset have no way in

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T20:24:14Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/49

---

## What

`HeikoTranslate/CostSheet.swift` still builds and still works, but nothing opens it any more.

It used to be reached from **Settings → Nutzung** via a chevron. The settings redesign removed the chevron (Georg, 2026-08-06: "nutzung rounded to cents, and delete the menu behind it as well as the chevron"), which was right for the screen — but it took the only entry point with it.

## What is stranded in there

- the per-model token breakdown
- the **cost reset** — the only way to zero the running total

The Nutzung row itself survived and still shows minutes and dollars, so the number Heiko might care about is still on screen. What is gone is Georg's detail view.

## Why it matters

Not urgent — this is developer-facing, and the headline figure is still visible. But dead code that still compiles is the kind that rots quietly, and "I cannot reset the cost counter" will eventually be annoying.

## Options

1. Give it a deliberate entry point that Heiko will not find — a long-press on the Nutzung row, or DEBUG-only.
2. Fold the cost reset somewhere reachable and delete the sheet.
3. Delete it outright and accept that the total only ever grows.

Needs a decision, not just a fix.
