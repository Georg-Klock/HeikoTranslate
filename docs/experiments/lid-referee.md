# Experiment — an independent language witness (#135)

Status (2026-09-16): **Phase 0 found a gap on the TestAudio corpus, on macOS.**
One score — the difference between the two transcribers' confidences —
separates German-spoken from partner-spoken readings with nothing in between.
The corpus is text-to-speech and the models are the Mac's, so this licenses
Phase 1 (observe-only on a phone), not any decision. The referee is wired into
the service as a log-only witness on `feat/language-referee-135` (see "Wired,
log only" below). The 2026-08-17 record below is kept as it was written.

## SpeechTranscriber, Phase 0 on the TestAudio corpus (2026-09-16)

### Does it cost a permission dialog? No — on the evidence available offline

#135 §5 assumed a second system dialog, because `SFSpeechRecognizer` needs
`NSSpeechRecognitionUsageDescription` and `requestAuthorization`. The iOS 26
transcriber does not appear to. What was checked, and how:

1. **The SDK.** In the iOS 26.5 SDK's `Speech.swiftinterface`,
   `SpeechAnalyzer`, `SpeechTranscriber` and `AssetInventory` declare no
   authorization API, and their documentation in the module's `.swiftdoc`
   mentions neither authorization nor a usage description. The
   `SFSpeechRecognizer.h` header, by contrast, states that the app crashes if
   the key is missing when authorization is requested. The transcriber also
   has no network mode to switch off: nothing like
   `requiresOnDeviceRecognition` exists on it. Its documentation says it uses
   the models system dictation uses on device.
2. **A run without the key.** `Tools/lidprobe` is a plain `swiftc` binary
   with no Info.plist and no usage description. On macOS 26.5.2 it installed
   the de-DE, es-MX and ko-KR models, reserved four locales, and transcribed
   the whole corpus through four transcribers. No prompt appeared, nothing
   was terminated, and `SFSpeechRecognizer.authorizationStatus()` read
   `notDetermined` before and after.
3. **The control, in the same binary on the same day.**
   `Tools/lidprobe.sh --request-sf-authorization` calls
   `SFSpeechRecognizer.requestAuthorization`. It was killed at once with
   SIGABRT, and the crash report's termination namespace is `TCC`, stating
   that the Info.plist must contain `NSSpeechRecognitionUsageDescription`. So
   TCC is enforcing speech authorization for this binary, and the transcriber
   run did not trigger it.

**What is not verified: iOS itself.** The iOS 26.5 simulator reports
`SpeechTranscriber.isAvailable == false` with zero supported locales, so it
cannot run the transcriber. The 2026-08-17 on-device install was made by a
build that already carried the usage description, so it cannot answer the
question either. Before anything ships, one device run of a build **without**
the key has to show the referee reaching `listening` with no dialog. Until
then, `project.yml` gains no usage description.

### Assets

The Mac had only the English models installed. Requested through
`AssetInventory` from the harness, with no interaction:

| Locale | Before | Install time |
|---|---|---|
| de-DE → de_DE | supported | 24.9 s |
| en-US → en_US | supported (model present, not reserved) | 0.2 s |
| es-MX → es_MX | supported | 9.3 s |
| ko-KR → ko_KR | supported | 8.9 s |

30 locales supported, `maximumReservedLocales` 5. Installing one locale
brought its regional siblings with it (es_CL, es_ES and es_US arrived with
es_MX). After that the whole corpus run takes about 23 seconds.

### The corpus and the method

`Tools/lidprobe.sh` feeds every `TestAudio/*.wav` to de-DE and to each partner
locale. The file name gives the spoken language. A German file is read under
all three pairs and a partner file only under its own. `silence.wav` and
`noise.wav` are the false-positive check. The corpus has no fr or zh files to
skip, and **no Korean file at all**, so de↔ko has no partner population.
`de_after_en` and `de_after_es` are composites: two utterances in two
languages, which the app would treat as two turns. That was declared before
the run, and they are reported both with and without the composites. Readings
came back byte-identical on a second run.

Readings carry the transcript, each transcriber's confidence (the
`transcriptionConfidence` attribute, weighted by character across the
transcript) and up to three alternatives. Scores are signed so that positive
favours home: `confΔ` is home minus partner confidence, the length balance is
(home − partner) ÷ (home + partner) letters and digits, and the weighted
balance weights each side's length by its confidence. #135 §3's fourth
candidate, agreement with Gemini's transcript, needs the live API and is not
measured here.

