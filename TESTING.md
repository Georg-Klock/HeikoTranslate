# Heiko Translate — Test Plan

The point of this document: **catch bugs before they reach a human tester.**
Every rule in SPEC.md §5 gets a test. Manual testing is the last step, not
the first.

## Test levels

| Level | What it checks | Needs a person? | Needs the phone? |
|---|---|---|---|
| L0 — Tooling | The build-number pipeline survives failure midway | No | No |
| L1 — Logic | Turn/alignment rules in isolation | No | No |
| L2 — Protocol | The live API behaves as we assume | No | No |
| L3 — Replay | Recorded audio through the real pipeline | No | No |
| L4 — Device | Mic, speaker, echo, feel | Yes | Yes |

**Rule: L1–L3 must all pass before asking for L4.**

---

## L1 — Logic tests (no network, no audio)

The turn logic is pure decision-making, extracted into
`HeikoTranslate/Models/TurnLogic.swift` precisely so it can be tested
without audio hardware. `Tests/TurnLogicTests.swift` exercises **that real
type** via `@testable import HeikoTranslate` — never a re-implementation
inside the test file (a mirror copy passes forever while the app
regresses; we made that mistake once).

Run:

```
Tools/l1.sh
```

Use the script rather than calling `xcodebuild test` by hand. It asserts that
a **non-zero** number of tests ran and all passed — a scheme that builds no
test target exits 0 and is otherwise indistinguishable from a green suite.
`-quiet`, which the old inline command passed, hides the "Executed N tests"
line that is the only proof the suite ran at all.

