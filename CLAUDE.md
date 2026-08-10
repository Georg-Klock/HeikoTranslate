# Heiko Translate

One-button iPhone app: live voice translation DE↔EN / DE↔ES via the Gemini
Live API (`gemini-3.5-live-translate-preview`). Built as a gift for a German
speaker with no English and no interest in software. **Simplicity beats
features** — if a choice is between "more capable" and "impossible to get
wrong", choose the latter.

## What is public, and what is not

**This repository is public.** It is Georg's portfolio: the point is that a
designer with no engineering background can direct AI to build a real,
tested, shipped iOS app, and that the record of it holds up to someone who
reads code for a living. So the bar is *higher* than for a private repo, not
lower. Nothing here is written to impress; it is written to be true and to
survive being read closely.

What that means concretely:

- **The work is public. The working-out is not.** A decision, its evidence
  and its trade-offs belong in `SPEC.md` / `TESTING.md` / `docs/` / an issue.
  The prompts that produced them, the drafts, the false starts thought
  through in prose, the notes-to-self — those go in `private/` (gitignored).
  Not because they are shameful, but because they are Georg's process rather
  than the project's substance, and publishing process invites the reader to
  review the process instead of the app.
- **Seed prompts never get committed.** They are transient scratchpads and
  they name internal reasoning. `private/` is where they live. A prompt in
  `docs/` is a bug.
- **Other people are not material.** The app has real users who did not sign
  up for a public repository. Nothing personal about them is committed:
  likeness, devices, accounts, contact routes, whereabouts, or personal
  circumstances. Most of all, **nothing anyone said**. The diagnostic log
  carries both sides of every turn; `logs/` is gitignored and stays that way,
  and no transcript excerpt is pasted into a doc, an issue, or a commit
  message. Where a real failure has to be described, the mechanism is kept and
  the utterance is replaced with an invented equivalent.
- **Account and machine identifiers are not project facts.** Vendor order and
  support-case numbers, hardware UDIDs, developer team IDs, e-mail addresses
  beyond the published support one. Machine-local values go in
  `Tools/local.env` (gitignored), and a script that needs one reads it from
  there and fails with instructions when it is missing.
- **Nothing committed or posted may reveal the machine it was made on.** No
  absolute paths into a home directory — write repo-relative paths, or `~/`
  where a real location is unavoidable. This covers commit messages, issue and
  PR text, code comments, docs, and pasted terminal output, which is the usual
  leak: shell prompts, `xcodebuild` output and stack traces all carry a full
  path. Trim before pasting. **Git identity is configured per repository**
  (`git config user.name` / `user.email`), never left to whatever the machine
  defaults to — that default is an account name, and an account name invites a
  reader to guess whose machine it is and whether it was theirs to use.
- **Positioning copy is not documentation.** Case-study framing, tone and
  narrative choices are marketing, written about real people and with them in
  mind. It reads very differently next to source code. Keep it in `private/`.
- **Submission paperwork is not documentation.** App Store and TestFlight
  submission narratives carry review contacts, account details and per-release
  status. `docs/release.md` holds the runbook; the paperwork stays in
  `private/`.

### Who authored what

The point of the repository is that AI wrote most of this code under a
designer's direction. So the commit log says exactly that, in git's own terms
rather than in a footnote:

- **Claude is the `Author`. Georg is the `Committer`.** Author is who wrote
  the change; committer is who applied it. GitHub renders this as *"Claude
  Opus 5 authored, Georg Klock committed"* on every commit — visible in the
  log, on the blame view, and in the API, without anyone having to read a
  trailer.
- **Use the specific model name**, `Claude Opus 5` or `Claude Fable 5`, not a
  generic "Claude" or "AI". Which model wrote which commit is a real fact
  about this project and it costs nothing to keep.
- **Set it per commit, not globally:**

  ```
  GIT_AUTHOR_NAME="Claude Opus 5" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
    git commit -m "…"
  ```

  The committer comes from the repository's own `user.name` / `user.email`.
