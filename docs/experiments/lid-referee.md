# Experiment — an independent language witness (#135)

Branch: `experiment/lid-referee`. Status: **the coverage blocker is GONE; the
accuracy question is open.** Measured on device 2026-08-17. Nothing ships yet.

## The refutation was wrong, and this is what replaced it

This document previously said the experiment was refuted because no API lets an
app install a speech model, so coverage was a property of how the owner had
configured their phone — and a setup step on the owner's phone is refused.

**That is false on iOS 26.** Measured on device (build 2.4.60, iPhone15,2,
iOS 26.5.2):

```
SpeechTranscriber supported=30 installed=12 maxReserved=5
assets  es[new:sup/notinst]  fr[new:sup/notinst]  ko[new:sup/notinst]  zh[new:sup/notinst]
install: requesting fr_FR …
install: DONE — installedLocales now …,fr_BE,fr_CA,fr_CH,fr_FR      ← 29 seconds
install: old API after install — de=on-device fr=STILL-NO
```

Three facts, all decisive:

1. **Spanish, French, Korean and Chinese are all supported** by
   `SpeechTranscriber` — 30 locales including `es_MX`, the app's actual
   Spanish target. Only Tagalog and Vietnamese are genuinely absent, which
   matches their partner-only status.
2. **The app installed French itself, in 29 seconds, with no user interaction
   at all** — no Settings, no keyboard, no dialog, nothing visible on the
   phone. `maxReserved=5` against a pair's 2, so the reservation cap is not a
   constraint either.
3. **The old `SFSpeechRecognizer` API is unaffected** (`fr=STILL-NO`). The two
   frameworks keep separate assets.

So the coverage problem — the thing that made this experiment useless for
exactly the pairs that carry the bugs — is solved, and solved without asking
Heiko for anything. What it costs is a **port**: `LanguageReferee` is written
against `SFSpeechRecognizer` and would have to move to
`SpeechAnalyzer`/`SpeechTranscriber`, which is iOS 26+ only and a different
shape (an actor with an async input stream rather than a callback task).

The product decision that produced the refutation still stands and is worth
keeping: **a setup step on the owner's phone is refused.** He never opens settings,
and the one action he may ever be asked to perform is a single German-labelled
row that shares a log. What changed is that iOS 26 does not require one.

## The open question is now accuracy, not coverage

Porting buys coverage. It does **not** buy a working discriminator, and the
device evidence on that is not encouraging. On de↔en — the one pair where the
referee could testify — it agreed with the app on 2 turns of 6:

| # | referee | app | evidence |
|---|---|---|---|
| 3 | en | RIGHT/home | `heard[en] "Hamburger new coffin it has a extra bacon and a McFlurry" conf=0.24`, de empty |
| 5 | en | LEFT/foreign | `heard[en] "OK that's going to be 1740 do you wanna pay by card" conf=0.83` ✓ |
| 6 | de | RIGHT/home | `heard[de] "Kein Problem wo muss ich das dran halten" conf=0.62` ✓ |

`onlyOne=true` on 18 of 18 turns — the two recognisers never both produced
text, so the categorical rule decided everything, and it decided by which
recogniser stayed silent. A silent recogniser is usually one that gave up, not
evidence the language was absent. Confidence does not rescue it either:
`"Bonjour"` scored **0.94** on a French turn against **0.62** for a full
correct German sentence, which is the #32 collision in a third metric.

So the case for porting rests on a bet: that `SpeechTranscriber`, a
substantially newer and better model than `SFSpeechRecognizer`, produces
readings clean enough that the discriminator problem shrinks. That is plausible
and unmeasured. **It should be measured on one language pair before the whole
referee is rewritten.**

Also unresolved: iOS 26 is a hard floor for this path, and whether the field
device (an iPhone SE 2nd generation) runs iOS 26 has not been checked.

## What the experiment has produced regardless

- The measurement discipline in TESTING.md on single-tester bilingual audio,
  which changes how every existing failure rate in this project should be read.
- A correction to #125's rate: `commit REJECTED` lines are deferral retries,
  not turns, and counting them overstated the de↔fr failure rate by 2–3×. The
  real figure is roughly 3 dropped utterances against 8–10 committed.
- A second, distinct de↔fr mechanism, recorded on #125: both sessions
  transcribe the French correctly and agree on it, and neither produces any
  translation at all (`outLen[home=0 partner=0]`). The arbitration is correct
  to refuse that turn; the model simply returned nothing.

---

Everything below is the record of how it got here.

## The first device result (build 2.4.58, iPhone 14 Pro, iOS 26.5.2)

18 turns: 10 committed, 8 rejected. Three findings, in order of how much they
matter.

