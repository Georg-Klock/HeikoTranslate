# Experiment — an independent language witness (#135)

Branch: `experiment/lid-referee`. Status: **Phase 1 — observe-only, deployable
by cable.** The referee runs on the phone and writes one log line per turn.
**No app behaviour changes:** nothing it produces is read by `TurnLogic`, the
direction, the commit, or the audio gate.

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