- **No `Co-Authored-By` trailer when Claude is the author** — it would name
  the same party twice. The trailer is for the other direction: a commit Georg
  wrote himself with Claude assisting keeps Georg as author and credits Claude
  in the trailer.
- **Commits Georg genuinely wrote stay his.** The practice is there to make
  the split legible, which only works if it is accurate in both directions.
  Do not blanket-attribute.

This was applied across the whole history on 2026-08-10, so the split is
legible from the log rather than asserted here.

### Writing in public, under Georg's name

Issues, PR descriptions and review comments are pushed with Georg's
credentials, so **every word an AI-assisted session writes there is published
as his**. Two rules follow, and they are the whole of it:

- **Write in one voice — the project's.** Describe the code, the evidence and
  the decision. Do not narrate the session, and never refer to Georg in the
  third person from his own account ("Georg decided…") — from his own login
  that reads as either affectation or a machine that forgot whose mouth it was
  speaking out of. Say "the decision was", or attribute it plainly to him in a
  sentence that a person could have written about their own project.
- **Keep the corrections; drop the confession.** "This claim was wrong, here
  is the measurement that shows it" is the most credible thing in an
  engineering record and it stays. Narrating the mistake-making itself is
  self-flagellation in someone else's voice — cut it. State what was wrong,
  what is true, and what changed. No apology, no post-mortem.

Where a session's output is substantially AI-written, say so once, plainly,
rather than letting a reader work it out from the seams. Building this way is
the point of the project; hiding it is what would look bad.

## Read first

- `SPEC.md` — product truth. Invariants R1–R8 (§5) are non-negotiable; a
  build that violates one is broken regardless of what else works.
- `TESTING.md` — test levels L1–L4. **L1–L3 must pass before any device
  (L4) testing.** Update its status tables in the same session as the work.
- `docs/ARCHITECTURE.md` — current technical truth: why exactly two
  concurrent sessions (one per side of the language pair), turn arbitration,
  verified wire-protocol findings. It also carries a clearly-marked
  historical section on the old three-session design — don't mistake it for
  current behaviour.
- `docs/history.md` — the original design writeup; historical only, do not
  trust where it disagrees with SPEC.md or the code.
- `docs/release.md` — how to cut a TestFlight build, and the rule for when
  a change earns a marketing-version bump. Stable runbook; it deliberately
  holds no per-release status, which goes stale by design.

## Commands

- Regenerate the Xcode project after editing `project.yml`:
  `xcodegen generate`
  **Also after switching branches**, whenever the two branches differ in which
  files exist. `HeikoTranslate.xcodeproj` is generated and gitignored, so it
  does not move with the checkout: it keeps referencing a file the new branch
  does not have and the build fails with `Build input file cannot be found`,
  which reads like a missing file rather than a stale project.
- L1 logic tests (fast, no device):
  `xcodebuild test -project HeikoTranslate.xcodeproj -scheme HeikoTranslate -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet`
- L2 protocol probe (talks to the real API, costs a fraction of a cent):
  `python3 Tools/livetest.py --text "a test sentence" --target de`
- L3 replay tests (recorded audio through the real session + turn logic):
  `Tools/l3replay.sh` (all cases) or `Tools/l3replay.sh TestAudio/en_short.wav`
- Open a PR for the current branch: `gh pr create`
- **L1, one command:** `Tools/l1.sh`. Use this and not a hand-typed
  `xcodebuild test` — it asserts a **non-zero** test count, so a scheme that
  builds no test target fails instead of exiting 0 and looking like a pass.
  `deploy.sh` and `release.sh` both call it.