`deploy.sh` runs it before it bumps the build number, and `release.sh` runs it
before it archives. CI runs it on pull requests (against the preview merge)
and on merges to `main` (restored 2026-08-10; it was main-only since
2026-08-08). Running it locally before opening a PR and stating the count in
the PR body is still the rule — the CI run is what a reviewer checks that
stated count against.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.1 | Detected language = English | Translator = German session; bubble = LEFT | R2 |
| L1.2 | Detected language = German | Translator = partner session; bubble = RIGHT | R2 |
| L1.3 | Detected language = Spanish | Translator = German session; bubble = LEFT | R2 |
| L1.4 | German after English | Translates to English | §3.1 |
| L1.5 | German after Spanish | Translates to Spanish | §3.1 |
| L1.6 | German first, nothing heard before | Translates to English (default) | §3.1 |
| L1.7 | One utterance, both finalize paths fire | Exactly ONE bubble emitted | **R1** |
| L1.8 | Finalize fires before language is known | NO bubble emitted (wait) | **R3** |
| L1.9 | Turn ends | All per-turn state cleared, partner memory kept | R1 |
| L1.10 | Next utterance after a turn | Language re-detected from scratch | R2 |
| L1.11 | Different detection after the turn locked | Locked language wins; partner memory untouched | R2 |
| L1.12 | Unrecognized language code (live: "ja" for English) | Ignored entirely | R2 |
| L1.13 | Translator session silent, another has output | Fall back — but German stays one side; EN↔ES never pairs (§3.1) | R3 |
| L1.14 | Whitespace around text | Trimmed; whitespace-only counts as absent | R3 |
| L1.15 | Codes re-announce the previous turn's language ≤2.5s after it ended | Ignored; a different language counts (fast reply, R4) | **R2** |
| L1.16 | Sessions disagree on the transcript | Translator session's transcript wins | R5 |
| L1.17 | Opening detection burst unanimously wrong, corrected ~1s later | Plurality after the settle window wins | **R2** |
| L1.18 | Short turn never settles a vote | Commits by plurality — utterance not lost | R4/R8 |
| L1.19 | Stray code long before real speech | Stale tally expires; settle window stays intact | **R2** |
| L1.20 | Codes claim German but the German session translated substantially | Session behavior beats the codes: LEFT, German translation | **R2/§3.1** |
| L1.21 | The measured per-language session behavior table | Pinned as tests so the direction rule argues with data | §3.1 |
| L1.22 | German session emits a false start ("Ich") next to full partner output | Not a translation: turn commits as German | **R2** |
| L1.23 | Partner sessions translate first (English echoes!) | Proves nothing until German stays silent ~1.2s | **R2** |
| L1.24 | Codes settled foreign while only the partner session output (echo) | noteOutputs refuses homeSpoken — echo audio must never play as a translation | **R2/R6** |
| L1.24b | Home codes settled, confirm window elapses with NO new event | Late time-only re-check still resolves homeSpoken (recheck clock) | R4 |
| L1.25 | Stragglers settle the wrong language during silence, real speech votes unanimously against it | Three consecutive contradictions overturn the poisoned settle; the turn commits | **R2/R4** |
| L1.25b | Normal alternating lying codes (en,de,en,de) after a settle | Never three consecutive — the settle holds | **R2** |
| L1.26 | Spoken number: home translation "14 Euro" (7 chars), codes settled foreign | Floor waived when codes corroborate — commits LEFT | **R2/R4** |
| L1.26b | Tiny home output, codes unsettled or settled home | Floor holds — false starts still can't decide a turn | **R2** |
| L1.29 | Pick the home language on the PARTNER wheel (sides collide) | Sides swap and the pair applies **exactly once** | **R8** |
| L1.29b | The same colliding pick on the HOME wheel | Symmetric observer, also exactly one apply | **R8** |
| L1.29d | An ordinary non-colliding pick | Still applies once — the fix must not silence real changes | **R8** |
| L1.29e | Every language picked on either wheel | The pair is never left with both sides equal (SPEC §4.4) | **R8** |
| L1.34 | A 2-2 vote across the settle window | No settle — a tie is not broken by enum order | **R3** |
| L1.35 | A turn containing only partner output | Still ends a turn, so the straggler grace is armed | **R3** |
| L1.36 | A commit that rejects | No direction and no translator left behind | **R1/R2** |
| L1.37 | Home output arriving after the commit | The committed side is final | **R1** |
| L1.38 | Another language's codes inside the straggler grace | They count — a reply is not a straggler (intended) | **R3** |
| L1.30 | Reconnect timer armed before a mute, fired after the unmute | Inert — must not replace the session that succeeded it | **R7/R8** |
| L1.30b | A superseded session's late event | Cannot act as its successor (no early mic open) | **R4** |
| L1.30c | Any event or timer from a stopped run | Nothing from it is current | **R8** |
| L1.30d | A `nil` token, including against a cleared registry | Never current — `nil == nil` must not validate | **R7** |
| L1.30e | One language reconnects | The other language's in-flight work is untouched | **R7** |
| L1.30f | A token used for a different language | Not current | **R7** |
| L1.31 | Short home translation beside a LONG partner echo, codes settled foreign | Committed — corroboration rescues it below the ratio floor | **R2/R4** |
| L1.31b | 3-char false start beside a full echo, codes settled foreign | Still rejected — the absolute floor holds | **R2** |
| L1.32 | An error is showing before the first successful start | The "tap to speak" hint is suppressed, and returns when it clears | **R8** |
| L1.33 | A turn commits after an earlier deferral | The wait budget resets for the next turn | **R1** |
| L1.33b | Each rejection reason in turn | Only codes-veto / no-translation wait; the rest give up | **R3/§5.1** |
| L1.33c | Repeated recoverable rejections | Bounded at 3 waits (~6s), then gives up and resets | **R8** |
| L1.33d | Teardown mid-wait (mute, stop) | Budget cleared, next run not starved | **R8** |
| L1.33e | Reasons carrying interpolated detail | Matched by substring — exact matching would never wait | **R3** |
| L1.41 | "14 Euro" (7 chars) beside a 26-char echo, codes settled foreign | Committed — the measured case #23 was filed for | **R2/R4** |
| L1.41b | Short corroborated output with an echo and without | Floor applies only beside an echo; "Ja"/"Nein" survive alone | **R2** |
| L1.39 | Each connection quality | Severity tracks the quality, not the copy's spelling | **R8** |
| L1.40 | Interruption-ended options, with and without `.shouldResume` | Parsed exactly — recorded in the log, not obeyed | **R7** |
| L1.41c | Interruption arms a resume, the user starts by hand, it ends | Exactly ZERO automatic starts — the tap owns the session | **R7/R8** |
| L1.41d | An armed resume, iOS withholding `.shouldResume` | Resumes anyway, exactly once; a repeat trigger does nothing | **R7/R8** |
| L1.41e | A resume that failed, then one that started, then a manual tap | Only a started resume speaks; informational; cleared by the tap | **R8** |
| L1.41f | Muted / warning / notice in every combination | One slot, one explicit precedence | **R8** |
| L1.42 | Permission granted in Settings, app returns | The denial clears and the button starts listening again | **R8** |
| L1.43 | The German string set | Exactly the reviewed wording, asserted on the real values | **§4.3** |
| L1.44 | All six language sets | Complete, keep their number placeholder, and none is still German | **§4.3** |
| L1.45 | Six wheel notches in rapid succession | Six persists, ONE session restart | **R7/#1** |
| L1.45b | A manual tap while a restart is pending | The restart is dropped — the tap owns the session | **R8** |
| L1.46 | A cold launch, before any tap | Glyph reads muted, notice stays silent — two rules, disagreeing on purpose | **R8** |
| L1.46c | Every combination of listening / launching | The glyph is muted whenever nothing is running; `hasEverStarted` does not enter into it | **R8** |
| L1.47 | A fresh install, no stored settings | Opens ME: German, YOU: English | **§4.1** |
| L1.46b | Every combination of listening / launching / has-started | Muted needs a session the user started — the other seven are not | **R8** |
| L1.47 | The measured #75 replay: a full-length round-trip echo, codes settled on the PARTNER | RIGHT via the partner session — echo disqualified, veto yields | **R2** |
| L1.47b | The same echo with codes settled on HOME (the referee-log pattern) | RIGHT — there the ratio path alone was the failure | **R2** |
| L1.47c | A one-token identical output ("Navigator") | Still a translation — cognates, numbers and names stay LEFT | **R2** |
| L1.47d | A third language's long translations in both sessions | LEFT via home — a real translation shares no tokens with the heard text | **R2** |
| L1.47e | Codes settled on a language that is NEITHER side | Still vetoed — no session translated into the reader's language | **R3** |
| L1.47f | A partner output that is itself the echo, or a settle with no partner-session votes at all | Veto holds — the yield needs positive evidence that HOME was spoken, not a plausible-looking translation | **R2/R3** |
| L1.47g | `noteOutputs` on the same #75 data | homeSpoken after the confirm window — streaming and commit agree | **R2** |
| L1.47h | Both sessions misread half the German, crossed (after-run 1) | RIGHT — the union echo test sees the round trip for what it is, and the crossed per-session votes carry the yield | **R1/R2** |