### Result

| Candidate | Single utterances, all pairs (27 German / 8 partner) | Composites included (33 / 8) |
|---|---|---|
| home confidence | German 0.841…0.977, partner 0.654…0.880: **no gap** (overlap 0.039) | no gap |
| −partner confidence | −0.734…−0.187 against −0.965…−0.773: gap 0.039 | no gap (touching at −0.773) |
| **confidence delta** | **+0.201…+0.764 against −0.177…+0.035: gap 0.166** | gap 0.052 |
| length balance | −0.259…+1.000 against −0.031…+0.015: **no gap** | no gap |
| weighted balance | −0.045…+1.000 against −0.092…+0.020: **no gap** | no gap |

Per pair, the confidence-delta gap is 0.303 on de↔en (9 German, 7 English)
and 0.316 on de↔es — but that pair has one Spanish file, so its number
describes a single file. Length alone does not separate anything: a German
transcriber reading English writes out roughly as many characters as an
English one does.

**Verdict: gap.** `confidenceDelta` separates the two populations with 0.166
of empty space over single utterances, and with 0.052 when the two
two-language composites are counted as German.

`RefereeEvidence` now decides on it, and on nothing else. It names a side
only when that side's transcriber was at least `confidenceMargin` (0.10) more
confident **and** heard letters or digits. It says `inconclusive` when either
side produced no transcript, because a silent transcriber is not a witness
for the other language (the 2026-08-17 device lesson). On this corpus:

| Spoken | Readings | Right | Wrong | Inconclusive |
|---|---|---|---|---|
| German | 27 | 26 | 0 | 1 (ko transcriber silent) |
| English | 7 | 4 | 0 | 3 (within margin) |
| Spanish | 1 | 1 | 0 | 0 |
| no speech | 6 | — | 0 named a language | 6 |

The old structural rule ("exactly one side heard words") would have named
German for `noise.wav` under all three pairs: the German transcriber heard
"you".

### Why this is weaker than it looks

- **The margin was chosen after reading the table.** 0.10 is a round number
  inside the gap and symmetric about zero, but this corpus cannot also
  validate it. The partner population's top value is **+0.035**
  (`en_entities.wav`, a list of brand names). That is on the home side of
  zero, so "whichever transcriber is more confident" is already wrong on one
  measured file.
- **The gap is asymmetric, and home was always German.** German speech drives
  the delta far positive (the English transcriber manages 0.19–0.61 on it).
  English speech only drives it slightly negative, because the German
  transcriber is comfortable with English names and loanwords (0.65–0.88).
  Two English readings, −0.108 and −0.119, clear the margin by less than 0.02.
  "German against not-German" and "home against partner" are the same thing
  here only because every pair has German at home. A pair without German, and
  Korean speech at all, are unmeasured.
- **Eight partner readings, seven of them one English voice.** Every fixture
  is `say` output from an Apple voice, read by an Apple recognizer, with no
  room, no microphone and no accent. That is the most favourable case the
  experiment can have. #32 already showed a TTS fixture failing to reproduce a
  human-voice failure.
- **Mac models, not the phone's.** The framework is the same, but the assets
  are per platform, and the field device (iPhone SE, 2nd generation) may
  report `SpeechTranscriber.isAvailable == false`. The simulator does. If it
  does, the referee is inert on the phone this app exists for.
- **The composites narrow the gap to 0.052.** A turn that is really two
  languages, which is #32's shape, dilutes the signal, as expected.

### What was built for Phase 1

| Piece | Where |
|---|---|
| The rule | `HeikoTranslate/Models/RefereeEvidence.swift`: readings, scores, verdict, `Thresholds.confidenceMargin` beside this measurement |
| The seam and the transcriber | `HeikoTranslate/Services/LanguageReferee.swift`: `LanguageRefereeing`, `TranscriberReferee` (iOS 26), `InertLanguageReferee` |
| L1 | `Tests/RefereeEvidenceTests.swift`: L1.116–L1.120b, including a source scan for server-capable recognition or networking APIs |
| The probe | `Tools/lidprobe.sh`, `Tools/lidprobe/main.swift`; `REFEREE_SOURCES` in `Tools/session_sources.sh`, checked by both harness gates |

