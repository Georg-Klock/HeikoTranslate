# pull #15 — Close the German-scanner blind spot, stop log I/O in body, fix drifted docs

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-03T22:49:09Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/15

---

Closes #5. Closes #6. Closes #7.

## #5 — the guardrail had a hole

The pattern required the literal to sit immediately after the call's opening paren, so `Text(String(format: "…"))` and `Text(verbatim: "…")` were invisible to it. Widened to allow one optional wrapping call and one optional argument label in between.

Running it then surfaced **exactly the string the report predicted, and nothing else** — `"%.0f Min gehört · %.0f Min gesprochen"`, which had reached the screen without ever passing this review. It's German and its interpolations are numbers, so it's registered rather than changed.

Worth stating why this one matters more than its severity label suggests: this test exists to make it *impossible* to ship text Heiko can't read. A hole in it is worse than not having it, because it reads as coverage.

## #6 — disk I/O per keystroke

Both sheets called `DiagnosticLog.shared.exportedFile()` inside `body`. That's a `queue.sync`, a read of every kept run, and a write of the concatenation. `body` re-runs on every keystroke in the language search field, and on every tracker update in `CostSheet` — so all of it ran synchronously on the main thread, repeatedly.

Now built once per appearance in a `.task`, on a detached utility task, with only a `URL` crossing back to the main actor. The `ShareLink` row is untouched, so L1.28 still pins that it exists and is German.

## #7 — docs describing a design that no longer exists

- `README.md` listed `Models/ConversationPartner.swift`, deleted in 0f32814, and described the service as running "the de/en/es sessions". (Replaced the stale entry with `FillerWords.swift`, which is actually there and wasn't listed.)
- `docs/ARCHITECTURE.md` said audio streams "to all three sessions" and that codes can misdetect "unanimously across all three" — both inside current-behaviour sections — and costed three concurrent input streams at ≈3× / ≈$0.016 per minute when two run at ≈2× / ≈$0.011.
- `CLAUDE.md`'s pointer sold the whole file as "why three concurrent sessions", which is the one line most likely to mislead a fresh session, since it's in *Read first*.

**Two deliberate non-changes.** The historical section keeps its counts and its heading — it's correctly labelled and explains why the design changed. And the 2026-07-27 mic-watchdog measurement keeps "three", now explicitly dated as *"when three sessions still ran"*: that was a real device observation, and rewriting it would have falsified the evidence rather than fixed the drift.

I'd already fixed one instance of this in passing — the service's own class doc comment, in the #3 commit.

## Verification

L1 43/43, including `GermanUITests` under the widened scanner. No L3: nothing here touches turn logic, sessions, or the audio path.

**Note on merge order:** this branch and #13 both touch `CLAUDE.md`'s *Read first* list on adjacent lines. They should merge cleanly either way round, but that's the one place to glance at if git complains.

---

### Georg-Klock — 2026-08-03T22:51:13Z

Added one more instance of the same drift, found while reviewing the finished work: `CostSheet`'s footer read *"Three sessions stream while the mic is open."*

Same stale design as the docs, but this one is **on screen** rather than in a file, and it sits directly beneath the cost figures it exists to explain — so it misstated the per-minute arithmetic to the only person who ever reads that sheet.

`GermanUITests` doesn't cover `CostSheet` by design (developer-facing, English, reachable only via Nutzung), which is why nothing flagged it. Worth noting as a small limit of that guardrail: it protects Heiko's surfaces, not correctness of the English ones.

L1 still 43/43.
