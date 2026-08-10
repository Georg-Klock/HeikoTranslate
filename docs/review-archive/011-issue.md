# issue #11 — Add a CLAUDE.md directive for cutting a TestFlight release (archive/export/upload + when to bump the marketing version)

- **State:** closed
- **Opened by:** jctoledo on 2026-08-02T01:16:22Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/11

---

## Summary
There's a documented process for the everyday loop (`Tools/deploy.sh`: build → wait for phone → install → pull logs, one command, referenced right in `CLAUDE.md`'s "Commands" section) — but there is **no equivalent directive for cutting an actual TestFlight release**. The only place that process exists today is `docs/testflight.md`, which mixes a point-in-time status table for one specific submission (build 33, "Warten auf Prüfung") together with the actual reusable commands, isn't linked from `CLAUDE.md`'s "Read first" or "Commands" sections, and is already showing the kind of drift that happens when a runbook lives inside a status narrative instead of a stable reference (see below).

## What exists today
`docs/testflight.md` has the real commands, under "Then, the upload (I can run all of this)":
```bash
cd ~/Developer/HeikoTranslate
# bump CFBundleVersion in project.yml first, then:
xcodegen generate
xcodebuild archive -project HeikoTranslate.xcodeproj -scheme HeikoTranslate \
  -destination 'generic/platform=iOS' -archivePath /tmp/ht.xcarchive \
  -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath /tmp/ht.xcarchive \
  -exportPath /tmp/ht-export -exportOptionsPlist Tools/ExportOptions.plist \
  -allowProvisioningUpdates
```
plus a second `-exportArchive` variant using `Tools/ExportUpload.plist` that uploads straight to TestFlight through the signed-in Xcode account, no API key needed.

## Gaps
1. **Not discoverable.** `CLAUDE.md`'s "Read first" list is `SPEC.md`, `TESTING.md`, `docs/ARCHITECTURE.md`, `docs/history.md` — `docs/testflight.md` isn't in it, and `CLAUDE.md`'s "Commands" section (which does list `xcodegen generate` and the L1-L3 test commands) has nothing for cutting a release. A future session has to already know this file exists.
2. **No operational trigger for the marketing-version bump.** `CLAUDE.md` says: *"Leave `CFBundleShortVersionString` alone unless you mean it... Change it for a real release, not a bug fix."* That's a real and important distinction (it's the difference between minutes and a day-long Beta App Review, most consequential exactly when Heiko is travelling — `CLAUDE.md` says so itself) but there's no checklist or concrete signal for *when* a change qualifies as "a real release" versus "a bug fix." Under-specified, this can go either way badly: never bumping it (marketing version frozen indefinitely even across real feature work) or bumping it reflexively (triggering an avoidable review delay).
3. **The doc already drifted once, which is exactly the failure mode a stable runbook would prevent.** `docs/testflight.md`'s "Things that will bite" section says *"Every upload needs a higher `CFBundleVersion`. Currently 28"* — `project.yml` and `CLAUDE.md`'s own commit log show the build is now 33. A status table for one release event went stale the moment the next release happened, because there's nothing separating "what happened for build 33" from "the procedure for any future release."
4. **No script**, unlike the device-install loop. `Tools/deploy.sh` is one command for local installs; there's nothing comparable (e.g. `Tools/release.sh`) wrapping the archive → export → upload sequence, even though the commands above are already fully scriptable (they're plain `xcodebuild` invocations with no interactive steps once `Tools/ExportUpload.plist` exists).

## Suggested fix
- Add a "Cutting a release" entry to `CLAUDE.md`'s "Commands" section pointing at wherever the process ends up living.
- Separate `docs/testflight.md`'s reusable procedure from its point-in-time status table — either split them into two files (a stable runbook + a dated status log, the same split `TESTING.md`'s "Current status" table already models for test state), or at minimum give the procedure its own clearly-marked, version-agnostic section the status table can't drift out from under.
- Turn the archive/export/upload commands into a `Tools/release.sh` (mirroring `Tools/deploy.sh`'s shape) so cutting a release is one command instead of a copy-pasted multi-step recipe.
- Give the `CFBundleShortVersionString` bump rule a concrete trigger — e.g. an explicit list of what counts as "a real release" (a new feature set, a language pair change, anything Heiko-facing and significant) versus "a bug fix" (anything covered by the existing build-number-only path), so a future session doesn't have to guess.

## Severity
**Medium** — no bug in the app, but a real process gap in exactly the area `CLAUDE.md` already flags as high-stakes ("this matters most while he is travelling"): the release path is the one workflow here that's both consequential (a botched marketing-version bump costs a day of review while Heiko is abroad) and currently the least documented for repeatable, AI-assisted use.

*Raised at the user's explicit request, grounded in the current contents of `docs/testflight.md` and `CLAUDE.md`.*
