# pull #34 — Trap signals, and set the point-of-no-return before the command

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-05T17:48:50Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/34

---

Follow-up to #33 (merged), acting on the final-gate review there. Refs #22.

The review found no blocking issues and named two operational limitations. Both were fair. Testing them turned up a third and a fourth problem that were **worse than either**, so most of this PR is those.

## 1. `EXIT`-only traps do not run on `SIGINT`

Measured, not assumed:

```
trap f EXIT          + SIGINT -> f does NOT run
trap f EXIT          + SIGTERM -> f runs
trap f EXIT INT TERM + either  -> f runs
```

Ctrl-C during a long `xcodebuild` is *the* realistic interrupt on this project, and it is literally the scenario #22 describes for release.sh — "an interrupt after `-exportArchive` succeeds but before the commit". Neither script handled it. Both now trap `INT`/`TERM` and re-raise as the conventional `128 + signo`, so callers and CI still see a real interrupt.

## 2. The point-of-no-return flags were set one line too late

This is the one worth reading. Bash **defers a signal until the running child exits**, so:

```bash
xcodebuild -exportArchive …   # <- signal arrives here, held
UPLOADED=1                    # <- never runs
```

The trap fires *between* those two lines with `UPLOADED` still `0`, takes the "nothing claimed this number" branch, and **reverts a number Apple already has**. Deterministic — the new test case reproduced it on every run, not intermittently. `deploy.sh` had the identical hole around `devicectl device install`.

Both flags now go *before* their command. Consequence, and it is a deliberate behaviour change:

> **A failed or interrupted upload/install now burns its build number instead of restoring it.**

An exit code cannot distinguish "never reached Apple" from "Apple took it and something failed afterwards", and the two mistakes are not symmetric:

- burned number → skips one in a counter that is only ever required to *increase*. Harmless; CLAUDE.md says it only goes up, never that it is dense.
- reverted-but-claimed number → permanent. TestFlight will not accept it again, so an uploaded build maps to no commit for good. That is the failure the whole pipeline exists to prevent.

The commit message records which case it was ("burned deliberately rather than risk…"), so a gap in the numbering is always explained. One existing test expectation changed as a result, deliberately and with the reasoning written next to it in the suite and in TESTING.md.

## 3. Review limitation 1 — a dirty worktree leaves the build unreproducible

Correct, and it was only ever surfaced by a terminal warning that scrolls away. The uncommitted files are now listed **in the commit message itself**, so a bug report naming 2.3.41 three weeks later still says the build came from a dirty tree and exactly which files were dirty.

## 4. Review limitation 2 — an uploaded build whose commit fails needs manual recovery

Still true in general; it cannot be fully automated. But it is narrower and better signposted now:

- a failing **pre-commit hook** can no longer cause it — one loud `--no-verify` retry, because a hook must not be able to lose a number that is already on a device or at Apple;
- `.build-number-recovery` is written with the exact command to run. It is **untracked on purpose**: its presence trips the dirty-tree guard, so no further release can be cut until it is dealt with.

## 5. A regression this PR fixes from #33

#33 changed `git diff --quiet` to `git diff --quiet HEAD` (correctly — see that PR). Side effect: with `--no-bump`, a *staged* unrelated `project.yml` edit now looked committable, and would have landed inside a commit labelled `Build X (device)`. The main-line commit is now gated on `BUMPED`.

## Verification

L0 suite grown **38 -> 68 assertions, all green**, still ~2 seconds with no Xcode or network. New cases:

| Case | Fails at | Expected |
|---|---|---|
| deploy | the install command itself | number BURNED — the phone may have it |
| deploy | a signal during the build | number restored |
| deploy | a signal after the install | number COMMITTED |
| deploy | a failing pre-commit hook | still committed, via `--no-verify` |
| deploy | — (dirty worktree) | uncommitted files named *in* the commit |
| deploy `--no-bump` | — (staged edit) | not swept into a "Build X" commit |
| release | the upload | number BURNED — Apple may hold it |
| release | a signal after the upload | number COMMITTED |
| release | the commit, after upload | number KEPT + recovery file on disk |

Signals are exercised through stubs that `kill -TERM "$PPID"` at a named point, which puts the signal in the same deferred position a terminal Ctrl-C does. `SIGTERM` rather than `SIGINT` because SIGINT is not deliverable to a background job the way a terminal delivers it to a foreground process group; both go through the same handler.

Counting #33, this suite has now caught **four** bugs in its own subject that were invisible to reading — the two in #33, plus the signal gap and the deferred-signal ordering here.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