- **CI runs L1 on merges to `main`**, not on pull requests
  (`.github/workflows/l1.yml`), and skips documentation-only changes. The
  per-PR trigger was dropped on 2026-08-08: at the macOS billing multiplier it
  consumed most of the monthly Actions allowance re-verifying what had already
  passed locally, with no failures it caught. What no local gate covers is the
  MERGE COMMIT — nobody tests the merged result — and that is what the
  remaining job guards. Run it by hand on a risky branch with
  `gh workflow run L1`. Still no L3 in CI: it needs the API key and is
  known-flaky by design.
- Cut a TestFlight build (tests → bump → archive → export → upload):
  `Tools/release.sh` — see `docs/release.md` before the first one.

## Rules for this codebase

- **Tests must exercise the real app types** (`@testable import
  HeikoTranslate` or compiling the real source files in). Never re-implement
  app logic inside a test file — a mirror copy passes forever while the app
  regresses.
- Turn-taking decisions live in `HeikoTranslate/Models/TurnLogic.swift`
  (pure, no audio/network) so they stay testable. Don't grow decision logic
  inline in `GeminiLiveTranslationService`; add it to `TurnLogic` with a
  test.
- When behavior changes, update SPEC.md / TESTING.md / ARCHITECTURE.md in
  the same session. Drifted docs are worse than no docs.
- **Work on a topic branch and land it through a PR — never commit to
  `main`.** Start with `git checkout -b <topic>`, commit at every working
  state, and `git push` often — the GitHub remote
  (github.com/Georg-Klock/HeikoTranslate) is the offsite backup, and an
  unpushed commit only exists on one SSD. That remote is **public**, so a
  push publishes: check the diff against "What is public, and what is not"
  before pushing, not after. Deleting a file in a later commit does not
  unpublish it — the history is public too. Open the PR with `gh pr create`
  when the work is reviewable. **Merging to `main` is Georg's call**; an
  AI-assisted session does not merge its own PR without him saying so.
  The cadence is unchanged — commit early, push often — only the ref
  changes. `main` is the branch TestFlight builds are cut from, so a
  change reaching a real user should have passed a human's eyes first.
  **One narrow exception:** `Tools/deploy.sh` and `Tools/release.sh` commit
  the build-number bump themselves (to whatever branch you are on, so on
  `main` that means directly). That commit records which code produced
  which build number; routing a one-line counter through a PR would be
  ceremony, and the alternative — not recording it — is how you end up
  unable to say which commit produced a build. Nothing else lands on
  `main` without a PR.
- Never commit `HeikoTranslate/Resources/Secrets.plist` (gitignored — keep
  it that way).
- Design iteration images go in `design/`, never the repo root.
- **Bump `CFBundleVersion`, not `CFBundleShortVersionString`.** The pill in
  the app's corner shows both, joined — `2.3.34` — so the build number is
  what has to move for "is my phone current?" to stay answerable. No
  parentheses. `Tools/deploy.sh` increments it automatically on every run
  (`--no-bump` opts out), so this is no longer something to remember.
- **The number on the pill is the build number, everywhere, always.**
  One counter in `project.yml`, shared by `deploy.sh` and `release.sh`. It
  only goes up, it is **never reverted**, and both scripts commit it — so
  any number read off a screen maps to exactly one commit. Reverting a bump
  after a device install makes that build untraceable, which is why the
  counter never goes backwards. A device build and a TestFlight build never
  share a number and never disagree; they are just successive values of the
  same counter. The older rule — bump the marketing version every time — was
  right when the pill showed only `CFBundleShortVersionString`, and wrong once
  the app went to TestFlight.
- **Leave `CFBundleShortVersionString` alone unless you mean it.** Apple
  reviews the *first build of a version* — "A review is only required for
  the first build of a version. Subsequent builds may not need a full
  review." Changing it puts every update to Heiko behind a fresh Beta App
  Review (about a day) instead of reaching him in minutes. The concrete
  test — **would the beta description have to change to stay true?** New
  language, new control, changed behaviour a tester would notice: bump it.
  Bug fix, timing tune, log change, doc change: don't. Full rule and the
  travelling exception in `docs/release.md`.