### Wired, log only

`GeminiLiveTranslationService` holds one referee for its life and makes four
calls:

- `start(home:partner:)` in `start()`, once the audio path is up and the pair
  is known;
- `append(_:)` first thing in the tap block, with the raw buffer, before the
  Int16/16 kHz conversion. The reference is captured before `installTap`, so
  the render thread reads no service state, and a watchdog rebuild's new tap
  feeds the same referee;
- `turnEnded()` in `resetForNextUtterance()`. A turn with words in it, from
  either Gemini session or either transcriber, writes one
  `referee: <verdict> … | app: <outcome> | referee[home] … referee[partner] …`
  line, where the outcome is what `emitUtterance` last did for the turn
  (`RIGHT/home`, `LEFT/foreign` or `REJECTED: <reason>`);
- `stop()` in `stopSession()`, the run's teardown, and not in `stopAudioIO()`,
  which rebuilds also run.

Nothing else reads the evidence. L1.121g holds `TurnLogic.swift` and every
other file under `Models/` to never naming the referee, and L1.121c/d run the
same committed and rejected turns with the inert referee and compare what the
user sees.

A missing model is downloaded in the background only when the network is known
to be unmetered: online, not expensive and not constrained, read from the
service's `NWPathMonitor` at the moment of install. An unknown path counts as
metered. Otherwise the side stays `model-not-installed`, the log says the
download was deferred, and the next `start` asks again.

### Full table

Confidence `n/a` means the transcriber returned no transcript.

