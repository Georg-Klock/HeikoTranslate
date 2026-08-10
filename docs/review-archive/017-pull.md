# pull #17 — CI: L1 on pull requests only

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-04T16:46:39Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/17

---

Closes #8. Following the recommendation: **L1 on `pull_request` only, no L3 workflow, no secret in CI.**

**This PR is its own first test** — the workflow runs on this pull request, so the check below is the proof it works.

## Why PRs and not pushes

macOS runners bill **10 included minutes per wall-clock minute**, and a cold runner (checkout, brew, simulator boot, no derived-data cache) takes 5–8 minutes where this suite takes 45 seconds on your Mac. That's 50–80 included minutes *per run*. On every push, ~30 pushes a month would consume a private repo's entire allowance on a test you'd already run locally.

On PRs it's maybe 5–10 runs a month, comfortably inside Free — and since work now lands through PRs (#10), that's also the only moment the answer changes a decision.

## Why no L3 job

The cost argument is real but secondary. The stronger one: **L3 is known-flaky by design.** `TESTING.md` already encodes one-rerun-is-expected, and this session saw 42/4 then 56/0 on identical code. A check that goes red on healthy code teaches you to ignore red checks, and a muted gate is worse than no gate because it still looks like coverage.

It would also put your Gemini key in a repository secret — a fourth place it lives, alongside the app, TestFlight and Nonna-Phone. Wider blast radius, nothing bought.

## Two things that would have made this red for the wrong reasons

- **The simulator is chosen at runtime** from what the image actually has. Runner images retire devices without warning, and a pinned `iPhone 17 Pro` eventually fails for reasons that have nothing to do with the code. Verified the query locally — it returns `iPhone 17` on this Mac.
- **`Secrets.plist` is gitignored**, so CI writes a placeholder from the example. L1 never reads the key, but this stops a future test that instantiates more of the app from failing *only* in CI with a `fatalError` that says nothing about the real cause.

## A defect this turned up

Writing that placeholder step exposed a bug in yesterday's `release.sh` guard: it grepped for the **key name** `DIAGNOSTIC_UPLOAD_URL`, but `Secrets.plist.example` ships that key set to `REPLACE-ME`, and `AppConfig` deliberately ignores that value.

So a `Secrets.plist` copied from the example — precisely what the new CI step creates — would have refused a release that could never upload anything. It now tests the value the way `AppConfig` does: non-empty, not `REPLACE-ME`, `https`. Verified against four fixtures:

| Secrets.plist | verdict |
|---|---|
| example, `REPLACE-ME` | proceed |
| real `https://…` URL | **refuse** |
| key absent | proceed |
| no file at all | proceed |

L1 43/43 locally.

---

### Georg-Klock — 2026-08-04T16:59:04Z

Audited the first green run before merging, and it didn't meet the bar as written.

**`-quiet` suppressed the test summary entirely.** The CI log ended at `Testing started` with no counts anywhere — so a green check proved only that `xcodebuild` exited 0, which is indistinguishable from a run where the bundle loaded and executed nothing.

That's the same failure shape this repo's sibling work went after: a check that reads as coverage without being it. A gate that can't tell "43 passed" from "0 ran" isn't much of a gate.

Dropped `-quiet` and added an explicit assertion on the summary line, so the step fails if no passing tests are reported. I validated the regex against real `xcodebuild` output locally before pushing rather than discovering it in CI.

The rerun now prints it:

```
Executed 43 tests, with 0 failures (0 unexpected) in 0.178 (0.436) seconds
```

Losing `-quiet` also makes a real failure diagnosable straight from the log instead of needing a local repro.

**Cost, now measured rather than estimated.** The first run took **5m30s** wall clock — squarely in the 5–8 minute range I predicted, so ~55 included minutes per run. At PR frequency that's comfortable; on every push it would have been exactly the allowance drain the design avoids.

**One thing surfaced that I'm not touching here.** The build emits `capture of 'buffer' with non-Sendable type 'AVAudioPCMBuffer' in a '@Sendable' closure` at `GeminiLiveTranslationService.swift:560`. It's pre-existing and only a warning, but it's the same family as #2 — concurrency the compiler can't prove — and now that CI surfaces warnings on every PR it's visible. Worth its own issue rather than riding along in a CI change.
