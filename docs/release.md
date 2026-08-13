# Cutting a TestFlight release

The stable runbook. It deliberately contains **no status for any particular
release**: a status table for one submission goes stale the moment the next one
happens, and a runbook that carries one drifts out of date without anyone
noticing. The procedure lives here; the status of a specific submission is
tracked outside this repository.

## One command

```bash
Tools/release.sh
```

Tests → bump the build number → archive → export → upload to TestFlight. It
refuses to run on a dirty tree or from a non-`main` branch, because a build
you cannot identify from a commit is a build you cannot debug later.

It also refuses — before the test gate and before the bump — when the bundled
`HeikoTranslate/Resources/Secrets.plist` cannot possibly hold a working key:
missing file, blank `GEMINI_API_KEY`, or the template's `REPLACE-ME` (GitHub
#89). The archive ships whatever that plist contains, and no other gate can
catch it: L1 never exercises the key, L3 takes its own from `Tools/local.env`,
and the build succeeds regardless. The check is structural — whether the key
is *live* stays L3's and `Tools/l2probe.sh`'s job. A release without
`APP_UPDATE_URL` gets a warning, not a refusal: the revoked-key sentence would
show with a tap that goes nowhere (#9). `deploy.sh` runs the same key
preflight.

Flags: `--no-tests` skips the L1+L3 gate (don't), `--no-l3` runs only L1 when
you have already run L3 this session, `--dry-run` archives and then restores
the build number, so a dry run leaves the tree exactly as it found it.


After a successful upload it commits the build-number bump to `main`. That is
the one commit exempt from the branch-and-PR rule (`CLAUDE.md`), because it
records which build number went to Apple.

No App Store Connect API key is needed. `Tools/ExportUpload.plist` sets
`destination: upload`, which uploads through the account already signed into
Xcode — the same one automatic signing uses. An API key is only worth creating
for unattended CI.

## When to bump the marketing version

`CFBundleVersion` (the build number) is bumped by the script on every release.
It always moves; nothing to decide.

`CFBundleShortVersionString` is the decision, and it is a real one. Apple:

> A review is only required for the first build of a version. Subsequent
> builds may not need a full review.

So the first build of a **new** marketing version waits for Beta App Review —
about a day, sometimes longer. Every later build of the **same** marketing
version reaches external testers in minutes.

**The test: would the beta description have to change for it to stay true?**

| Change | Bump? |
|---|---|
| A new language in the picker | **Yes** — the description lists them |
| A new control, or a visibly different interaction | **Yes** |
| Behaviour a tester would describe differently | **Yes** |
| Bug fix, crash fix, timing tune | No |
| Reconnect/backoff behaviour, logging, diagnostics | No |
| Docs, tests, tooling | No |

**The travelling exception overrides the table.** While Heiko is abroad and
depending on the app, do not bump the marketing version for anything that could
ship without it. A day of review is a day he has no working translator, and
that cost is far larger than a tidy version number. Ship the fix on the current
version; bump when he is home.

## After the upload

1. Wait for processing (5–15 min), then the build appears under TestFlight.
2. If the marketing version is unchanged and its first build was already
   approved, the new build reaches the external group without a full review.
3. If it is a new marketing version, it goes to Beta App Review and you wait.
4. Builds expire **90 days** after upload. Cut the build Heiko actually travels
   with close to the trip, not months ahead.

## Key rotation and the revoked-key sentence

`Tools/rotate-key.sh` mints the replacement key and runs this same release
path. The order is **revoke first, then ship** — safe because a build that
meets a revoked key (from 2.3, GitHub #9) confirms it over REST and shows
one sentence: *"Diese Version der App funktioniert nicht mehr. Zum
Aktualisieren antippen."* The tap opens `APP_UPDATE_URL` from
`Secrets.plist`: add it there once (see `Secrets.plist.example`) and every
build carries it. The value is the unlisted App Store link and is never
committed — the plist is gitignored. Builds older than the sentence fail
silently until updated; that residual is accepted on #9.

## Things that have bitten

- **A locked iPhone reports as "unavailable"** to `devicectl`, which looks
  exactly like "not plugged in". Only relevant to `deploy.sh`, but it has cost
  this project more time than any bug in the app.
- **The version shown in the app** is `CFBundleShortVersionString` +
  `CFBundleVersion` joined, e.g. `2.3.35`. The build number is the part that
  moves; that is why "did my phone update?" stays answerable without touching
  the marketing version.