| Fixture | Spoken | Pair | de conf | partner conf | confΔ | length bal. | weighted bal. | Verdict |
|---|---|---|---|---|---|---|---|---|
| `de_after_en.wav` (composite) | de | de↔en | 0.818 | 0.552 | +0.266 | +0.000 | +0.194 | home, right |
| `de_after_en.wav` (composite) | de | de↔es | 0.818 | 0.732 | +0.086 | +0.043 | +0.099 | inconclusive (within margin) |
| `de_after_en.wav` (composite) | de | de↔ko | 0.818 | 0.727 | +0.092 | +0.108 | +0.166 | inconclusive (within margin) |
| `de_after_es.wav` (composite) | de | de↔en | 0.875 | 0.479 | +0.396 | +0.018 | +0.309 | home, right |
| `de_after_es.wav` (composite) | de | de↔es | 0.875 | 0.773 | +0.102 | +0.027 | +0.089 | home, right |
| `de_after_es.wav` (composite) | de | de↔ko | 0.875 | 0.488 | +0.387 | +0.198 | +0.456 | home, right |
| `de_loanwords.wav` | de | de↔en | 0.841 | 0.335 | +0.506 | -0.049 | +0.389 | home, right |
| `de_loanwords.wav` | de | de↔es | 0.841 | 0.640 | +0.201 | +0.054 | +0.188 | home, right |
| `de_loanwords.wav` | de | de↔ko | 0.841 | 0.488 | +0.353 | +1.000 | +1.000 | home, right |
| `de_pause.wav` | de | de↔en | 0.954 | 0.426 | +0.528 | -0.027 | +0.360 | home, right |
| `de_pause.wav` | de | de↔es | 0.954 | 0.648 | +0.307 | +0.021 | +0.212 | home, right |
| `de_pause.wav` | de | de↔ko | 0.954 | 0.419 | +0.535 | +0.327 | +0.636 | home, right |
| `de_pause_a.wav` | de | de↔en | 0.926 | 0.410 | +0.516 | -0.014 | +0.375 | home, right |
| `de_pause_a.wav` | de | de↔es | 0.926 | 0.549 | +0.377 | +0.091 | +0.339 | home, right |
| `de_pause_a.wav` | de | de↔ko | 0.926 | 0.467 | +0.459 | +0.895 | +0.946 | home, right |
| `de_pause_b.wav` | de | de↔en | 0.970 | 0.329 | +0.642 | -0.026 | +0.474 | home, right |
| `de_pause_b.wav` | de | de↔es | 0.970 | 0.734 | +0.236 | +0.028 | +0.166 | home, right |
| `de_pause_b.wav` | de | de↔ko | 0.970 | 0.340 | +0.630 | +0.233 | +0.642 | home, right |
| `de_price_short.wav` | de | de↔en | 0.951 | 0.187 | +0.764 | -0.211 | +0.536 | home, right |
| `de_price_short.wav` | de | de↔es | 0.951 | 0.529 | +0.422 | -0.062 | +0.227 | home, right |
| `de_price_short.wav` | de | de↔ko | 0.951 | 0.553 | +0.398 | +0.000 | +0.265 | home, right |
| `de_reply_long.wav` | de | de↔en | 0.977 | 0.421 | +0.555 | +0.037 | +0.428 | home, right |
| `de_reply_long.wav` | de | de↔es | 0.977 | 0.710 | +0.266 | +0.049 | +0.206 | home, right |
| `de_reply_long.wav` | de | de↔ko | 0.977 | 0.383 | +0.594 | +0.360 | +0.689 | home, right |
| `de_short.wav` | de | de↔en | 0.957 | 0.415 | +0.542 | +0.000 | +0.395 | home, right |
| `de_short.wav` | de | de↔es | 0.957 | 0.586 | +0.371 | +0.030 | +0.269 | home, right |
| `de_short.wav` | de | de↔ko | 0.957 | n/a | n/a | +1.000 | n/a | inconclusive (one side silent) |
| `de_song_lead.wav` | de | de↔en | 0.950 | 0.612 | +0.338 | -0.259 | -0.045 | home, right |
| `de_song_lead.wav` | de | de↔es | 0.950 | 0.682 | +0.267 | -0.184 | -0.021 | home, right |
| `de_song_lead.wav` | de | de↔ko | 0.950 | 0.616 | +0.333 | +0.026 | +0.237 | home, right |
| `de_song_lead_long.wav` | de | de↔en | 0.960 | 0.469 | +0.490 | -0.149 | +0.204 | home, right |
| `de_song_lead_long.wav` | de | de↔es | 0.960 | 0.722 | +0.238 | -0.119 | +0.023 | home, right |
| `de_song_lead_long.wav` | de | de↔ko | 0.960 | 0.481 | +0.479 | +0.682 | +0.827 | home, right |
| `en_apple_google.wav` | en | de↔en | 0.854 | 0.947 | -0.092 | -0.031 | -0.082 | inconclusive (within margin) |
| `en_band_queen.wav` | en | de↔en | 0.861 | 0.944 | -0.083 | +0.000 | -0.046 | inconclusive (within margin) |
| `en_entities.wav` | en | de↔en | 0.880 | 0.845 | +0.035 | +0.000 | +0.020 | inconclusive (within margin) |
| `en_long.wav` | en | de↔en | 0.857 | 0.965 | -0.108 | -0.015 | -0.074 | partner, right |
| `en_series_ny.wav` | en | de↔en | 0.801 | 0.946 | -0.145 | +0.013 | -0.070 | partner, right |
| `en_short.wav` | en | de↔en | 0.654 | 0.773 | -0.119 | +0.000 | -0.084 | partner, right |
| `en_song_cash.wav` | en | de↔en | 0.761 | 0.937 | -0.177 | +0.013 | -0.092 | partner, right |
| `es_short.wav` | es | de↔es | 0.734 | 0.849 | -0.115 | +0.015 | -0.058 | partner, right |
| `noise.wav` | none | de↔en | 0.744 | n/a | n/a | +1.000 | n/a | inconclusive (one side silent) |
| `noise.wav` | none | de↔es | 0.744 | n/a | n/a | +1.000 | n/a | inconclusive (one side silent) |
| `noise.wav` | none | de↔ko | 0.744 | n/a | n/a | +1.000 | n/a | inconclusive (one side silent) |
| `silence.wav` | none | de↔en | n/a | n/a | n/a | +0.000 | n/a | inconclusive (neither side heard words) |
| `silence.wav` | none | de↔es | n/a | n/a | n/a | +0.000 | n/a | inconclusive (neither side heard words) |
| `silence.wav` | none | de↔ko | n/a | n/a | n/a | +0.000 | n/a | inconclusive (neither side heard words) |

---

The record from 2026-08-17 follows, unchanged.

Branch: `experiment/lid-referee`. Status then: **the coverage blocker is GONE;
the accuracy question is open.** Measured on device 2026-08-17.

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