**1. On-device model coverage is the binding constraint.** Only German and
English came up `ready`; `es`, `fr`, `zh` and `vi` all reported
`NO-ON-DEVICE-MODEL`. The referee is therefore inert for exactly the pairs
that have the bugs — #125's de↔es and de↔fr — and active only for de↔en, which
already works. **All 8 rejected turns were de↔fr**, so every turn the app
dropped was a turn the referee could not testify on.

The sharpest case: a turn the app dropped outright, where Gemini's `de` session
read the German as French garbage and its `fr` session read it correctly. The
referee's German recognizer had it verbatim at **0.98 confidence** — and had to
report inconclusive, because a verdict needs both sides.

Not yet a refutation: `supportsOnDeviceRecognition` reflects which dictation
models the device has *downloaded*, not what the hardware can do. Enabling those
languages under Settings → General → Keyboard → Dictation Languages may flip
them. Untested, nearly free, and the next thing to do. If it works it becomes a
setup step — fine on a measurement phone, a real burden on Heiko's.

**2. The structural rule is unreliable, measured.** `onlyOne=true` on 18 of 18
turns: the two recognizers never both produced text, so L1.95c's "both produced
words" case does not arise in practice and the categorical rule decides
everything. It decided wrongly on 4 of 6 de↔en turns, because *empty does not
mean "not this language"* — on one turn German was spoken, the German
recognizer produced nothing, and the English one produced phonetic garbage
("Hamburger new coffin it has a extra bacon and a McFlurry"). A silent
recognizer is usually one that gave up, not a witness for the other side.

**3. Confidence is not the fix — the same collision as `echoShare`.** "Bonjour"
heard by the German recognizer scored **0.94** on a French turn; a full correct
German sentence scored **0.62**. Any cut-off between them is wrong about one.
That is the #32 result in a new metric, and the third time a single scalar has
failed to separate these populations. Confidence *and* length may separate them
(one token vs eight), but that is a hypothesis at n=2 and fitting it now would
repeat the mistake this project already documented twice.

Full tables in #135's Phase 1 comment; raw evidence in the pulled device log
for that build.

## Deploying it

```
Tools/deploy.sh
```

The phone must be **unlocked** — a locked iPhone reports as `unavailable`,
which looks identical to not being plugged in. Then talk to it, and:

```
Tools/pull_logs.sh
grep "referee:" logs/<timestamp>/*.log
```

Each turn produces one line beside the existing `why:` line:

```
referee: de | app: LEFT/foreign | heard[de] "…" conf=0.82  heard[en] "…" conf=0.44 | confΔ=+0.38 ratio=0.412 onlyOne=false
```

`referee:` is what the independent witness would have said, `app:` is what
shipped. The turns where those two disagree are the whole point — especially
the `app: REJECTED …` ones, which are the turns the referee exists to rescue.

**On the first launch after installing, expect the referee to be inert for one
session.** Authorization is requested when audio starts, and the answer
arrives asynchronously, so that first run sees `notDetermined` and both sides
record `unauthorized`. Grant the dialog, then tap the button again (or relaunch)
and the `referee: start pair …` line should read `de=ready en=ready`. That line
is also the first result worth reading: if it says `NO-ON-DEVICE-MODEL`, this
phone has no on-device model for that language and the experiment stops there
for that pair.

The other thing to watch on an **iPhone SE (2nd gen)** — the field device — is
cost: two recognizers now run alongside two WebSockets and the audio engine.
Heat, battery, and whether the mic heartbeat stays regular are all real
signals; the `audio` category's per-second heartbeat is where a struggling
device would show up first.

## Why this branch exists

Every open turn-routing bug has one root: the app's only witness to "which
language was just spoken" is Gemini, and all Gemini sessions run one model, so
they mis-hear *together*. #125 has both sessions of a de↔es pair settling on
English — a language in neither side of the pair. The ten labelled turns in
TESTING.md have ten English utterances read as German by the `de` session,
both sessions voting `de`.

That is why the 2026-08-05 referee experiment failed (6/10 against a 5/10
baseline, branch `feat/de-es-referee-session`): a third Gemini session is a
correlated voter, and correlated errors cannot be outvoted by more of the
same. The proposal in #135 is a witness whose errors are independent — two
on-device speech recognizers, one per side of the pair.

## What is on the branch

| Piece | Where | Covered by |
|---|---|---|
| The pure decision type | `HeikoTranslate/Models/RefereeEvidence.swift` | `Tools/l1.sh` — L1.95–L1.97b |
| The on-device witness | `HeikoTranslate/Services/LanguageReferee.swift` | device evidence — Phase 1's deliverable |
| The offline probe | `Tools/lidprobe.sh`, `Tools/lidprobe/` | `harness-sources-shared.sh` (structural, in CI) + the compile itself |
| The shared source entry | `REFEREE_SOURCES` in `Tools/session_sources.sh` | existence-checked by the same gate |

