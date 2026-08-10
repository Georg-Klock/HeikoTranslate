# issue #10 — AI-assisted sessions must use branches + pull requests, not direct pushes to main

- **State:** closed
- **Opened by:** jctoledo on 2026-08-02T01:16:21Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/10

---

## Summary
Every commit in this repo's history has gone straight to `main` — 69 commits, zero branches besides `main`, zero merge commits, zero pull requests, ever. This includes `CLAUDE.md`'s own current instruction, which explicitly tells an AI-assisted session to `git push` directly after every commit. That's worth fixing before it produces the kind of regression `TESTING.md` was written to catch, just one layer up: at the change-integration level instead of the test level.

## Evidence
```
$ git branch -a
* main
  remotes/origin/HEAD -> origin/main
  remotes/origin/main

$ git log --merges --oneline | wc -l
0

$ git rev-list --count HEAD
69

$ gh pr list --repo georgkloeck/HeikoTranslate --state all
(empty)
```

`CLAUDE.md` currently reads (the "Commit at every working state..." bullet, under "Rules for this codebase"):
> Commit at every working state, and `git push` after committing — the private GitHub remote (github.com/georgkloeck/HeikoTranslate) is the offsite backup, and an unpushed commit only exists on one SSD.

This rule is *correct* about the real risk it's guarding against — an unpushed commit sitting only on one machine — but as written it tells an AI-assisted session to push straight to `main`, not to push a branch and open a PR. For a project this careful about everything else (turn-taking correctness, wire-protocol findings, German-only UI, adversarial reviews of filler-word lists), every code change — including the kind of multi-file, timing-sensitive `TurnLogic`/`GeminiLiveTranslationService` changes this project is full of — currently lands on the exact branch the next TestFlight build is cut from, with no review step and no CI gate (see the separate CI issue).

## What this issue is asking for
Update `CLAUDE.md`'s git rules so an AI-assisted session (Claude or otherwise):
1. Creates a topic branch for the work at hand instead of committing directly to `main`.
2. Pushes that branch and opens a PR (`gh pr create`) rather than pushing straight to `main`.
3. Only merges to `main` after explicit human approval (and, once CI exists, a passing check run).
4. Still follows the existing "commit at every working state, push often" discipline — the fix here is *which ref* gets pushed to, not the commit/push cadence itself, so the offsite-backup property the current rule protects is kept intact.

This should stay proportionate to a one-person project — it doesn't need required reviewers or branch-protection ceremony, just "work happens on a branch, lands on `main` through a PR" instead of every commit going straight there.

## Suggested fix
Rewrite the "Commit at every working state..." bullet in `CLAUDE.md`'s "Rules for this codebase" section to describe a branch + PR flow instead of direct pushes to `main`, and add `gh pr create` to the same section's list of expected commands alongside `xcodegen generate`/`deploy.sh`.

## Severity
**Medium** — no bug in the shipped app, but a real process gap: unreviewed direct-to-main commits are exactly the kind of thing that lets a regression reach Heiko before anyone (human or CI) had a chance to look at the diff.

*Raised at the user's explicit request, grounded in the git/PR history above and the current text of CLAUDE.md.*
