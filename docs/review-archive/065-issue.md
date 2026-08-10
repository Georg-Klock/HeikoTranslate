# issue #65 — Restore the documented `Tools/targetprobe.sh` launcher

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:41:06Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/65

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `docs/ARCHITECTURE.md:31-36`
- `Tools/targetprobe/main.swift:3-17`
- `Tools/targetprobe/` (the documented shell launcher is absent)

## What's wrong

Documentation and the Swift source both tell developers to run `Tools/targetprobe.sh fr ko zh`, but no such file exists. The source program is present under `Tools/targetprobe/main.swift`, so the documented verification command is broken at the first step.

## Why it matters — minor

Target-language capability is a prerequisite for adding languages to the user-facing picker. A missing launcher turns a documented live-verification workflow into a manual source-compilation exercise and makes it easy to skip or mis-run.

## Suggested fix

Add an executable wrapper modeled on the existing tool launchers:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc HeikoTranslate/Services/GeminiLiveSession.swift \
  Tools/l3replay/common.swift \
  Tools/targetprobe/main.swift \
  -o .build/targetprobe
exec .build/targetprobe "$@"
```

If the intended command is different, update both the source comment and architecture documentation together.

## Acceptance checks

- `Tools/targetprobe.sh fr` launches the probe using the same local secret setup as the other live tools.
- The wrapper forwards all language-code arguments.
- Add a lightweight syntax/argument smoke check that does not contact the live API.
