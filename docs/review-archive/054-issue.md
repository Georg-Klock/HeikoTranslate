# issue #54 — Do not treat an `unavailable` iPhone as deployable

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:37:31Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/54

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `Tools/deploy.sh:225-243`
- `Tools/pull_logs.sh:18-39`
- `Tools/deploy.sh:252-258` (build-number state changes after the false readiness decision)

## What's wrong

Both scripts match device state with `connected|available`. The string `unavailable` contains `available`, so a locked or unreachable device is accepted as reachable.

The failure is directly reproducible:

```bash
printf '%s\n' 'Example iPhone (unavailable)' \
  | grep -iE 'iphone|ipad' \
  | grep -qiE 'connected|available'
# exits 0
```

`deploy.sh` can therefore leave its waiting loop and attempt installation before a device is usable. Its point-of-no-return bookkeeping can then burn/commit a build number even though the actual install was not established. `pull_logs.sh` can select an unavailable device and fail later with a misleading path.

## Why it matters — moderate

This breaks the deployment tool's core safety claim: a recorded build number and a reported installation may no longer correspond to an installable phone. It also makes recovery harder for the non-technical operator the scripts are intended to protect.

## Suggested fix

Put one reachability predicate in a shared shell helper and use it from both scripts. At minimum, reject unavailable/disconnected rows before accepting the supported connected or paired-available states:

```bash
is_reachable_ios_device() {
  grep -iE 'iphone|ipad' \
    | grep -viE 'unavailable|disconnected' \
    | grep -qiE 'connected|available'
}
```

Use the same filtering when extracting the UUID in `pull_logs.sh`. Prefer structured `devicectl` output if available, rather than matching a human-formatted table.

## Acceptance checks

- A row containing `unavailable` or `disconnected` is rejected.
- A USB `connected` row and a Wi-Fi `available (paired)` row are accepted.
- `Tools/tests/build-number-windows.sh` includes an unavailable-device case proving no build number is committed.
- `deploy.sh` and `pull_logs.sh` call the same predicate, so future state matching cannot drift.
