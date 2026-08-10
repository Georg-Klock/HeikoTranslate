# pull #33 — Close the build-number pipeline's failure windows

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-05T17:02:44Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/33

---

Fixes #22.

The invariant #16 established: **every build number that ever reaches a screen or Apple exists in exactly one commit, and is never reverted once it has been seen.** Both holes only open when something fails midway, which is why neither showed up in normal use.

## #22.1 — deploy.sh could revert the bump *after* the install

```
xcrun devicectl device install app …          # phone now has build N+1
xcrun devicectl device info apps … | grep -i heiko   # <- fatal under set -euo pipefail
```

Anything that makes that pipeline fail — phone drops off USB, devicectl changes its output format, grep simply matches nothing — killed the script *after* the install, fired the EXIT trap, and reverted `project.yml`. The phone runs N+1, git says N. The exact untraceable-build failure #16 exists to prevent, reintroduced by the trap added to prevent a different one.

Now: the info line is `|| true` (it was only ever informational), and `INSTALLED=1` is set the moment the install succeeds. Past that point the trap **commits** rather than reverts.

## #22.2 — release.sh had no trap at all

Two windows, one of them permanent:

- Failed archive after the bump → bumped, uncommitted `project.yml`. Every later run then refused on its own dirty-tree check until someone cleaned up by hand.
- Interrupt after the upload succeeded but before the commit → an Apple-visible build recorded in no commit. Unrecoverable: TestFlight will not accept that number again, so it is spent and nothing says which code produced it.

Now it has the same discipline as deploy.sh, flipping at `UPLOADED` instead of `INSTALLED`. If the commit fails after a successful upload the script cannot fix it, so the bar is: never revert, and say so unmissably.

## #22.3 — the revert destroyed unrelated edits

`git checkout -- project.yml` threw away every uncommitted `project.yml` change, and deploy.sh has no dirty-tree guard (deliberately — the daily loop deploys over work in progress). A hand edit plus any failed deploy silently destroyed the edit. Both scripts now put back **only** the CFBundleVersion line, and say so if that fails.

I did not add a dirty-tree guard to deploy.sh: refusing to deploy over uncommitted work would break the loop this script exists for, and the existing post-commit warnings already cover it.

## Verification

New `Tools/tests/build-number-windows.sh` — **38 assertions, all green**, a couple of seconds, no Xcode or network. Each case builds a throwaway git repo, copies the *real* scripts into it, and stubs `xcrun`/`xcodebuild`/`xcodegen` to fail at one named step. No copy of the scripts' logic lives in the test; the thing under test is the thing that ships.

Bold rows are the regressions; the rest is the behaviour that had to keep working:

| Case | Fails at | Expected |
|---|---|---|
| deploy happy path | — | bumped, installed, committed, clean |
| deploy | build | number restored |
| deploy | phone never appears | number restored |
| **deploy** | **post-install `devicectl info`** | **number COMMITTED** |
| **deploy** | build, with a hand edit in project.yml | **hand edit survives** |
| release | L1 | nothing moved |
| release | archive | number restored, clean |
| release | upload | number restored |
| release happy path | — | uploaded and committed |
| **release** | **commit, after a successful upload** | **number KEPT, loud warning** |
| release `--dry-run` | — | archived, restored, clean |

## Two bugs the suite caught in the fix itself

Both invisible to reading, both would have surfaced as a lost build number months later:

1. **`set -e` is disabled inside a function invoked as `f || …`.** The trap calls `commit_build_number || { warn }`, so a failing `git commit` did *not* abort the function — it fell through to `COMMITTED=1` and reported success. The script would have claimed it recorded a number it had not.
2. **`git diff --quiet` compares the worktree to the *index*, not to HEAD.** After a first failed attempt left `project.yml` staged, the retry saw no difference, returned early, and skipped the commit entirely.

Both now have explicit `|| return 1` and `git diff --quiet HEAD`, with comments naming the test that caught them.

## Docs

TESTING.md gains an **L0 — Tooling** level with the case table. Deliberately placed away from the L1 table, which #30 and #31 both append to.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