Routing on per-session evidence (#83/#84, 2026-08-10). The tell is no longer
token overlap — which was letting plurals and apostrophes decide who spoke —
but WHO reported which language. `noteInputLanguage` now records the
reporting session, and a yield needs the partner's own reading to corroborate
that home speech happened.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.48 | An English paraphrase-echo of English speech (#83's five-row table) | All five drop — before the fix, three committed the partner's speech as Heiko's | **R2** |
| L1.49 | A genuine home translation that preserves names: 0.80 token overlap, codes settled | Commits — names and numbers surviving translation are what a CORRECT translation looks like | **R2** |
| L1.49b | The same turn with the codes not yet settled | Commits — the shipped rule resolved home-spoken off the partner echo and put the foreign sentence in Heiko's bubble | **R1/R2** |
| L1.50 | Run 6's real event order: the echo prefix arrives before the votes that expose it | The provisional foreign direction clears and re-derives instead of latching | **R2** |
| L1.51 | Four output tokens judged against ONE heard token | Not an echo — the token floor is two-sided, as documented since #75 | **R2** |
| L1.54 | One stray partner vote for home against a fresh foreign settle | Veto holds — corroboration needs a quorum, a lone stray is not testimony | **R2** |
| L1.54b | A quorum of home votes amid a run of unmapped codes ("ja"/"pt") | Veto holds — unmapped codes are competing testimony from the same witness | **R2** |
| L1.55 | Partner-home votes from a dead context (gap > `voteExpiry`) | They expire with the global tally — stale evidence cannot lift a fresh veto | **R2** |
| L1.56 | A provisional homeSpoken, then a late foreign settle arms the veto | The direction clears — `translator` must not keep naming the partner session | **R1/R2** |
| L1.57 | Run 6 interleaved exactly as the service sees it, `noteOutputs` re-run per code | provisional-foreign → cleared → homeSpoken; streaming and commit agree | **R2** |
| L1.58 | Two mapped home codes from the partner session | Session-local noise — not enough to override a settled foreign veto | **R2** |
| L1.59 | A partner-home quorum that arrives only AFTER a real foreign verdict | No override — the #75 signal is evidence that helped FORM the settle | **R2** |
| L1.60 | Crossed evidence whose quorum completes after the partner-language settle | Still valid — the partner had already testified HOME before that settle formed | **R2** |
| L1.61 | A settled stale context, not merely an unsettled tally | Expires as a whole, per-session evidence included | **R2** |
| L1.62 | A provisional translator with PCM already queued | No playback — irreversible audio needs a committed turn, not a guess | **R1** |

A home settle **backed by the full crossed shape** outranks the home session's
output (build 2.3.48 device evidence, 2026-08-10). The codes settled on HOME
and the partner session's own votes agreed, yet `noteOutputs` consults
`homeIsRealTranslation` first and its size ratio kept reading the home
session's streamed echo as a real translation: the direction flipped six times
in four seconds while the speaker was still talking. The bubble was still
correct and no audio played early — the committed-audio gate held — so this
was a live-line defect, not a wrong-side one. Below `echoMinTokens` (4) an
echo prefix cannot be *detected* as an echo, so the early streamed chunks fall
straight through to the ratio.

**The settle is not a second witness.** `spokenLang` comes from a pooled tally
that already contains the partner session's votes, so "settled home + partner
says home" can be one noisy session counted twice. Independence comes from the
HOME session's own reading, which partner noise cannot forge — hence the full
crossed shape, each session reporting the other's language by its own
plurality and quorum. L1.64e is that lesson; it was a wrong-side commit in
review of #47, not a hypothetical.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.64 | The measured 2.3.48 code sequence, then both outputs streamed word by word | Never reads foreign, settles the side once — the reproduced flip was 3 oscillations in the first 3 chunks | **R2/R3** |
| L1.64b | `commit` on that same state | RIGHT/home via the partner session — live line and bubble cannot disagree (L1.47g's doctrine) | **R2** |
| L1.64c | L1.20's shape: codes settled home, **no** partner votes, a substantial home translation | LEFT — the crossed shape never forms, so session behaviour still beats the codes | **R2** |
| L1.64d | A foreign settle | Unaffected — the existing veto and its narrow crossed yield still govern | **R2** |
| L1.64e | An ordinary foreign turn where the partner session alone emits a quorum of stray home codes | LEFT via the home session — one session cannot be its own corroboration, even though it carries the pooled settle too | **R2** |

Speech end, mic-aware (#21 precedent, 2026-08-10). `SpeechEndPolicy` is pure,
so L1 and the L3 harness run the same rule the app runs. The transcript-idle
timer proposes; the microphone disposes.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.52 | The idle timer fires 148ms after a loud mic buffer, speaker mid-sentence | Release defers — the mic outranks a lagging transcript | **R5** |
| L1.52b | The same turn once speech genuinely ends | The deferred release proceeds | **R5** |
| L1.52c | A normal quiet release (≥1s since any loud buffer) | Zero added latency — release stays on the original schedule | **R5** |
| L1.52d | No loud mic buffer this session (silence, or a dead route) | The gate holds nothing | **R5** |
| L1.53 | A restaurant-loud room — babble the RMS floor was never calibrated against | Defers only to `maxMicExtension`, then degrades to the OLD behaviour | **R5** |
| L1.53b | A breath pause with speech resuming into the deferral | Stays deferred until the speaker actually finishes | **R5** |

Commit diagnostics. Evidence only — these must never influence which
transcript `TurnLogic` commits.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.63 | The two sessions disagree on a number at commit | Both readings logged, in a deterministic order, so selection failure is distinguishable from shared mis-transcription | **diagnostic** |
| L1.63b | An active session with no text; a transcript carrying quotes and newlines | Every active session logged and escaped, so no transcript can forge a log line; a non-active session's stale input is excluded | **diagnostic** |

The replacement window (#15, 2026-08-10). On every renewal — the routine
goAway after ~9 minutes, or an abrupt drop — the fresh WebSocket used to be
fed mic audio before its own `setupComplete`, because the sending paths
selected on "not dead" and `reconnect` never cleared readiness. Sessions are
faked at the `LiveTranslationSocket` seam; a fake's events take the shipping
route into the handler, registry token check included. Verified by
reintroducing the original selection: all four cases fail.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.67 | A goAway renewal, mic open, speech continuing | The replacement receives NOTHING before its own setupComplete, then the held chunks exactly once, oldest first, then live; the other side of the pair streams uninterrupted | **R7/R4** |
| L1.67b | An abrupt drop, including the cooldown before the reconnect exists | The closed session is not fed while the reconnect waits; speech from the whole gap is delivered once after the new setup | **R7/R4** |
| L1.67c | A session error during a replacement window | Held audio is dropped, not delivered stale seconds later; the healthy side is unaffected | **R7** |
| L1.67d | More speech during the window than the queue holds | A rolling ~3.2s window — newest chunks win, staleness stays bounded however slow the reconnect | **R4** |

> Beyond the numbered rows: `FillerWordTests` / `FillerWordsFromDeviceTests` /
> `FillerWordFalsePositiveTests` cover hesitation stripping (including the
> seven real words an adversarial review caught the first version deleting),
> and `LiveDirectionMatchesCommitTests` pins that the live line and the
> committed bubble share one direction rule and cannot disagree.
>
> L1.30* live in `SessionRegistryTests` and cover `SessionRegistry`, the rule
> that decides whether an asynchronous continuation still belongs to the
> current run and session instance. Extracted for the same reason `TurnLogic`
> was: the service needs audio hardware and a network, so the rule was
> untestable inside it — and GitHub #20 was a defect in the #3 fix that lived
> exactly there. L1.30d is the one with teeth: reintroducing the naive
> `tokens[lang] == token` comparison fails it on both assertions, because
> `nil == nil` is true after a clear. L1.30 itself documents the semantic the
> service relies on rather than catching a registry defect — it passes against
> the naive version, since the original bug was the ABSENCE of any token.
>
> L1.29* live in `LanguagePairTests`, not `TurnLogicTests`, because the bug
> they pin (GitHub #1) was not in any function — it was in the wiring between
> two `@Published` observers, where a `defer`-released guard let one gesture
> apply the pair twice and race two `installTap` calls. Only driving the real
> observed properties can see it, so these drive `ConversationViewModel`
> itself. Verified by reintroducing the original wiring: both colliding cases
> fail with 2 applies, both non-colliding cases stay green.
>
> L1.31/L1.31b close the half of L1.26's problem its fix could not reach: the
> ratio branch returned early whenever the partner echoed, so settled codes
> could never rescue a short translation — and an echo is the common case for
> foreign speech. Verified by reintroducing the early return: L1.31 fails with
> a nil bubble (the turn swallowed outright), while L1.22/L1.22b/L1.26/L1.26b
> stay green, so the false-start guard was not loosened. GitHub #23.
> L1.33* cover `FinalizePolicy`, which the app AND `Tools/l3replay` now both
> compile. The harness previously had no deferral at all: it committed-or-wiped
> on the spot, so L3 reported swallowed turns the shipping app would have
> recovered by waiting. Measured 2026-08-04 across 19 live `de_after_es`
> replays: 58% of failures were turn-lost or turn-split — the exact shape the
> deferral prevents — against 11% genuine mis-attribution. Any L3 result from
> before this sharing carries that error bar (GitHub #21).
>
> L1.41/L1.41b close what L1.31 missed. #23 was filed against a measured
> `"14 Euro"` — **7 characters** — but the fix kept the uncorroborated 8-char
> floor in the echo branch, so the reported case stayed swallowed; L1.31 passed
> only because its example (`"14 Euro bitte"`) is 13. The echo branch now uses
> `minCorroboratedHomeOutput` (5), bracketed by the two measured points: the
> false start `"Ich"` (3) and the real translation `"14 Euro"` (7).
>
> The no-echo branch keeps accepting any corroborated output, and L1.41b pins
> that asymmetry on purpose. An earlier draft applied the 5-char floor to both
> branches for symmetry; review caught that this newly rejected `"Ja"` (2) and
> `"Nein"` (4) — real German answers — to buy rejection of a no-echo false
> start with **zero observed instances**. A floor is worth having only where
> there is an echo to weigh against. L1.22/L1.22b/L1.26/L1.26b/L1.31/L1.31b all
> stay green, so the false-start guard was not traded away for it.
>
> Both floors are **German-calibrated character counts**, and `home` is not
> always German (L1.29e). Tracked in GitHub #38, not fixed here.
>
> L1.43 exists because the mic glyph's amber tint, its strike-through and the
> animation that draws it were keyed to `statusIsPaused`, which is true before
> the first tap — so the first frame of a fresh install showed a microphone
> struck through in `Palette.muted` directly above "Zum Sprechen antippen".
> `statusShowsMuted` is the property that separates never-started from
> muted-after-use, and the difference between the two is invisible in every
> state except that one, which is why nothing caught it for six review rounds.
>
> **What L1.43/L1.43b do and do not catch, stated because the difference
> matters.** The rule now lives in one pure function, `readsAsMuted`, for the
> same reason `bottomNotice` and `mayResume` do — L1.43b drives all eight
> combinations, including the two an instance cannot be put into without audio
> hardware (mid-launch, listening). Both were verified by breaking the code:
> collapsing `statusShowsMuted` into `statusIsPaused` fails L1.43, and dropping
> the `hasEverStarted` requirement fails L1.43b.
>
> What they still do **not** guard is the three bindings in `ContentView`.
> Those are `private` on a `View`, so no unit test can reach them, and
> re-pointing one back at `statusIsPaused` would reintroduce the bug with L1
> green. The seam narrows the target — one named rule instead of three
> open-coded booleans — but it cannot close that. Closing it needs a UI-test
> target, which the repo does not have and which is a decision about CI spend
> rather than a review checkbox.
>
> **Not covered by L1:** that the transcript honours the system text size.
> `@ScaledMetric` is a property wrapper on a `View`, so no unit test can read
> it; it was verified by capturing the same seeded transcript at `large` and at
> AX-XXXL and comparing the rendered text (see GitHub #43). Stated here rather
> than left implied.
>
> L1.42 covers the recovery `micPermissionDenied` never had: nothing cleared
> it, so getting the app working again depended on iOS terminating it when the
> microphone switch is toggled. `noteMicPermission(granted:)` is split out of
> the scene-phase handler precisely so a test can reach it — the branch was
> unreachable before, which is how it shipped unexercised. The scene-phase read
> itself (`AVAudioApplication.shared.recordPermission` on `.active`) stays
> outside L1: it needs a real permission state a test cannot set.
>
> L1.39-L1.41f are the GitHub #28 bundle. **L1.39** exists because the warning's
> colour was chosen with `warning.hasPrefix("Schlechte")` — the German copy was
> a control channel, so rewording the degraded warning would have silently
> turned it red with nothing failing. Text and severity are one value now.
>
> **L1.41c/L1.41d are the tests the first attempt could not write.** Arming
> `resumeWhenActive` needs `isListening`, and the notification handler was
> private, so the ownership fix rested entirely on a doc comment — for a
> failure mode that is *the microphone opening without the user asking*. The
> decision is now split out of the handler (`noteInterruptionBegan()`,
> `noteInterruptionEnded(options:)`, `noteBecameActive()`), which perform no
> audio work and return whether a resume is owed; the handlers are thin callers.
> `automaticResumeCount` makes "exactly one start" assertable, the same trick
> `languageApplyCount` plays for #1. L1.41c drives the last step through the
> real `toggleButton()` rather than the seam it calls, because asserting only
> on the seam would leave exactly the unreachable branch #28 shipped with.
>
> **The `.shouldResume` hint is recorded, not obeyed** (product decision,
> 2026-08-05). iOS almost always attaches an options value, so gating on it
> meant any interruption it did not mark resumable — an alarm, a timer — left
> Heiko silently muted until he noticed. A stop he does not notice is worse
> than a start he can see. L1.40 still pins the parser exactly, because the
> device log's answer has to be trustworthy; L1.41d pins that it no longer
> gates.
>
> **The notice speaks only for a resume that started.** `showMicNotice()`'s
> one caller in the app sits behind `noteAutomaticResumeFinished(started:)`,
> which L1.41e drives both ways — the rule is a function with a test rather
> than a statement ordering inside an async body, where nothing could have
> caught it. An earlier draft had exactly that ordering and no test failed when
> the call was moved above the `await`.
>
> **Three things are deliberately NOT covered**, and are here rather than left
> implied: the 5-second auto-dismiss is a `Task.sleep` and no test waits on it;
> the real `AVAudioSession` notification payload is not synthesised, so L1
> starts at the seam the handler calls, one line in; and no test drives a
> genuinely failing `beginListening()` — what is pinned is that a failed
> *outcome* raises no notice, not that a real failure produces that outcome.
> L1.34-L1.38 are the GitHub #26 bundle: five edge cases in the state machine,
> written as tests *before* any fix so they document the intended semantics
> either way. Four found real defects — an enum-order tie-break that settled a
> 2-2 vote arbitrarily and then armed the commit veto; an echo-only turn that
> never stamped `lastTurnEnd`, so the next turn's straggler grace was never
> armed; a rejected `commit` that still left `direction` (and therefore
> `translator`) set for a turn that produced no bubble; and `noteOutputs`
> flipping a turn's side *after* it had committed, while the service was
> flushing held audio for the old translator. **L1.38 found nothing, and that is
> its value:** `staleCodeGrace` (2.5s) being longer than `settleWindow` (1.5s)
> looks like a hole — a tally can settle entirely inside the grace — but the
> grace only ever filtered the *previous turn's* language, and a code for a
> different language is a fast reply that should count. The test pins that so
> the asymmetry is not "fixed" by someone reading the constants alone.
>
> L1.7 and L1.8 are the regression tests for the duplicate-bubble bug:
> two independent timers finalizing the same turn, one before the language
> was known — which produced two bubbles with opposite alignment.
> L1.8b also pins down that a *failed* commit doesn't latch R1.
> L1.15–L1.18 encode live-API behavior discovered by the L3 replays on
> 2026-07-25 (see §L3): straggler code events after a finished turn, garbage
> codes/transcripts from the session whose target equals the spoken
> language, and opening bursts that misdetect unanimously before
> self-correcting. Each was reproduced live before being pinned here.
>
> L1.47–L1.47g are the GitHub #75 bundle, written from an instrumented
> failing replay rather than a hypothesis. Two prior hypotheses died on
> measurement first: a third "referee" session (6/10 vs a 5/10 baseline —
> no tie for it to break; branch `feat/de-es-referee-session` kept) and
> #75's own home-silence-confirmation suspicion (the failing turn resolved
> through the ratio path; the confirmation window was never consulted).
> The per-event timeline (`L3_VERBOSE` now timestamps every IN/OUT chunk)
> showed the real mechanism: the de session mis-hears the German opening
> as Spanish, translates that misreading back into German, then repeats
> the rest verbatim — full-length output, ratio 1.1, every size floor
> passed. The tell is #45's: the output is built from the input's own
> words. Echo-share (fraction of output tokens already present in the
> turn's transcripts) measured over 20 replays / 39 outputs: genuine
> translations 0.00–0.17, echoes 0.80–1.00 — a clean gap, thresholded at
> 0.6 with a 4-token floor so #45's cognate/number/name rows keep
> counting as translations. Two rules share the primitive: a long
> high-share home output is no translation (L1.47/47b), and the
> codes-veto — whose premise is "the partner output is an echo" — yields
> when the settle is the partner language and the partner output proves
> itself a translation (L1.47, the failing run's exact shape: the
> mis-hearing session's votes had settled the codes on "es").
>
> The comparison sets differ on purpose, and the first cut got that
> wrong (L1.47h, from the first post-fix replay): when a session
> mis-hears German toward Spanish, its transcript converges on nearly
> the same Spanish the partner legitimately translates into, so against
> the UNION of transcripts the genuine translation read as an echo and
> the veto swallowed the turn — a wrong-side failure traded for a
> lost-turn one. An echo is damning in ANY session's reading (that same
> run put the home echo in the partner's transcript, not its own), so
> `isRoundTripEcho` keeps the union; a translation proves itself only
> against what the translating session ITSELF heard, so
> `looksTranslated` takes the session's own transcript. The known
> residual: the mirror shape (Spanish misread toward German after
> Spanish context) would poison the union in the other direction —
> zero instances in 30 measured runs, all mishearings ran home-ward
> with the priming, so it stays a documented non-case rather than a
> paid-for guard, per the L1.41b precedent. Verified against the old
> behaviour by neutering both predicates to constant-false: exactly
> L1.47, L1.47b, L1.47g and L1.47h fail, the other 42 pass — so the
> guards the old table pinned were not loosened.

## L2 — Protocol tests (real API, no app)

Standalone tools that talk to the Gemini Live API directly, proving
whether a problem is *ours* or *theirs*: `Tools/livetest.py` (one-shot
probes) and `Tools/l2expiry.sh` (session-lifetime probe, ~10–20 min,
compiled against the app's real `GeminiLiveSession`).

| ID | Check | Status |
|---|---|---|
| L2.1 | Handshake + setup accepted | ✅ verified |
| L2.2 | Transcription returns text | ✅ verified |
| L2.3 | Translated audio returns | ✅ verified |
| L2.4 | 60-word sentence fully transcribed | ✅ verified (56 words, 100%) |
| L2.5 | Session expiry sends `goAway` | ✅ observed (after ~9 min on 2026-07-25) |
| L2.6 | Reconnect after expiry works | ✅ verified (2026-07-25, `Tools/l2expiry.sh`): `goAway` at ~9 min surfaced as `.closed` — the reconnect trigger — and a fresh session translated 0.3s later |

## L3 — Replay tests (real pipeline, recorded audio)

Feed **recorded audio files** through the real pipeline — the app's own
`GeminiLiveSession` (wire protocol) and `TurnLogic` (turn decisions),
compiled straight from the app sources — against the live API, so the whole
translation stack can be tested without a person talking. Only the mic
itself and the finalization timers are emulated (`Tools/l3replay/main.swift`
mirrors the service's rules); audio hardware stays L4.

Run (talks to the real API; costs a few cents for the full suite):

```
Tools/l3replay.sh                    # all cases
Tools/l3replay.sh en_short de_after_es   # specific cases
L3_VERBOSE=1 Tools/l3replay.sh …     # + per-session event timelines
```

Recordings live in `TestAudio/` and are regenerated reproducibly by
`Tools/make_test_audio.sh` (macOS `say`, 16kHz 16-bit mono — the app's mic
format):

| File | Contains | Tests |
|---|---|---|
| `en_short.wav` | "Hello Heiko, how are you?" | Basic English→German |
| `de_short.wav` | "Mir geht es gut, danke." | Basic German→English |
| `es_short.wav` | "¿Dónde está la estación de tren?" | Spanish→German |
| `en_long.wav` | 60-word English sentence | **R5** truncation |
| `de_after_en.wav` | German following English | Direction memory |
| `de_after_es.wav` | German following Spanish | Direction memory + the three-session fix |
| `silence.wav` | 5s of silence | No phantom bubbles |
| `noise.wav` | Background noise, no speech | No phantom bubbles |

**Assertions per replay:**
1. Exactly the expected number of bubbles (**R1**)
2. Correct side for each (**R2**)
3. Original text present in full — word-count floor (**R5**)
4. Translation non-empty and produced by the RIGHT session, not the
   fallback (**R3**, §3.1)
5. No session errors, and unrecognized server messages surfaced

**Flakiness** (measured 2026-07-26, five full runs): expect an occasional
single-assertion flake — 56/56, 56/56, 55/56, 55/56, 56/56. This is a
live-API gate: model detection and timing vary run to run. One failed
assertion in an otherwise-green run means *rerun that case* before
treating it as a regression; the same case failing twice in a row is real.

**The de↔es mishearing** (2026-07-28; mechanism instrumented 2026-08-07,
GitHub #75): German after Spanish can be misheard by the de session as
Spanish, round-tripped back into German at full length, and read as a
real translation — the bubble lands LEFT via the home session. The
historical "~2 of 3 runs" figure predates the shared `FinalizePolicy`
(#21) and overstates it; measured baselines since: 5/10 correct
(2026-08-05, referee experiment) and 9/10 (2026-08-07, this fix's
baseline — the live model varies day to day, so single-day rates are
weather, not climate). A third "referee" session was measured and does
NOT help (6/10 vs 5/10 — the codes are not the tie it assumed; branch
`feat/de-es-referee-session` kept for reproducibility). The shipped
mitigation is echo detection (L1.47 bundle): direction accuracy for a
turn-2 side call is scored by `Tools/l3direction.sh`, 10 runs per
invocation, which is also where the before/after numbers for any future
change to this area should come from. Measured for the #75 PR
itself (2026-08-07): de↔es 9/10 → 10/10, with the misheard-echo shape
occurring in 3 of the 10 after-runs and corrected in all 3; the de↔en
control 10/10 → 10/10; the full suite 56/56 after. The intermediate
run that motivated L1.47h came from exactly this loop.

**Known model limitation** (2026-07-25): a *short* German sentence right
after Spanish context is misdetected as Spanish by every session for its
entire duration — transcripts come back half-Spanish ("Me geht es gut").
No client-side logic can fix that (SPEC §6: detection is the model's), so
`de_after_es.wav` uses a longer German reply, which the model detects
correctly after ~1s. The settle-window rule (L1.17) exists precisely so
that transient first second doesn't decide the turn.

## L0 — Tooling tests (no network, no audio, no Xcode)

```bash
Tools/tests/build-number-windows.sh
```

Runs in a couple of seconds and needs nothing installed — it stubs `xcrun`,
`xcodebuild` and `xcodegen`, so it is safe on any machine and in CI.

The invariant under test is the one #16 established and #22 found holes in:
**every build number that ever reaches a screen or Apple exists in exactly one
commit, and no number is ever reverted once it has been seen.** That only
breaks when something fails *midway*, so each case builds a throwaway git repo,
copies the real `deploy.sh` / `release.sh` into it, and makes a specific step
fail:

| Case | Fails at | Expected |
|---|---|---|
| deploy happy path | — | number bumped, installed, committed, tree clean |
| deploy | the build | number restored, nothing committed |
| deploy | the phone never appears | number restored |
| deploy | the post-install `devicectl info` line | number COMMITTED — the phone has it |
| deploy | the build, with a hand edit in `project.yml` | the hand edit survives |
| deploy | the install command itself | number BURNED — the phone may have it |
| deploy | a signal during the build | number restored |
| deploy | a signal after the install | number COMMITTED |
| deploy | a failing pre-commit hook | number still committed, via `--no-verify` |
| deploy | — (dirty worktree) | the uncommitted files are named *in* the commit |
| deploy `--no-bump` | — (staged `project.yml` edit) | not swept into a "Build X" commit |
| release | L1 | nothing moved (the bump hasn't happened yet) |
| release | the archive | number restored, tree clean |
| release | the upload | number BURNED — Apple may hold it |
| release | a signal after the upload | number COMMITTED |
| release happy path | — | uploaded and committed |
| release | the commit, after a successful upload | number KEPT, loud warning, recovery file |
| release `--dry-run` | — | archived, number restored, tree clean |

Run it after touching either script — the scripts commit to the repo, so a bug
in them is a bug in the repo's history.

**Why a failed upload burns its number rather than restoring it.** An exit code
cannot distinguish "never reached Apple" from "Apple took it and something
failed afterwards", and the two mistakes are not symmetric. A burned number
skips one in a counter that is only ever required to *increase* — harmless.
Reverting a number TestFlight already holds is permanent: it will not accept
that number again, so the uploaded build maps to no commit for good. Same
reasoning for a failed install. The commit message says which case it was.

**Four implementation bugs were caught by this suite, none of them visible to
reading:**

1. `set -e` is disabled inside a function invoked as `f || …`, so a failed
   commit fell through and reported success.
2. `git diff --quiet` compares the worktree to the *index*, so a retry after a
   partially-staged failure saw "nothing to commit" and returned success.
3. Bash does not run an `EXIT`-only trap when the script takes `SIGINT` — and
   Ctrl-C during a long `xcodebuild` is the interrupt #22 actually describes.
4. Bash defers a signal until the running child exits, so a trap fired between
   `xcodebuild -exportArchive` returning and the next line: the point-of-no-return
   flag was still unset and the trap reverted a number Apple already had.
   Deterministic, not a rare race — which is why the flags are now set *before*
   their commands rather than after.

## Target devices

| Phone | Screen | Notes |
|---|---|---|
| iPhone 14 Pro | 6.1", Dynamic Island, home indicator | dev/test device |
| **iPhone SE (2nd gen)** | **4.7", home button, NO bottom safe area** | the deployment target in the field; well past the iOS 17 floor |

Layout is driven by safe-area insets, never fixed margins, because these
two differ sharply: a bottom padding that rides the home indicator on the
14 Pro puts text against the glass on the SE. Check both simulators after
any layout change:

```
xcrun simctl create "Heiko SE" com.apple.CoreSimulator.SimDeviceType.iPhone-SE--2nd-generation- com.apple.CoreSimulator.SimRuntime.iOS-26-5
```

## L4 — Device tests (person + phone)

Only after L1–L3 pass. Do these in order and stop at the first failure.

| ID | Do this | Expect | Rule |
|---|---|---|---|
| D1 | Open app, wait for spinner to clear | Ready in a few seconds | R8 |
| D2b | Tap once, speak within half a second | Nothing lost — the mic watchdog rebuilds a dead audio path in ~0.5s | **R4** |
| D2 | Speak English **immediately** at launch | ⚠️ **Known broken** — speech at launch is lost. The app now opens muted with `Zum Sprechen antippen` as a workaround (SPEC §3.2); the underlying bug is still open. Retest by tapping once, then speaking. | **R4** |
| D3 | "Hello Heiko, how are you?" | ONE left black bubble, German audio | R1, R2 |
| D4 | Reply "Mir geht es gut, danke." | ONE right grey bubble, English audio | R1, R2 |
| D5 | The 60-word sentence | Full text, full translation, nothing cut | **R5** |
| D6 | Speak while it's speaking | Your speech is still captured | R6 |
| D15 | Speak a long German sentence with a breath in the middle | ONE bubble, complete; the app does not start talking until you stop | **R5**, §3.3 |
| D7 | 6 exchanges back to back | All work; no failure after round 3 | **R7** |
| D8 | Let it sit **10+ minutes**, then speak | Still works (reconnected silently) | R7 |
| D9 | Mute, speak, unmute, speak | Nothing while muted; works after | R8 |
| D10 | Spanish, then German | German comes back as Spanish | §3.1 |
| D11 | Spanish conversation, mute, unmute, speak German | Still comes back as Spanish (direction memory survives the cycle) | §3.1 |
| D12 | Receive a phone call mid-conversation, hang up | App resumes listening by itself | **R7/R8** |
| D13 | Background the app, reopen it | Resumes listening by itself; nothing streams (or bills) while backgrounded | R8 |
| D14 | Deny mic permission, then tap the button | The Settings instruction appears again on every tap — never a silent dead app | **R8** |

### On-device diagnostic log

The app records every launch to `Documents/heiko-diagnostics.log` in its own
container (previous run kept as `.log.1`, 4 MB cap). No tethering needed
while testing — use the app anywhere, plug in afterwards and run:

```
Tools/pull_logs.sh
```

It lands in `logs/<timestamp>/` (gitignored). Categories: `app` (launch,
foreground/background, interruptions, permission), `audio` (engine start,
input format, per-second mic heartbeat with peak level, converter rebuilds,
mic open/flush), `session` (connect, handshake, setupComplete, errors,
goAway, reconnects, unrecognized frames), `turn` (language codes, direction,
speaker-stopped,each commit accepted or rejected and why), `watchdog` (the 3s
startup health check), `ui` (button taps).

The mic heartbeat is the key line for the launch bug: it distinguishes "the
room was quiet" from "the microphone was dead", which no amount of staring
at the screen can.

### Reporting a failure
Give: which test ID, what appeared on screen (screenshot), what you heard,
and the last words shown before it stopped. That is enough to locate the bug
without guessing.

---

## Current status

| Level | State |
|---|---|
| L1 | ✅ Built and passing — 122 XCTest cases bound to the real `TurnLogic`, `SpeechEndPolicy` and `GeminiLiveTranslationService` (2026-08-10) |
| L2 | ✅ Fully verified, including L2.6 reconnect-after-expiry (2026-07-25) |
| L3 | ✅ Built and passing — 71 assertions across 10 replays (2026-08-10, on the merged #41+#44 result; 63 across 9 on #41 alone). Earlier: 56 across 8, twice in a row (2026-07-25). Found and fixed live: straggler-code carryover (wrong-side bubbles), garbage transcripts from the target==spoken session, unanimous-then-corrected opening misdetections |
| L4 | ⚠️ Needs a device re-run: fixes landed for the D2 root cause (mic now opens on setupComplete and flushes pre-connect audio), D3/D4 (settle-window + straggler grace + commit gates in `TurnLogic`), D5 (output-tail no longer finalizes while the speaker is still talking), D7/D8 (goAway closes are no longer treated as intentional, so sessions actually reconnect), and D10 (all three sessions now run, so German→Spanish is possible at all) — none re-verified on a phone yet |

## What I got wrong

Testing at L4 only. Every bug was found by a person talking to a phone,
which is slow, inconsistent, and gives ambiguous evidence. The duplicate
bubble bug is a **pure logic error** that a five-line L1 test would have
caught immediately.

**The fix:** build L1 and L3 first, then never ship to L4 without them
passing.
