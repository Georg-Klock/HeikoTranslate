# issue #62 — Run the L0 build-number failure-window suite in CI

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:40:54Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/62

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `.github/workflows/l1.yml:30-102`
- `Tools/tests/build-number-windows.sh:1-370`
- `TESTING.md:310-348`

## What's wrong

The repository documents `Tools/tests/build-number-windows.sh` as L0 coverage for the irreversible deploy/release build-number invariant, but GitHub Actions never runs it. Current CI verifies only L1. The local harness passed all 68 checks during this audit, proving it is an executable regression suite rather than documentation.

## Why it matters — moderate

`deploy.sh` and `release.sh` mutate Git history and represent irreversible device/TestFlight state. A regression in an interrupt, install, upload, or recovery window can merge with a green L1 check even though the dedicated safety suite would catch it.

## Suggested fix

Add an explicit L0 step to `.github/workflows/l1.yml` before the expensive Xcode work:

```yaml
- name: L0 build-number safety
  run: Tools/tests/build-number-windows.sh
```

Run it on the existing macOS job unless/until the harness is made portable and verified on a cheaper runner. Keep the command independent from the live API and simulator so failures are fast and diagnostic.

## Acceptance checks

- Every pull request runs the L0 harness and fails the workflow when any case fails.
- Workflow output includes the harness summary (currently `68 passed, 0 failed`).
- A deliberately broken build-number recovery condition makes the L0 step red while L1 is otherwise unaffected.
