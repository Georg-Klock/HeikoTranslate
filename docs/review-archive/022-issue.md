# issue #22 — deploy.sh/release.sh: the build-number pipeline still has unprotected failure windows (post-install revert; release.sh has no trap at all)

- **State:** closed
- **Opened by:** Georg-Klock on 2026-08-04T20:01:57Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/22

---

## Summary
#16 established the invariant — every number that ever reaches a screen maps to exactly one commit — and its fix has two remaining holes, both hand-verified.

**1. deploy.sh can revert the bump AFTER the app is installed.** Between the install and the commit sits `xcrun devicectl device info apps … | grep -i heiko`. Under `set -euo pipefail`, that pipeline failing (device drops off USB right after install; output format change; grep finds no match) kills the script → the EXIT trap sees `COMMITTED != 1` → reverts `project.yml` → **the phone runs N+1 while git says N.** The exact untraceable-build failure #16 exists to prevent, reintroduced by the trap that was added to prevent a different one.

**2. release.sh has no trap at all** (grep: zero hits). A failed archive — after the bump, before the commit — strands a bumped, uncommitted `project.yml`; every subsequent run then refuses on its own dirty-tree check until someone cleans up by hand. Worse: an interrupt after `xcodebuild -exportArchive` succeeds but before the commit leaves an **uploaded, Apple-visible build with no commit recording it** — permanent, since TestFlight numbers can't be reused.

**3. The deploy trap discards ALL uncommitted project.yml edits**, not just the bump (`git checkout -- project.yml`). deploy.sh has no dirty-tree guard, so a hand edit to project.yml + any deploy failure = the edit silently destroyed.

## Suggested fix
- deploy.sh: set `COMMITTED`-equivalent (or commit) immediately after the install succeeds — the post-install info line must not be able to trigger the revert; make it `|| true`.
- release.sh: same trap discipline as deploy.sh — revert the bump on any exit before upload; after a successful upload, the commit must be unconditional (trap commits rather than reverts past that point).
- Both: revert via `git checkout -p`-equivalent limited to the CFBundleVersion lines, or stash/restore, so unrelated project.yml edits survive.

## Severity
**High** for (2)'s post-upload window, medium for the rest — all are one failure away from the exact confusion this pipeline was rebuilt to end.
