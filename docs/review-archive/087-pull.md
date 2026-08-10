# pull #87 — CI: run L1 on merges to main, skip docs, stop brew auto-updating

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-08T19:13:12Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/87

---

The per-PR trigger reached **90% of the monthly Actions allowance** — 1,811 of 2,000 included minutes — across **33 runs with zero failures**.

It was never going to find anything. `deploy.sh` and `release.sh` both refuse to proceed without L1, so by the time a PR exists the suite has already passed locally, and CI re-ran it at the macOS **10× billing multiplier**.

My sizing was wrong, not the design: it assumed 5–10 PRs a month, and the project has been running at 17–37 commits a day.

## Three changes

**Trigger on push to `main`, not `pull_request`.** Roughly a third of the runs, and it guards the one thing local gates genuinely cannot — **the merge commit**. Nobody runs tests on a merged result, and a conflict resolved in Swift rather than Markdown would land broken on the branch releases are cut from. Three `TESTING.md` conflicts came up in one day recently; a Swift one is a matter of time.

The trade, stated in the file: a broken merge is caught minutes *after* it lands rather than before. On a repo where `main` is not auto-deployed, that is the cheaper side.

**`paths-ignore` for markdown, `docs/`, `design/`, `logs/`.** A large share of this project's changes cannot affect a build.

**`HOMEBREW_NO_AUTO_UPDATE` on the xcodegen install.** Refreshing the formula index costs more wall-clock than the install does, and every wall-clock minute bills as ten.

`workflow_dispatch` is kept, so a risky branch can still be checked before merging with `gh workflow run L1`.

## What I deliberately did not do

**No DerivedData cache.** It is the largest remaining cost — most of the ~5½ minutes is the compile — and it is also the one change that can hand back a **stale green**. This repo has already spent effort making sure a passing check proves the suite actually ran (dropping `-quiet`, asserting the test count). A build cache trades exactly that property away for minutes, which is the wrong direction for this project.

## Also

Removed the old header comment, which still argued for the per-PR trigger this commit replaces. A stale rationale is worse than none — someone would have read it as the current reasoning.

## Expected effect

Roughly a third of the runs, minus documentation-only merges, each about a minute shorter. Comfortably inside the free tier at the current pace.

**Separately, and more urgently: set a `$0` Actions budget.** 189 included minutes remain before overage begins billing, and macOS is the expensive tier.
