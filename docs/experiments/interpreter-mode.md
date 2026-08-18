# One session that picks its own direction (#135)

**Status: abandoned on device, 2026-08-17. Nothing merged.** The two-session
design stays. Everything below is why, and what is worth keeping from it.

The experiment lives on `experiment/lid-referee` behind two gitignored flags
(`INTERPRETER_MODE`, `CAPTURE_TURN_AUDIO`), both off. A build from a clean
checkout is the shipping app.

## What was being tested

The app runs two sessions because of one sentence in `ARCHITECTURE.md`: the
translate model supports exactly one fixed target per session. The target is
pinned at setup, so the app opens one session per side and infers **which
language was spoken** from which session produced a real translation.

That inference is what `TurnLogic` is. The vote tallies, the codes-veto, the
straggler windows, the settle-overturn rule, the impossible-settle yield, and
the entire second-witness search in #135 — all of it reconstructs a decision
the translate model was never able to express.

A general Live model can express it: name both languages in a system
instruction and it chooses the target per utterance. If that worked, most of
that machinery would be unnecessary rather than merely better-refereed.

## What the model got right

Measured, not assumed.

- **Direction: 10 of 11** on the L3 corpus through `Tools/l3interpreter.sh`,
  including both `de_after_en` and `de_after_es`, where the direction changes
  *within* one session with nothing reconfigured.
- **#32**, the German sentence opening with an English song title that flips
  the shipping arbitration to the wrong side, came back correct in 0.23s.
- **Silence and noise produce nothing.** A model that fills a pause with
  conversation would have been disqualified here whatever its translations.
- **Latency at parity**, once the right model was found: 1.10–2.32s against
  the shipping 1.42–2.29s across five clips.

The intelligence was never the missing piece. That matters for anyone
revisiting this: do not re-run the direction experiment, it passed.

## Why it was abandoned

**Turn-taking, four builds in a row, always the same shape underneath: the
model and the app both believing they owned it.**

| Build | Symptom | Cause |
|---|---|---|
| 2.4.67 | 3 of 8 turns rejected | The arbitration still ran. `codes-veto: settled fr, home session never translated` is predicated on two sessions existing and one staying silent; with one session the question has no true answer, so it killed turns whose translation was already in hand. |
| 2.4.69 | Garbled audio | The app batched held audio and released it at commit. The model streamed two overlapping generations; a batch of two concurrent streams is a braid. |
| 2.4.70 | Translated itself | Playing live put our own voice in the room with the mic still streaming. A general model translates any speech it hears — German in, correct French out, then that French translated back to German. Cannot happen on the shipping path, where a pinned target makes it impossible. |
| 2.4.71 | Worse | A half-duplex gate meant to stop the loop cut the speaker off mid-utterance, and the model answered the fragments. |
| 2.4.73 | Unusable latency | Manual activity windows fixed the garbling — the app declares the turn, one window in, one response out. But then nothing generates until the app says the turn ended: 0.7s idle + 1.0s mic veto + 1.6–3.6s generation. |

The last row is the one that ends it, and it is structural rather than a
threshold to tune. **The shipping translate model begins emitting BEFORE the
utterance ends** — measured at `first=-0.46s` on `de_song_lead`. It interprets
simultaneously. A general model waits for a complete turn, and once the app
owns the turn boundary it waits for the app too. Every second of the app's
end-of-turn caution becomes dead air the listener sits through, and the
caution is not optional: shortening it re-opens the double-answer failure,
because a breath pause is a legitimate end of speech to anything listening
acoustically.

Simultaneous interpretation and app-owned segmentation are not compatible.
Pick one. The shipping design already picked, and picked correctly for a
one-button app used by someone who cannot tell when it is wrong.

## What is worth keeping

**Pair restriction is the single biggest free win in language identification**,
and it is unused on the shipping path. The app always knows both languages, so
any classifier should be scored over exactly two candidates rather than
ninety-nine. Measured on `TestAudio` with `Tools/lid-bench.py`: whisper-tiny
goes from 89.5% open-set to 100% pair-restricted at full clip length. Google's
tuplemax paper (ICASSP 2019) reports the same effect for the same reason.

**Speaker identity is not language identity.** Recorded separately in
TESTING.md and refuted before this experiment began; do not revisit.

**The accent artifact governs every device measurement.** Off-the-shelf LID
scores 93.4% on mainstream-accented German and 61.3% on L2-accented German
(arXiv:2506.00628). Every solo device recording this project has is one tester
speaking both languages, so a failure rate measured that way is an upper bound
on what a real pair of speakers will see, never an estimate of it.

**A general model will translate its own output.** Anyone wiring a
conversational model into a full-duplex audio path should assume this and gate
the microphone by construction, not hope the echo canceller wins.

## Tools that outlived the experiment

All committed, all independently useful, none requiring interpreter mode:

- `Tools/lid-bench.py` — scores language deciders (Silero, SpeechBrain ECAPA,
  Whisper) on labelled audio, open-set and pair-restricted, with `rescues` and
  `breaks` columns that say whether a candidate is an *independent* witness
  rather than merely an accurate one.
- `Tools/lid-label.py` — labels a captured corpus without showing the app's
  own verdict, which is how a corpus quietly acquires the app's bias.
- `Tools/l3interpreter.sh` — the L3 corpus through a single session.
- `Tools/interpreterprobe.sh` — latency and correctness for either session mode
  on the shipping client.
- `Tools/onesession-probe.py` — the same question against a standalone client.
- `TurnAudioCapture` — per-turn audio with the app's verdict beside it, off
  unless switched on, covered by L1.104–104r.

## Measurement mistakes, recorded because they cost the most time

Four times, a broken measurement looked like a finding. Every one would have
been believed if it had pointed the other way.

1. A text detector scored correct French output as unknown, reporting a WRONG
   target when the model had answered correctly.
2. Stopping at the first `turnComplete` reported a two-utterance fixture as a
   failure when the model had answered the first utterance and never been
   asked about the second.
3. A 3s stability window closed the socket inside the gap between two
   utterances, scoring both multi-turn cases as one-turn failures.
4. `speechBounds` returned sample indices while the caller sliced bytes,
   halving every clip and keeping the first half of the speech as though it
   were the whole utterance.

And twice a measurement flag reached the test suite through the gitignored
`Secrets.plist` the test host bundles, turning L1 red for reasons unrelated to
the code. `AppConfig.isRunningTests` now forces both flags off under XCTest.

## The device facts that came out of it

Measured on iPhone15,2 / iOS 26.5.2, and not answerable from public sources:

- `AssetInventory.maximumReservedLocales` is **5**.
- `SpeechTranscriber`: 30 locales supported, 16 installed.
- Spanish, Korean and Mandarin are supported but **not installed**; Tagalog and
  Vietnamese are unsupported outright.
- Installing a `SpeechTranscriber` asset does **not** make
  `SFSpeechRecognizer.supportsOnDeviceRecognition` true for that locale — the
  old API still had only `de` and `en`. That was the open question from the
  referee research, and the answer is no.
- **#76 is narrower than recorded.** The translate-preview model returns
  `setupComplete` and then nothing to a Python client while the same clip
  through `GeminiLiveSession` answers correctly — but that same Python client
  drives a general Live model without trouble. The fault is an interaction with
  the translate-preview model, not the Python twin being broken.
