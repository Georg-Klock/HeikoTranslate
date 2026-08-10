# issue #27 — Tooling hygiene: stale DerivedData glob, inconsistent device selection, .venv ignored only by accident, no shell linting in CI

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-04T20:02:55Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/27

---

## Summary
Four small operational risks from the audit, none urgent, all cheap:

1. **deploy.sh picks the .app alphabetically, not by recency** — `ls -d …/DerivedData/HeikoTranslate-*/…/*.app | head -1`. With more than one DerivedData directory for the project (which Xcode creates on project-identity changes — one exists right now with a hash suffix), a **stale build can be installed while the fresh build number gets committed**, silently breaking the number↔code mapping everything else protects. Fix: `ls -dt` (mtime), or better, resolve via `xcodebuild -showBuildSettings`.
2. **Device selection is three different rules**: the wait loop passes on ANY connected device, the install targets one hardcoded UUID, `pull_logs.sh` takes the first device it sees. One phone today, so it holds; a second device (an iPad, a loaner) makes the loop pass while the install hangs. Fix: one `DEVICE_UUID` check everywhere, sourced from one variable.
3. **`Tools/.venv` is invisible to git only via the venv's own self-`.gitignore`** (`*` inside it, written by `python -m venv` on 3.13+). The repo's `.gitignore` has no venv entry. Recreate that venv with an older Python and thousands of untracked files appear — at which point `release.sh`'s `git status --porcelain` gate refuses every release. Fix: add `Tools/.venv/` to the repo `.gitignore`.
4. **CI never parses the two scripts that mutate git state.** `deploy.sh`/`release.sh` commit to the repo, and nothing runs even `bash -n` over them. A `shellcheck` + `bash -n` job on an **ubuntu** runner (1× multiplier, seconds) covers every `.sh` in Tools/ per PR.

## Severity
**Low** — but (1) undermines the build-number invariant from an unexpected direction, and (3) is a one-line fix against a confusing future morning.
