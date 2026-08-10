# issue #61 — Generate the Xcode project before running the release test gate

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:40:49Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/61

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `Tools/release.sh:89-97`
- `Tools/release.sh:224-231`
- `.gitignore:1-3`

## What's wrong

`release.sh` runs L1 with `xcodebuild test -project HeikoTranslate.xcodeproj` before it runs `xcodegen generate`. The Xcode project is generated/ignored, so the release test gate can use a stale project that does not include newly added source files or tests. On a fresh checkout with no generated project it fails before testing; on a developer machine it can pass while testing a project that differs from the project later archived at line 224.

## Why it matters — moderate

The release gate is supposed to validate the exact application that will be archived. A stale generated project can make a green L1 result prove less than the release process claims, including silently omitting recently added test targets/files.

## Suggested fix

Generate the project after the early dirty-tree/privacy guards and before any `xcodebuild test` call:

```bash
xcodegen generate >/dev/null

if [[ "$RUN_TESTS" == "1" ]]; then
  xcodebuild test -project HeikoTranslate.xcodeproj ...
fi
```

Keep (or harmlessly repeat) generation after the build-number change before archive if the generated project incorporates versioned configuration. The key invariant is that L1 and archive use a project generated from the current `project.yml`.

## Acceptance checks

- A fresh clone with no `HeikoTranslate.xcodeproj` can reach the L1 gate.
- Add a release-script harness case that records `xcodegen` before `xcodebuild test`.
- A newly added source/test file is present in both the L1 project and the later archive project.
