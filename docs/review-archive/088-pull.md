# pull #88 — Guard deployments against unavailable devices

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-08T19:16:58Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/pull/88

---

Fixes #54

## What changed

- Added one shared `devicectl` JSON-based reachability helper for iPhone/iPad devices.
- `deploy.sh` now requires the configured UUID itself to be `connected` or `available (paired)` before it can attempt an install.
- `pull_logs.sh` applies the same check to automatic and explicit UUID/name selection; named devices are matched locally from structured JSON, so names such as `Georg's iPhone` remain supported without predicate injection.
- Expanded the L0 failure-window harness with exact-state fixtures, spoofed names/UUIDs, unreachable explicit selectors, UUID-casing, and iPad coverage.

## Safety effect

`unavailable`, `disconnected`, and `not connected` devices now fail closed. A different reachable phone, or a misleading display name, cannot make the configured deployment target appear ready and consume a build number.

## Validation

- `bash -n Tools/ios_device.sh Tools/deploy.sh Tools/pull_logs.sh Tools/tests/build-number-windows.sh`
- `git diff --check`
- `Tools/tests/build-number-windows.sh` — 105 passed, 0 failed