- Valuable one-off scripts get saved to `Tools/`, not left in a session
  scratchpad (scratchpads are deleted).
- **Anything durable but not publishable goes in `private/`** (gitignored,
  see `private/README.md`): seed prompts, drafts, paperwork, positioning
  copy, notes to self. It is the answer to "this is worth keeping but does
  not belong in a public repo", so that the answer is never "commit it and
  delete it later" — which does not work, because history is public.
  `private/` is **not backed up by the remote**; back it up separately.
- **Run `Tools/privacy-check.sh` before any push to a public remote.** It
  applies `private/hold-back-patterns.txt` to **every tracked file**, not just
  the review archive, and fails the run on a hit. That gap is not theoretical:
  the patterns existed for months while a family relationship sat in a design
  doc, a distance in two source comments, and a developer team ID in the build
  config — each already named by a pattern that was never pointed at those
  files. It also refuses to pass on an empty file list, and flags anything
  tracked under `private/` (a `git mv` into a gitignored directory still
  stages the file, and ignore rules do not apply to already-tracked paths).
  Reviewed exceptions live in `private/privacy-allow.txt`, scoped to a pattern
  AND a line so they cannot blind the check to the rest of a file.
  **Two gates do not depend on the pattern file at all**, because the pattern
  file is exactly what failed the one time this mattered: a device identifier
  copied out of `Tools/local.env` into a test fixture passed the check and was
  pushed to the public remote (2026-08-10, PR #42). So (1) **any** UUID-shaped
  string in a tracked file fails unless it is listed in `SYNTHETIC_UUIDS` in
  the script — invented fixtures should look invented, a run of repeated
  nibbles rather than anything a tool could have produced; and (2) the values
  in `Tools/local.env` are read at run time and searched for literally, so the
  check can catch them without ever containing them. A force-push does not
  unpublish a commit, which is why these are structural rather than a list
  someone has to remember to extend.
- **Run `Tools/l1.sh` before opening a PR, and put the result in the PR
  body** ("L1 90/90"). Since CI no longer runs on pull requests, this is the
  only thing standing between a branch and `main` — and unlike a CI check,
  a reviewer can see whether it was actually done. A PR that does not state
  its L1 result has not been tested; treat it as unreviewable rather than
  guessing.
- **Run L1 AND L3 before every device deploy** (standing rule,
  2026-07-29). `deploy.sh` now runs L1 itself and refuses to build if it
  fails, so only L3 is on you. L3 talks to the live API and costs a few
  cents; a single flaked assertion gets one rerun, twice-in-a-row is a real
  regression (TESTING.md §L3).
- One command does build → wait → install → pull logs: `Tools/deploy.sh`
  (add `--no-build` to skip rebuilding). The phone must be **unlocked** — a
  locked iPhone reports as "unavailable", which looks identical to "not
  plugged in" and has cost this project more time than any app bug.
- If the cable won't cooperate at all, the log can be shared straight off
  the phone: the language pill (top centre) → "Protokoll an Georg senden" →
  AirDrop/WhatsApp/Mail. That row is one tap from the pill — which replaced
  the old gear — and in German **on purpose** — Heiko speaks no
  English, so anything he might be asked to do must be readable by him.
  `Tests/GermanUITests.swift` fails the build if a new user-facing string
  appears that hasn't been reviewed for language.
- Logs can also upload themselves: set `DIAGNOSTIC_UPLOAD_URL` in
  `Secrets.plist` and the app POSTs its log on backgrounding. Absent by
  default, and absent means nothing is ever sent. The log contains
  conversation transcripts — Heiko's and his counterpart's — so that switch
  is a decision about other people's speech, not just about debugging.
- The app writes a diagnostic log on device every launch. After any device
  session that misbehaved, run `Tools/pull_logs.sh` and read it before
  theorising — this project has lost time to guessing at timing bugs that
  the log would have named outright.
