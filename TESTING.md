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

Session lifecycle (#1, 2026-08-10). The flags `close()` writes on the main
thread and the URLSession callbacks read on the delegate queue are one pure
value now (`SessionLifecycle`), guarded by a lock in the class; the
decisions that read them are mutating functions, so the interleavings run as
L1 cases. Verified fail-first: with the exactly-once latch neutered, L1.70b
fails in all six orderings.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.70 | An intentional close racing the task-completion callback | Quiet — our own close must never read as server-initiated and trigger a reconnect nobody asked for | **R7/R8** |
| L1.70b | One pre-handshake failure observed by the setup send, the receive loop AND the completion, in every order | Exactly ONE `.error` — three reports burned the whole 3-attempt retry budget on one transient refusal | **R7/R8** |
| L1.70c | goAway close / abrupt drop / noise after close or after open | Planned close, unplanned close, and quiet respectively — the pre-#1 classifications, preserved and now atomic | **R7** |
| L1.70d | A failure landing with intent recorded but the transport not yet marked closing | Expected-close noise — intent alone suffices, and the class records both under ONE lock acquisition | **R7/R8** |

Text size (#12, 2026-08-11). The untouched state is the SYSTEM size: the
old default forced `.large` at the app root, replacing the system Dynamic
Type environment — including the accessibility categories the slider cannot
express. `TextSize.override(for:)` is pure; the behavioural halves were
verified on the simulator per the #43 precedent (fresh install of this
build, `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL`
plus the demo transcript): the system size visibly reaches the transcript
with no override, and an explicit `-settings.textSizeStep 0` renders the
same transcript at xSmall despite the AX setting. The modifier is one
`transformEnvironment`, deliberately not an `if let` around the content: the
conditional's branch flip on the first slider touch would hand `ContentView`
a new structural identity and recreate its `@StateObject` — the live
conversation — mid-use (caught in review of the first draft). That
one-identity property is SwiftUI structure, not reachable by a unit test;
stated here rather than left implied, per the L1.43 precedent. Both
simulator checks were re-taken after the rewrite.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.72 | A fresh install (the sentinel default) | NO override — the system size, accessibility categories included, flows through | **§4.1/a11y** |
| L1.72b | Every explicit slider notch, and out-of-range persisted values | The chosen override, clamped — a stored integer outlives notch-count changes | **§4.4** |
| L1.72c | The thumb position while the system is in charge | The notch nearest the current system size; accessibility categories clamp to the last notch | **§4.4** |

Per-script floors (#29, measured 2026-08-11). The output-substance floors
are per home language now — `TurnLogic.floors(for:)` — calibrated by
`Tools/floor_measurement.py` on the Swift wire path (60 probes, the table
committed at `Tools/measurements/floors-2026-08-11.json`). Korean and
Chinese loosen (2/3 and ratio 0.34/0.23); the Latin homes measured safely
above the baseline and keep the German values, whose binding constraint is
the false-start corpus only German has. The loosen-only doctrine is itself
a test. One campaign exclusion, recorded in the table: a ~300ms utterance
("Ja.") never engages the model at all — a VAD floor, not a length fact.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.74 | Every language's floors vs the German baseline | Loosen-only, and the Latin homes keep the baseline exactly | **#29** |
| L1.74b | A 7-char zh translation against a 22-char echo (ratio 0.32), codes LYING home | Counts as a real translation and beats the codes (the L1.20 doctrine), where the baseline 0.4 handed the turn to the lying codes — wrong side | **R2** |
| L1.74c | The decisive path, densest script: 1 char alone vs a 3-char real answer | 1 stays a false start; 3 stands, which the baseline 8 swallowed | **R2/R4** |
| L1.74d | zh/ko short answers through commit under settled foreign codes | Shape coverage, labelled as such — the settled-codes route admits these regardless; the discrimination lives in the rows above | **R2** |

Partner-only languages (#30, 2026-08-12). Tagalog and Vietnamese are
selectable as the partner, never as home (`canBeHome`): the wheel filters,
the SPEC §4.4 collision swap falls back instead of seating them, and the
home binding refuses them outright. A stored value arrives through `init`,
where property observers do not fire, so init normalizes it itself (#90).
L1.44 encodes the amended rule: a partner-only language needs a NAME in
every set and falls back to German, not a set of its own. Verified live
before landing: `targetprobe.sh tl vi` translated both.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.75 | The collision swap with a partner-only old partner | Falls back (default home, or its counterpart on a second collision) — never seats tl/vi on home | **§4.4/#30** |
| L1.75b | Any write of a partner-only language to the home binding | Refused; previous home survives; the pair stays distinct | **R8/#30** |
| L1.75c | A persisted partner-only home (`settings.homeLang = "tl"`), fresh init | Repaired to the default home — observers do not fire during init, so the binding guard cannot cover this path. The distinct-pair fix re-runs after the repair, and the STORE is repaired too, or it lasts one launch | **R8/#30/#90** |
| L1.75d | A legitimate persisted pair (a partner-only PARTNER included) through the same init | Loads unchanged, in memory and in the store — the repair touches exactly one broken state | **§4.1/#30/#90** |

The wheels, for VoiceOver (#14, 2026-08-11). Each language column is ONE
adjustable element; a swipe steps through the same displayed order the
wheel scrolls, writing the same `selection` binding, so the distinct-pair
rules apply unchanged. The element's presence, label
and value are verified by the LOCAL accessibility UI target
(`Tools/uitest-accessibility.sh`, deliberately outside CI — the CI-spend
decision stands; the target exists so the claim is verified, not assumed) —
the adjustable ACTION itself has no XCUITest trigger for custom
elements, so its behaviour stays pinned by the pure lap tests plus the
same-binding argument.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.73 | The excluding column's options, for every other-side choice | The other side is never offered, and never produced by any adjustment step | **§4.4/a11y** |
| L1.73b | A full adjustable lap, both directions | Every option visited exactly once, wrapping — one notch of the endless wheel | **a11y** |
| L1.73c | An empty option list, or a stored selection outside it | Safe: current pick kept, or first option — a persisted value outlives invariants | **R8** |

The revoked key (#9, 2026-08-12). The piece that makes revoke-first rotation
safe: after the pre-handshake retries exhaust, ONE REST probe asks whether
the key itself is dead, and only a body naming `API_KEY_INVALID` upgrades
the message from "try again" to the update sentence. The German sentence is
a candidate awaiting Georg's on-device check; the tap opens `APP_UPDATE_URL`
from Secrets.plist (absent in dev builds by design — the unlisted link must
not be committed).

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.76 | A response body naming `API_KEY_INVALID` (or the standard human message) | Verdict: revoked | **#9** |
| L1.76b | Quota exhaustion, a healthy body, a captive portal, garbage | Inconclusive — never "update the app" on a network problem | **#9** |
| L1.76c | Exhausted sessions + a probe that confirms revocation | `keyRevoked`, the reader-language update sentence shown, listening refused until updated | **R8/#9** |
| L1.76d | Exhausted sessions + an inconclusive probe | Generic messaging stands; nothing terminal | **#9** |

Resumed speech un-stops the turn (#83, 2026-08-12). Device finding: once
"speaker stopped" was set, the mic was never consulted again until commit,
so speech resuming in that ~2s window was half-committed, half-dropped, and
talked over. A loud mic buffer in the window now returns the turn to normal
listening; the regular end-of-turn clock re-governs, so a cough merely
re-runs the stop 1.4s later. Loudspeaker playback is gated out — an
echo-driven un-stop would hold turns open forever. Needs the device
re-validation the next phone session: the case-1 long-breath run should now
show `speaker resumed during the commit window` instead of losing words.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.77 | A loud mic buffer while stopped, no playback | The turn un-stops — the person is still talking | **R1/#83** |
| L1.77b | A loud mic buffer while our own translation plays | No un-stop — echo proves nothing | **#35/#83** |
| L1.77c | A loud buffer on a live turn | Nothing changes | **#83** |

The privacy-policy row (#91, 2026-08-12). App Review 5.1.1(i) requires the
policy link inside the app; the answer is a `Datenschutz` row on the
language sheet, beside the log row, labelled from `UIStrings` under the
reader-language rule (so the label went through L1.43/L1.44 like every
string), opening the ONE canonical URL the policy is published under —
the `www.` form, same as App Store Connect carries. The German label and
the extended mic usage-description sentence (naming the Google Gemini API,
5.1.2(i)) were approved by Georg on 2026-08-13; the sentence names the API
exactly as docs/privacy-policy.md does, so the permission dialog and the
published policy cannot describe the same transfer in two ways. Whether a
consent gate goes on top is the decision #91 stays open for.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.79 | The language sheet's source | Offers the policy link, labels it from `UIStrings`, and the destination is exactly the published `www.` URL | **#91** |

The direction decision, and the song-title flip (#32, 2026-08-14). Eight
device turns on build 2.4.52 were captured with a new `why:` diagnostic
(`TurnLogic.decisionSummary` plus the output lengths and ratio). Three
flipped to the foreign side, showing German-into-German nonsense in the
bubble's large line.

The discriminator is neither the settle nor the size ratio: five of the
eight settled on `en` and only three flipped, and every turn cleared the
0.40 floor. It is **what the home session produced**. On a flip the `de`
session TRANSLATED the English title and echoed the German tail — a half
translation, which `isRoundTripEcho` does not catch because too much
changed — so `homeIsRealTranslation` reads it as a genuine translation of
foreign speech. On a hold the `de` session echoed the whole utterance and
the guard fired.

L1.86–90 drive `homeIsRealTranslation` directly (it is pure, and it is the
branch the evidence implicates). Every string is reconstructed from the log
and each one's length matches that turn's recorded `outLen[...]`, so these
are the real values rather than plausible ones.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.86 | Home output half-translates the title, echoes the German (`home=46 partner=20`) | NOT a real translation — the speaker was German throughout | **#32** |
| L1.87 | The same, with a COMPLETE partner output (`home=46 partner=37`) | The same — rules out #115's truncation as the cause | **#32** |
| L1.88 | Home output is a full echo of the input (`home=40 partner=37`) | Not a translation; the turn stays home. The control: same words, same settle, opposite home output | **#32** |
| L1.89 | The same shape, a different title (`home=38 partner=35`) | Still an echo — not specific to one song | **#32** |
| L1.90 | Genuinely foreign speech, home session produces real German | STILL a real translation | **#83/#75** |

**A fix was attempted and reverted the same hour, 2026-08-14.** Lowering
`echoShareThreshold` from 0.6 to 0.3 turned L1.86/87 green, passed L1
219/219 and L3 89/89, and both `de_song_lead` fixtures committed
RIGHT/home. It was deployed to the device and dropped a real turn within
minutes.

"A boy named Sue is my favorite song by Johnny Cash.", spoken in English.
The `de` session translated it correctly — "Ein Junge namens Sue ist mein
Lieblingslied von Johnny Cash.", 60 chars, matching the turn's logged
`outLen[home=60]` — and the proper nouns Sue, Johnny and Cash survived, as
proper nouns do. Echo share: **exactly 0.300**. At 0.3 that read as an
echo, the home session was judged never to have translated, direction
never resolved, and the codes-veto dropped the turn four times. **No
bubble at all** — worse than the wrong-side bubble the change was meant to
fix.

That is #83's failure with a different sentence, and this file had already
named the shape: "Apple Google Netflix and Amazon" → "… und Amazon" scores
0.80 and is a correct translation.

**The lesson is about the kind of number this is.** A single overlap
scalar cannot separate the populations, because they interleave: a
half-translation shares the home FUNCTION words it left alone (*ist*,
*mein*), while a genuine translation shares the NAMES that survive it
(*Sue*, *Johnny*, *Cash*). 0.429 against 0.300 is not a gap — it is two
points, and any threshold between them is fitted to those two points.
Fixing #32 needs a discriminator over WHICH tokens are shared, not a
better cut-off.

**Measured 2026-08-14, both populations, real `echoShare`.** Genuinely
foreign speech was generated with the ENGLISH voice, because a German
speaker cannot produce this side: on device, ten English utterances spoken
by a German speaker were transcribed AS GERMAN by the de session
(`said[de]` empty on every turn, both sessions voting `de`), so the
`homeIsRealTranslation` branch was never even reached.

| utterance | share | truth |
|---|---|---|
| "Where is the train station, please?" | 0.000 | foreign |
| "A boy named Sue …" (device, L1.91) | **0.300** | foreign |
| "My favorite band is Queen …" | 0.364 | foreign |
| "And Sue is my favorite song …" | 0.375 | foreign |
| **"Apple and Google are both in California."** | **0.429** | **foreign** |
| "I watched Breaking Bad in New York …" | 0.500 | foreign |
| "Google, Netflix and Amazon." | 0.750 | foreign |
| **"We will rock you. ist mein Lieblingslied."** | **0.429** | **home** |
| "Happy Birthday ist mein Lieblingslied." | 1.000 | home |
| "We will rock you ist mein Lieblingslied." | 1.000 | home |

**The two 0.429 rows are the result.** Identical scores, opposite correct
answers. This is not a narrow gap to be split more carefully — it is a
proof that **no cut-off on this metric can be right about both**, which is
why the 0.3 attempt broke L1.91 the instant it fixed L1.86. Pinned by
L1.92, which asserts the collision rather than a direction and should fail
the day a discriminator makes the two separable.

What distinguishes them is WHICH tokens overlap: the foreign rows share
proper nouns that survive translation (Apple, Google, Sue, Johnny, Queen),
the home rows share German function words the model left alone (*ist*,
*mein*). That is the signal a fix has to read.

**Fixed 2026-08-14 — by a different signal, not a better cut-off.**
`sharesHomeFunctionWords`: among the tokens the home output shares with the
input, how many are unambiguously function words of the HOME language. A
genuine translation of foreign speech cannot reuse them, because the input
had none; a partial translation reuses exactly those, because it left the
home-language part alone.

Measured over the ten labelled turns: **0 shared home function words for
every foreign turn, 2 for every home turn.** A gap with nothing in it,
which is what makes this a classification rather than a threshold — and
why it succeeds where every cut-off on `echoShare` provably fails.

The word list is admitted under `FillerWords`' rule: unambiguously a
function word of that language, not an English word, not a name. `in`,
`an`, `am`, `so`, `will`, `was`, `hat`, `die` are all excluded for being
English too — `in` in particular is shared by two of the FOREIGN turns.
German only; other home languages get an empty set and the rule is inert
for them rather than guessing.

L1.86/87 pass without their markers. L1.93 runs the whole corpus with each
turn's OWN `partnerHomeEvidence` (device turns logged it true; L3 foreign
turns do not produce it), and L1.94 states the rule directly. `echoShare`
and its 0.6 threshold are untouched, so the 0.80–1.00 echo population and
every #83/#75/#23 guard behave exactly as before.

One pre-existing acceptance recorded rather than papered over: `entities`
("Google, Netflix and Amazon.") scores 0.750 and would be misread as an
echo if partner-home evidence ever appeared on it. That is #83's known
0.80 case; verified identical with and without this fix.

L1.91 is the dropped turn, and it is the guard the next attempt has to
satisfy before anything else. L1.90 was meant to represent this case and
could not: its sentence shares no tokens at all, so it stayed green
throughout. L1.86/87 are back under `XCTExpectFailure`.

The `interrupted` signal (#112, 2026-08-14). The spoken translation stutters
— a false start, then the corrected sentence — while the written bubble is
always right. Cause, established by reading the code rather than by
instrumenting: every audio chunk of a turn is held in `pendingOutput` and
**all** of them are played at commit, filtered only by RMS, so a rendering
the model abandoned is replayed before its replacement. The server says
when it abandons one — `serverContent.interrupted` — and that key sat in
`knownServerContentKeys` as "known-benign", read by nothing. It has been
arriving silently all along.

These rows pin the parser end only. **No behaviour changed**: nothing is
discarded yet, because `turnComplete` and `generationComplete` are
documented as unreliable on this preview model and `interrupted` may be
too. The diagnostic exists to answer that from a device log, since a frame
that is silently swallowed looks identical to a model that never sends one.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.80 | A `serverContent.interrupted: true` frame | Surfaces as `.interrupted` — reaching the orchestrator at all | **#112** |
| L1.80b | `interrupted: false` | NOT an interruption — read as a boolean, not as key presence, or the fix on top of this would discard good audio | **#112** |
| L1.80c | `interrupted` sharing a frame with an `outputTranscription` | Both survive — this is the shape the real frame arrives in | **#112** |
| L1.80d | `turnComplete`, a plain transcript, `setupComplete` | No interruption signalled, so a line in a device log means something | **#112** |
| L1.80e | The same interrupted frame | Not ALSO surfaced as `.raw` — it stays a known key | **#112** |

Verified fail-first: with the parser regressed to main's behaviour, L1.80
and L1.80c fail. L1.80b/d/e pass both ways by design — they pin invariants
that were already true and must survive the fix that comes next.

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

Audio startup as a transaction (#16, 2026-08-10). The choreography runs
against the `AudioGraphControlling` seam (`AudioStartupTests`), so ordering,
the once-only player wiring and the rollback are pinned without an
AVAudioEngine. Verified by reintroducing the original behaviour (wire every
start, no rollback): four of the five cases fail; the AEC case passes both
ways because it pins behaviour that predates the fix.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.68 | start → stop → start | The player node is attached and connected exactly ONCE per engine lifetime; the tap cycles with every start | **R8** |
| L1.68b | The engine fails to start | Rollback through the shared teardown — no tap, no playback, no activated session left; the next start succeeds | **R8** |
| L1.68c | The 0 Hz placeholder format a cold launch can report | The converter guard's throw unwinds the same way | **R8** |
| L1.68d | AEC cannot be enabled | Logged, not fatal — full-duplex without cancellation beats not running (pre-existing decision, pinned) | **R6** |
| L1.68e | The 0.5s mic watchdog rebuild | Shared teardown first, then a restart that obeys the once-only wiring | **R8/R4** |

The watchdog's exhausted case (#87, 2026-08-12). Two rebuilds that both came
up dead used to end as a silent no-op — `isRunning` stayed true, the button
read as listening, and speaking did nothing. The third strike now gives up
loudly: the shared teardown, exactly once, and `onMicUnrecoverable` fired;
the view model stops the UI and shows the existing reviewed sentence
(`micResumeFailed` — no new copy, so L1.43/L1.44 are untouched). The first
two attempts and the 0.5s cadence are unchanged. Verified fail-first: with
the silent no-op back, L1.68f fails on every terminal assertion; L1.68g
passes both ways because it pins that the cap must not become a hair
trigger, which was never broken.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.68f | Zero mic buffers through both rebuilds and the next check | Give up LOUDLY: shared teardown exactly once, `onMicUnrecoverable` exactly once, `isRunning` false — no third rebuild, no silent no-op | **R8** |
| L1.68g | A buffer lands after the first rebuild | The later checks are no-ops: no give-up, no further rebuilds, the run stays up | **R8/R4** |
| L1.68h | The view model's give-up handler | The button returns to tap-to-start and the EXISTING reviewed sentence (`micResumeFailed`) shows — the same pairing the failed automatic resume uses | **R8/§4.3** |

Cost accounting (#4, 2026-08-10). Usage frames are recorded in the session
callback ahead of the registry token check — billing happened whether or not
the instance is still current — and nowhere else. Verified fail-first: with
the recording back in `handle()`, both late-frame cases fail.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.69 | A usage frame in flight when the run stops, or from a superseded instance | Counted — a mute or goAway renewal must not lose the frames it had in flight | **costs** |
| L1.69b | A current session's usage frame | Counted exactly ONCE — the recording moved, it did not gain a second site | **costs** |

Late fragments (#39, 2026-08-11). The straggler rule the codes gate has had
since 2026-07-29 now covers the transcripts too: a fragment arriving while
the mic has heard no speech this turn is the previous turn still echoing out
of the server, and it must not rebuild per-turn state. Driven through the
real service — event route, idle and finalize timers — with fake sockets;
~8s of wall clock per case, paid for the production path on purpose.
Verified fail-first: with the gates removed, the repro case commits a second
bubble whose lines are strict prefixes of the first, the filed shape
verbatim. Known residual, same as the codes gate: a room loud enough to
cross the speech floor continuously makes the gate transparent.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.71 | A committed turn, then transcript fragments (prefixes of both lines) with no mic speech since the reset | Exactly ONE bubble — the stragglers rebuild nothing | **R1/R3** |
| L1.71b | A genuine reply immediately after the commit, mic energy first | Commits normally — the gate is a straggler filter, NOT the cooldown the issue forbids | **R4/R6** |

Log backup exclusion (#92, 2026-08-12). The diagnostic log carries both
speakers' words, and `Documents/` rides iCloud and local backups by default —
the one automatic copy "logs never leave the phone by themselves" (#8) did
not cover. Every log file now carries `isExcludedFromBackup`: the primary
when its handle opens, every kept run after the rotation moves (a move can
shed the attribute), and the concatenated share file when it is produced.
The tests write through the real `DiagnosticLog` into an injected temporary
directory and read the resource value back off disk; the rotation case runs
the real launch-rotation path by opening a second instance over the same
directory. Verified fail-first: all three cases fail without the exclusion
calls.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.78 | A fresh log file, written through the real type | `isExcludedFromBackup` reads back true on the primary file | **privacy** |
| L1.78b | A second launch over an existing log (the real rotation, a move) | The rotated `.log.1` AND the fresh primary both read back excluded | **privacy** |
| L1.78c | The concatenated share file for the manual share row | Reads back excluded — tmp/ not being backed up is an OS default, not a promise | **privacy** |


Start serialization (#13, 2026-08-10). One pending start attempt at a time,
owned and generation-stamped; the permission prompt is replaced by a
continuation the test resolves by hand, so the interleavings run as
deterministic cases (`PendingStartTests`) through the real `toggleButton()` /
`beginListening()` / `handleScenePhase()` paths. Verified by reintroducing the
original wiring: all three guards removed fails the double-tap case with the
original symptom (two service starts), and each guard alone has a failing test
when removed — the double-tap case stays green with only the `toggleButton`
branch gone, because `beginListening`'s own gate also refuses it (defense in
depth, on purpose).

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.66 | Two taps during one delayed permission prompt | Exactly ONE service start, and the app still ends up LISTENING — an accidental double-tap must never leave it silently off | **R8** |
| L1.66b | A second `beginListening()` racing a pending one (resume vs. tap) | Refused at the gate — one start owns the session | **R8** |
| L1.66c | Backgrounding while the prompt is up, then the grant arrives | ZERO starts — audio and sockets must not open off screen; no auto-resume for a start that never happened; a fresh tap works | **R8** |
| L1.66d | A stale grant resolving after a NEWER start is already pending | Touches nothing — not the spinner, not the session; the newer start completes alone | **R8** |
| L1.66e | The prompt denied | Launch state cleared, Settings guidance raised — the gate must not change the denied path | **R8** |
| L1.66f | A stop while a start is pending, then the grant | Nothing restarts — a grant from before the stop is void | **R8** |
| L1.66g | An audio interruption begins while the prompt is up, then the grant | ZERO starts — the mic must not open while iOS owns the audio; no resume armed for a session that never ran; a fresh tap works | **R8** |
| L1.66h | Backgrounding lands before the tapped start's first actor turn | The superseded task does NOTHING — no launch state, no permission request, no start — and a fresh tap works (cancellation is cooperative; the scheduling stamp is what kills it) | **R8** |
| L1.66i | Background, or a new interruption, before a scheduled interruption-ended resume runs | The resume is voided through the owned path: no prompt, no start, no stale resume armed | **R8** |
| L1.66j | An undisturbed interruption-ended resume | Still starts, exactly once — the voiding cases cannot pass by the resume path having been dropped | **R8** |
| L1.66k | The interruption ends while the app is backgrounded (call taken, app left mid-call) | The resume is DEFERRED, still armed — zero starts and zero permission work off-screen; `.active` performs exactly the one owed resume | **R8** |
| L1.66l | The grant resolves while the scene is `.inactive` — where the permission alert itself puts the app | Zero audio work; the granted intent is carried to `.active`, which starts on the ordinary alert-dismissal reactivation | **R8** |
| L1.66m | A manual tap after an automatic resume is queued but not yet run | The tap owns the session — the queued task is superseded by the generation bump, and no automatic-resume banner appears | **R8** |

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
whether a problem is *ours* or *theirs*: `Tools/l2probe.sh` (one-shot
probe) and `Tools/l2expiry.sh` (session-lifetime probe, ~10–20 min), both
compiled against the app's real `GeminiLiveSession`. `Tools/livetest.py`
is the Python twin and is **not** a working probe — see below.

**`Tools/l2probe.sh <target> "<sentence>"` is the working one-shot probe**:
it rides the Swift `GeminiLiveSession` — the path the app ships. It exists
because `livetest.py` went silent server-side while the Swift path worked
(#76: setupComplete, then nothing; fixture audio, setup-wait, compression
and a websockets 12↔17 bisect all eliminated client-side). livetest.py
stays for protocol experiments, with the caveat that its results are
currently evidence about the Python client, not the API.

Re-measured 2026-08-13, and the picture is unchanged: `l2probe.sh` returned
`Wo ist der Bahnhof?` and `targetprobe.sh de` returned `✓ Hallo, Heiko.` in
the same minutes that nine `livetest.py` variants all returned
`messages: 1` — setupComplete and nothing else, with no error frame. Newly
eliminated that round: the **websockets version** (17.0 was installed
2026-07-30, eleven days before the probe last worked, so the upgrade cannot
be the cause) and **compression** (the server returns no
`sec-websocket-extensions` header at all, so permessage-deflate was never
negotiated and `compression=None` was always a no-op). Also eliminated:
`audioStreamEnd` present/absent, `mimeType` with and without `rate`, 20ms
and 64ms chunking, waiting for setupComplete before streaming, and a Darwin
user-agent. What remains untested is below the application layer — TLS or
HTTP client fingerprint — which is not reachable from this repo. The
practical conclusion stands: probe with `l2probe.sh`.

The one-shot probe **exits nonzero when the API misbehaved** — a server
error, a setup that was never acknowledged, an empty transcript, or no
translated output (#20; it used to print all of that and exit 0, so a
script checking `$?` saw green on a completely failed probe). The pass/fail
predicate is pure and pinned by `Tools/tests/livetest-validation.py`, which
needs no network and runs with the other L0 scripts.

`Tools/numberprobe.sh` measures whether spoken numbers survive translation
(#33), on the wire path the app ships: ten German sentences through `say`
and the real `GeminiLiveSession`, checked for the value coming back. It
accepts any faithful rendering — `185`, "one hundred eighty-five", and
`4:42 PM` for *sechzehn Uhr zweiundvierzig* all count, because the question
is whether the VALUE survived, not how it was spelled. The first version
checked digits only and scored 8/10 by calling a correct 12-hour conversion
and a correctly spelled "nine" failures; a harness that overstates the bug
it measures is worse than none.

**Measured 2026-08-14: 10/10, including `hundertfünfundachtzig` → 185** —
the exact compound that failed on device at build 2.3.46 (#33). So German
compound numerals are composed correctly through this path, and the device
failure is not a flat model inability. What this does **not** establish is
that #33 is gone: `say` output is far cleaner than a real voice through a
phone microphone in a room with other people in it. It bounds the problem
to acoustic conditions or the specific session and direction, rather than
to numeral composition as such — which is where device evidence should now
look.

The probe also **cannot outlive its session** (#65): one hard deadline
covers connect, send and tail (default 4× the audio length + tail + 30s,
floor 60s; `--deadline` overrides), because a runaway generation — 2355
messages and ~28 MB for a 7-word sentence, measured — never goes
message-quiet, so a quiet tail alone can never fire. A deadline-capped run
fails validation by name with the partial tallies as evidence. On `goAway`
the probe now closes on cue the way `GeminiLiveSession` does, instead of
lingering into the server's 1008.

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

**A TTS fixture cannot reproduce #32**, and the two `de_song_lead` files are
the record of establishing that. On device (2026-08-14) a short German
sentence opening with an English song title flipped to the foreign side
twice, committing a German-into-German "translation". Both replays land
home, from a cold turn and after a preceding German one, with a transcript
identical to the device turn — `"We will rock you ist mein Lieblingslied."`

Two things had to be got right before that negative meant anything. The
first version let `say -v Anna` read the English title, and German phonetics
turned it into `"Wie viel Rock you"` — German words, so the opening was
never English and the case passed for the wrong reason. The fixture now
splices the ENGLISH voice for the title onto the German voice for the
remainder, one utterance, no gap, and the transcript matches the device.

So the sentence is not what flips it, and neither is session warmth. The
remaining difference is a human voice. These cases stay as regression
guards — English-leading German must keep landing home, and a fix for #32
must not buy the short case by breaking them.

| File | Contains | Tests |
|---|---|---|
| `en_short.wav` | "Hello Heiko, how are you?" | Basic English→German |
| `de_short.wav` | "Mir geht es gut, danke." | Basic German→English |
| `de_song_lead.wav` | "We will rock you ist mein Lieblingslied." | English-leading German stays home (#32) |
| `de_song_lead_long.wav` | same, extended past the title | The same, when the German outweighs the title (#32) |
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
5. No session errors, and **no unrecognized server messages** — protocol
   drift FAILS the run with a bounded sample of the frame (#19; it used to
   print a warning and pass, which let the release gate stay green while
   the parser discarded a new server shape). `L3_ALLOW_RAW=1` downgrades it
   back to a warning for investigating a drift — never for a release run —
   and `L3_INJECT_RAW=1` seeds one synthetic frame so the gate's teeth can
   be demonstrated on demand. "Never for a release run" is enforced, not
   asked: `release.sh` refuses to run at all while either variable is set
   to anything, before it tests, bumps, or builds
   (`Tools/tests/release-rejects-l3-overrides.sh` pins the refusal).

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
Tools/tests/shell-syntax.sh
Tools/tests/l1-gate-regenerates.sh
Tools/tests/uitest-accessibility-gate.sh
Tools/tests/release-rejects-l3-overrides.sh
Tools/tests/release-key-preflight.sh
Tools/tests/harness-sources-shared.sh
```

Two L0 suites are **local only**, because they need `swiftc` and the ubuntu
runner has none: `targetprobe-smoke.sh` and `harness-compile.sh`. Putting
them on a macOS runner is the CI spend #14 and #88 both declined. Run them
before a PR that touches the session's dependency graph.

Runs in a couple of seconds and needs nothing installed — it stubs `xcrun`,
`xcodebuild` and `xcodegen`, so it is safe on any machine and in CI. **CI
runs it** (#18): the `l0` job in `.github/workflows/shell.yml`, on ubuntu at
the 1× multiplier, triggered whenever a shell script changes. That became
possible when the scripts' one BSD-ism went away: in-place `sed -i ''` is a
spelling GNU sed rejects, so the CFBundleVersion swap now goes through
`Tools/build_number.sh` — one shared, portable helper (temp file + `mv`,
which also can't leave a backup file where the dirty-tree gates would trip
on it). Verified both ways: the suite passes with GNU sed shadowing the
system sed, and the old spelling demonstrably fails under GNU sed.

`shell-syntax.sh` runs `bash -n` over every tracked `.sh` file (#3):
`deploy.sh` and `release.sh` commit to this repository, and nothing so much
as parsed them before running. It refuses to pass on an empty file list, the
same discipline `l1.sh` applies to its test count. `shellcheck` remains a
separate decision — it needs installing, and putting it in CI is a spend
question.

The build-number suite also pins the app-path resolution (#3): `deploy.sh`
resolves the built app from `xcodebuild -showBuildSettings`, never a glob
over DerivedData — the old `ls | head -1` picked alphabetically, so a stale
hash directory sorting first got *installed* while the fresh build number
was committed. A decoy-directory case fails against the old resolution with
exactly that symptom.

`l1-gate-regenerates.sh` pins the other tooling invariant (#17): **the L1
gate tests the project generated from this checkout.** `Tools/l1.sh` runs
`xcodegen generate` before `xcodebuild test` — the generated project is
gitignored and does not follow a branch switch, so a stale one can silently
omit newly added sources and tests — and a failed generation stops the gate
instead of testing whatever project was lying around. The cases run the
REAL `l1.sh` against logging stubs, so the ordering is asserted on the
script that ships, not a re-implementation. `release.sh` and `deploy.sh`
inherit the guarantee through `l1.sh`, which they both call.

A third case pins the gate's exit status itself: a stubbed `xcodebuild`
prints a passing-looking `Executed … with 0 failures` summary but exits
nonzero, and `l1.sh` must exit nonzero without printing "L1 passed". The
original construct appended `|| true` to the xcodebuild pipeline before
reading `PIPESTATUS[0]`, which zeroed it — a failed build whose output
still carried a passing summary line was reported as a pass.

`uitest-accessibility-gate.sh` pins the same discipline onto the
accessibility gate (#88): `Tools/uitest-accessibility.sh` ended its
xcodebuild pipeline in `|| true` — there so a display `grep` matching no
lines could not fail the run under `pipefail`, but it swallowed the real
status too, on the script whose whole purpose is that the wheels' VoiceOver
claims are verified, not assumed (#14 above). The script now tees the
output aside, reads xcodebuild's status out of `PIPESTATUS`, and asserts a
non-zero `Executed N tests, with 0 failures` count, exactly as `l1.sh`
does. Three cases against stubs, the failing two verified fail-first
against the old construct: a failing xcodebuild cannot pass on its summary
line, a run that executed zero tests is not a pass, and a passing non-zero
run still passes with its summary displayed. The UI-test target itself
stays out of CI — the #14 CI-spend decision stands; only the stubbed L0
cases run there.

`release-rejects-l3-overrides.sh` pins the release side of the L3 drift gate
(#19): a shell with `L3_ALLOW_RAW` or `L3_INJECT_RAW` exported — set to
anything, not just `1` — cannot cut a release. `release.sh` refuses outright
before testing, bumping, or building, and a clean environment sails past the
guard to the test gate. Same idiom as the build-number cases: the REAL
`release.sh` in a throwaway repo, no re-implementation.

`release-key-preflight.sh` pins the Secrets preflight (#89): the archive
ships whatever `HeikoTranslate/Resources/Secrets.plist` contains, and no
other gate can catch a missing file, a blank `GEMINI_API_KEY`, or the
template's `REPLACE-ME` — L1 never exercises the key, L3 takes its own from
`Tools/local.env`, and the build succeeds regardless because the plist is a
bundled resource, not compiled. `Tools/secrets_preflight.sh` (shared, sourced
by both scripts the way `build_number.sh` is) makes `release.sh` and
`deploy.sh` refuse those three states before the test gate and before the
bump, so a refusal moves nothing and there is nothing to restore; a valid key
sails through to the test gate. Structural on purpose — whether the key is
*live* stays L3's and `l2probe.sh`'s job. The suite also asserts what the
preflight must never do: **print the key's value.** Every case's captured
output, refusal and pass alike, is swept for the invented fixture key.
`APP_UPDATE_URL` is pinned as a warning, never a refusal (#9): a release
without it still reaches the test gate, but is told the revoked-key sentence
would tap to nowhere. The extraction goes through `plutil -extract … raw`; on
a machine without a `plutil` (Linux CI) the suite substitutes a stub that
honours the contract the real tool was verified to have — the same contract
`build-number-windows.sh`'s plutil stub answers, since that stub shadows the
host tool for its whole harness.

`harness-sources-shared.sh` and `harness-compile.sh` pin the shared harness
source list (#103). Four scripts compile a `swiftc` binary out of the app's
own files — `l3replay.sh`, `floorprobe.sh`, `l2expiry.sh`, `targetprobe.sh`
— and each used to carry a private copy of that list, so a new file in the
session's graph broke all four and stayed broken in whichever ones nobody
ran. `KeyCheck.swift` (#82) did exactly that: #86 fixed the two being run,
and the other two were found by reading, not by failing (#102). The list now
lives once, in `Tools/session_sources.sh`.

`harness-sources-shared.sh` is the structural half and runs in CI: it
discovers harnesses by what they do (a real `swiftc` command line, not a
mention of one), then asserts each sources the shared list and names no
`HeikoTranslate/` source inline — plus that every file the list names
exists. Verified fail-first: regressed to main's inline shape, both
assertions fire. `harness-compile.sh` is the sufficiency half — it
type-checks all four — and is local only, since `swiftc` is not on the
ubuntu runner. Verified fail-first by deleting `KeyCheck.swift` from the
shared list: all four fail with the original `cannot find 'KeyCheck' in
scope`, which is the signal that was missing in #82.

### The language-referee experiment (#135, branch `experiment/lid-referee`)

The experiment carries a fifth harness, `Tools/lidprobe.sh`, and it is wired
into the two gates above on purpose. An experiment branch that only compiles
on the day it was written is not evidence of anything later, and this repo has
the receipts: #103's four harnesses drifted apart exactly that way. So
`RefereeEvidence` lives in the app target (compiled by every build, covered by
`Tools/l1.sh`, L1.95–L1.97b), and `lidprobe.sh` takes its sources from
`Tools/session_sources.sh` — which `harness-sources-shared.sh` now discovers
and checks like the other four, `REFEREE_SOURCES` included. Rebasing onto a
moved `main` therefore breaks loudly rather than silently.

**Phase 0's corpus measurement does not run on macOS, and that is a finding
rather than a setback.** `SFSpeechRecognizer.requestAuthorization` from a
`swiftc`-built tool is terminated by TCC before any of our code runs:

```
namespace TCC — "This app has crashed because it attempted to access
privacy-sensitive data without a usage description. The app's Info.plist
must contain an NSSpeechRecognitionUsageDescription key…"
```

Measured 2026-08-17 in four configurations, sandboxed and not: plain CLI;
CLI with the description linked into `__TEXT,__info_plist` (present, verified
with `otool -s __TEXT __info_plist`); the same ad-hoc code-signed; and a real
`.app` bundle with `CFBundleExecutable`/`CFBundlePackageType` set and signed.
SIGABRT every time. TCC wants a LaunchServices launch and a human at the
prompt, which a measurement harness has neither of.

So `lidprobe` reads the authorization status and refuses rather than asking —
a sentence instead of an unexplained abort — and the corpus measurement moves
to iOS, where the app bundle carries the usage description and the grant is a
real dialog. That is where the referee has to work anyway, so the constraint
costs the experiment nothing except the illusion that it could be measured
offline. The compile still earns its keep every run: it type-checks
`RefereeEvidence` against the app's real sources.

| ID | Given | Expect | Rule |
|---|---|---|---|
| L1.95 | Exactly one recognizer produced words | That language — the one categorical case, and #125's shape | **#135** |
| L1.95b | Neither produced words | Inconclusive — silence is not evidence for either side | **#135** |
| L1.95c | Both produced words | Inconclusive. A discriminator here is Phase 0's *deliverable*, not an assumption — the #32 revert one phase earlier | **#135/#32** |
| L1.95d | A recognizer that could not run, with stale text attached | Inert, never decisive — no on-device model, unauthorized, or failed | **R8/#135** |
| L1.95e | Whitespace-only output | Not testimony; must not win by default against a silent partner | **#135** |
| L1.95f | Every combination | The verdict names only a language in the pair — a third would be #125 again | **#135** |
| L1.96 | The reported scores | Computed and printed, never thresholded, so the lidprobe table means one thing run to run | **#135** |
| L1.96b | An empty side | Ratio collapses to 0 rather than dividing by zero; flagged categorical | **#135** |
| L1.96c | The sides swapped | Delta negates, ratio holds — home is a product decision, not an acoustic one | **#135** |
| L1.97 | Every app language | A distinct, non-empty recognition locale; the switch is exhaustive so a new `Lang` breaks the build | **#135/#30** |
| L1.97b | en and es | `en-US` and `es-MX` — the regions the flags already encode | **#135** |

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
container (previous run kept as `.log.1`, 4 MB cap). The log files are
excluded from iCloud and local device backups (#92) — they move off the
phone only by the owner's hand. No tethering needed
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

### Who is speaking, and why it changes what the evidence means

**Speaker identity is not language identity, in either direction.** Recorded
because a routing idea was built on the opposite assumption and reverted the
same hour (2026-08-17, #135 side quest: cluster turns by voice pitch, since
"who spoke" looked better-posed than "which language").

Two real cases break it:

- **Two people, one language.** Heiko and his wife both speak German, to one
  foreign-language speaker. Two voices, one home language — a speaker-based
  router flips sides between two people who belong on the same side.
- **One person, two languages.** Which is how this app is *tested*. One voice,
  both languages — a speaker-based router cannot see the switch at all.

The second case is the one with teeth beyond that experiment, because **every
device measurement this project has is single-tester bilingual audio**, and
that is systematically harder than the real thing:

- The second language carries the tester's accent. TESTING.md already records
  the consequence — ten English utterances spoken by a German speaker were
  transcribed **as German** by the `de` session, `said[de]` empty on every
  turn, so `homeIsRealTranslation` was never reached. A native English speaker
  would not produce that audio.
- The de↔es and de↔fr collapses (#125) were measured the same way. Some part
  of that failure rate may be accent rather than arbitration, and nothing
  currently separates the two.

Two consequences for how evidence is read:

1. A measured failure rate from single-tester audio is an **upper bound** on
   the failure rate Heiko will see, not an estimate of it. Do not quote it as
   the latter.
2. Before a fix is judged, ask whether its evidence needs a second speaker. A
   fix aimed at the accent artifact and a fix aimed at the arbitration look
   identical in single-tester logs.

Getting a native speaker of the partner language in front of the phone for one
session would be worth more than several more solo runs. The `de_song_lead`
fixtures already carry this lesson in miniature: the first version let the
German voice read the English title, German phonetics turned it into German
words, and the case passed for the wrong reason until the fixture spliced in an
actual English voice.

### Reporting a failure
Give: which test ID, what appeared on screen (screenshot), what you heard,
and the last words shown before it stopped. That is enough to locate the bug
without guessing.

---

## Current status

| Level | State |
|---|---|
| L1 | ✅ Built and passing — 203 XCTest cases bound to the real `TurnLogic`, `SpeechEndPolicy`, `GeminiLiveTranslationService` and `ConversationViewModel` (2026-08-13, on the #91 branch) |
| L2 | ✅ Fully verified, including L2.6 reconnect-after-expiry (2026-07-25) |
| L3 | ✅ Built and passing — 71 assertions across 10 replays (2026-08-10, on the merged #41+#44 result; 63 across 9 on #41 alone). Earlier: 56 across 8, twice in a row (2026-07-25). Found and fixed live: straggler-code carryover (wrong-side bubbles), garbage transcripts from the target==spoken session, unanimous-then-corrected opening misdetections |
| L4 | ⚠️ Partially re-verified on device (2026-08-12): revoked-key recovery passed after four on-device iterations (#9, PR #82); late-fragment filtering (#39), loanword direction (#40) and mic-aware speech end (#36) passed and closed; number transcription measured — shared model-level mis-hearing of German compound numerals, now a decision (#33); code-switching evidence refreshed (#32). Found live: #83, speech resuming in the stopped→commit window is dropped and talked over — the open half of #31. Still owed: the deliberate self-hearing geometry run (#35, case 7), which has fresh incidental evidence (a post-playback fragment recommitted as a small bubble). The ordered plan with per-case log criteria stays on GitHub #71. |

## What I got wrong

Testing at L4 only. Every bug was found by a person talking to a phone,
which is slow, inconsistent, and gives ambiguous evidence. The duplicate
bubble bug is a **pure logic error** that a five-line L1 test would have
caught immediately.

**The fix:** build L1 and L3 first, then never ship to L4 without them
passing.
