# issue #8 — No CI: add a GitHub Actions workflow for L1 tests (L2/L3 as an optional, secret-gated job)

- **State:** closed
- **Opened by:** jctoledo on 2026-08-02T00:01:11Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/8

---

## Summary
There's no CI in this repo (no `.github/workflows`) — every gate (L1 logic tests, L2 protocol probe, L3 replay) runs only when someone remembers to run it locally. `TESTING.md`'s own stated philosophy is "catch bugs before they reach a human tester," and `CLAUDE.md` mandates "Run L1 AND L3 before every device deploy" as a standing rule — CI is the natural enforcement of that rule instead of relying on memory.

## What I'd propose (and what I'd leave to you)
I did **not** commit a workflow file directly — I have no macOS/Xcode available in this environment to actually run and validate one, and an untested CI config that silently red-Xs (or worse, silently no-ops) on its first real run is worse than no CI at all. Two things are genuinely your call rather than mine:

- **GitHub Actions macOS runners carry a 10x per-minute multiplier** against Actions minutes (relevant for a private repo's included-minutes budget) — worth deciding you want that cost before it's wired up.
- L2/L3 talk to the **live** Gemini API — L3 alone costs "a few cents" per full run per `TESTING.md`, and needs a `GEMINI_API_KEY` repository secret. Whether that should run on every push, or only on-demand, is a spend/security tradeoff you should set.

### L1 — free, no secrets, safe to run on every push/PR
```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  l1:
    name: L1 logic tests
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Install xcodegen
        run: brew install xcodegen
      - name: Placeholder Secrets.plist (L1 never touches AppConfig, but keep the bundle resource present)
        run: cp HeikoTranslate/Resources/Secrets.plist.example HeikoTranslate/Resources/Secrets.plist
      - name: Generate Xcode project
        run: xcodegen generate
      - name: Resolve an available iPhone simulator
        id: sim
        run: |
          NAME=$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [0-9]+( Pro)?' || echo "iPhone 16")
          echo "name=$NAME" >> "$GITHUB_OUTPUT"
      - name: Run L1 tests
        run: |
          xcodebuild test -project HeikoTranslate.xcodeproj -scheme HeikoTranslate \
            -destination "platform=iOS Simulator,name=${{ steps.sim.outputs.name }}" -quiet
```
The dynamic simulator lookup is there because hardcoding `iPhone 17 Pro` (what `TESTING.md` uses locally) risks going stale the moment the runner's default Xcode image doesn't include that exact simulator — pin it explicitly instead if you'd rather control the Xcode/simulator version exactly.

### L2/L3 — optional, only if you want it, gated behind a secret
A separate `workflow_dispatch`-triggered (or nightly `schedule`-triggered) job, with `GEMINI_API_KEY` added as a repo secret and written into `Secrets.plist` at run time, running `Tools/l3replay.sh`. I'd deliberately keep this OFF the push/PR trigger — it costs real money per run and there's no reason to spend it on every commit to a personal project.

## Suggested next step
If you want this, I can wire up the L1 workflow for real once you confirm the runner/Xcode version you want pinned (or you can drop this YAML in as-is and we iterate from whatever the first real run tells us).

## Severity
**Low-Medium** — pure process improvement, no user-facing impact, but it turns "run L1 and L3 before every deploy" from a remembered rule into an enforced one.

*Proposed via code review; not implemented in the repo — see rationale above.*