### How the witness is kept from mattering

Observe-only has to be structural rather than a promise in a comment, because
this build goes on a phone a real person uses:

- `LanguageReferee` is read by **exactly one** call site — the `referee:` line
  in `emitUtterance`. `grep -n referee` over the service is the whole audit.
- Every failure is inert: no on-device model, no authorization, or a recognizer
  that dies mid-turn are each recorded as an `Availability` and stood down.
  `RefereeEvidence.verdict` returns `.inconclusive` whenever either side is not
  `.ready` (L1.95d).
- It joins the **one shared teardown** (`stopAudioIO`), so a mute cannot leave
  two recognizers listening — the shape of #15 and #127.
- It starts inside `startAudioIO`, which the L1 audio seam already skips, so no
  logic test loads the Speech framework and the 237-case suite is unchanged by
  its presence.
- It never touches the start path: authorization is requested off to the side
  rather than woven into `beginListening()`, whose interleavings are pinned by
  L1.66a–m and must not gain a new `await`.

`RefereeEvidence` deliberately reaches **no** calibrated verdict. It decides
the one categorical case — one recognizer produced words and the other
produced none — and reports everything else inconclusive, with the candidate
scores computed and printed rather than thresholded. That is the #32 lesson
applied before the fact: `echoShare` failed because two turns scored 0.429
with opposite correct answers, and the rule that worked measured 0 against 2.
Picking a cut-off before the corpus table exists is how this experiment would
repeat that.

## How the branch is kept honest as `main` moves

An experiment branch that only compiled on the day it was written is not
evidence of anything later. Two mechanisms, both borrowed from the repo's own
history rather than invented here:

1. **The pure type lives in the app target**, so every build compiles it and
   `Tools/l1.sh` — which CI runs on pull requests — covers its rules. A change
   to `TurnLogic.Lang` breaks L1.97 rather than rotting quietly.
2. **The probe takes its sources from `Tools/session_sources.sh`**, and
   `Tools/tests/harness-sources-shared.sh` discovers it automatically (it
   finds harnesses by looking for a real `swiftc` command line). #103 is the
   precedent: four harnesses each carried a private copy of that list, a new
   file broke all four at once, and two of them stayed broken until somebody
   read them. `REFEREE_SOURCES` is existence-checked by the same gate.

To revalidate after a rebase: `Tools/l1.sh` and `Tools/lidprobe.sh` (the
latter for the compile — see the blocker below) and
`Tools/tests/harness-sources-shared.sh`.

## The Phase 0 blocker, measured 2026-08-17

**The corpus measurement does not run on macOS.**
`SFSpeechRecognizer.requestAuthorization` from a `swiftc`-built tool is
terminated by TCC before any of our code runs:

```
namespace TCC — "This app has crashed because it attempted to access
privacy-sensitive data without a usage description. The app's Info.plist
must contain an NSSpeechRecognitionUsageDescription key…"
```

Verified in four configurations, sandboxed and unsandboxed, all SIGABRT:

1. plain CLI;
2. CLI with the description linked into `__TEXT,__info_plist` — present, and
   confirmed with `otool -s __TEXT __info_plist`;
3. the same, ad-hoc code-signed;
4. a real `.app` bundle with `CFBundleExecutable` and `CFBundlePackageType`
   set, signed.

TCC appears to want a LaunchServices launch and a human at the prompt. A
measurement harness has neither.

`lidprobe` therefore **reads** the authorization status and refuses rather
than asking, so the failure is a sentence instead of an unexplained abort.
The compile still runs on every invocation and still type-checks
`RefereeEvidence` against the app's real sources, which is the part that keeps
the branch from rotting.

## Next step

Move Phase 0's corpus measurement to iOS, where the app bundle carries the
usage description and the grant is a real dialog — which is where the referee
has to work anyway, so the constraint costs the experiment nothing except the
idea that it could be measured offline. Two candidate homes, in preference
order:

1. **A test target case on a real device**, driving the same
   `RefereeEvidence` over the same `TestAudio/` fixtures. Real on-device
   models, real grant. Local-only, like the accessibility UI target — the
   #14/#88 CI-spend decision stands.
2. **The simulator**, if `supportsOnDeviceRecognition` is true there. Cheaper
   and scriptable, but it is evidence about the simulator's models, not the
   phone's, and must be labelled that way.

Whichever runs, the deliverable is unchanged and is stated in #135: a
per-utterance table over both populations, and a gap with nothing in it —
not a narrow one. If there is no gap, this experiment stops and the negative
result gets written up beside the referee-session one.
