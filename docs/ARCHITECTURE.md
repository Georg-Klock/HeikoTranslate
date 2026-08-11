# Heiko Translate — Architecture (current)

Technical truth as of 2026-07-25. The product behavior this implements is
`SPEC.md`; how it's tested is `TESTING.md`. The original design writeup with
the full decision history is `docs/history.md` (historical — this file wins
where they disagree).

## The shape of the app

```
 mic audio (16-bit PCM, 16kHz, mono) — full-duplex, AEC keeps our own
    │                                  speaker output out of the mic
    ├──────────────┬──────────────┐
    ▼              ▼              ▼
[session de]  [session en]  [session es]      GeminiLiveSession.swift ×3
 target: de    target: en    target: es       (one WebSocket each)
    │              │              │
    └──────────────┴──────────────┘
                   ▼
        TurnLogic (pure, tested at L1)        Models/TurnLogic.swift
        which language was spoken? → which session's output is the
        real translation? → may this turn become a bubble?
                   ▼
        GeminiLiveTranslationService          orchestration: audio I/O,
        plays the translator session's        timers, reconnects
        audio, commits one bubble per turn
                   ▼
        ConversationViewModel → ContentView   one screen, one button
```

## The language pair (2026-07-28)

Settings select an explicit pair: home (right side, large type, default
German) and partner (left, default English/🇺🇸) from de/en/es/fr/ko/zh —
every code verified against the live model (`Tools/targetprobe.sh`). One
session per side, so exactly TWO sessions run. The direction doctrine
generalizes: the home session translates substantially iff the input was
not the home language; partner-session output plus 1.2s of home silence
means the home language was spoken. The historical section below explains
why three sessions existed before the pair was explicit.

## Why three concurrent sessions (historical)

Gemini Live Translate supports exactly **one fixed target language per
session** (source auto-detected). German's own target is not recoverable
from audio — it's whichever language the current listener speaks — so the
app follows the conversation (SPEC §3.1): German translates into the last
non-German language heard.

That rule is why all **three** sessions must always run: if only de+en were
open, the first Spanish utterance could be translated *to* German, but
German's reply could never become Spanish — the es session wouldn't exist.
(This exact bug shipped briefly: the code ran two sessions with the partner
hardcoded to English. L1 tests couldn't see it; replaying Spanish audio at
L3 does.)

Normally exactly one session translates any given utterance (the one whose
target isn't the spoken language, per TurnLogic); the sessions whose target
*is* the spoken language stay effectively silent for that turn, and only the
translator session's audio is played.

## Turn lifecycle

1. Mic chunks (64ms, 16kHz PCM) stream to both sessions of the pair. Audio captured
   before the sockets finish connecting is buffered and flushed on connect
   (SPEC R4) — the mic "opens" only when **all** sessions are ready.
2. Sessions stream back `inputTranscription` (detected language code +
   text — drives the live provisional line and the button glow) and
   `outputTranscription` + audio chunks (the translation).
3. `TurnLogic.noteInputLanguage(_:from:)` locks the spoken language — and
   with it the translator session — by **settling, never first-code-wins**:
   votes are collected for a 1.5s window after the first recognized code,
   then the plurality wins. Live replays showed a turn's opening burst can be
   unanimously wrong (German after Spanish reads as "es" for ~1s before
   every session corrects itself), stragglers keep re-announcing a finished
   turn's language for ~2s after it finalizes (a grace window drops exactly
   those — a different language right after a turn is a fast reply and
   counts), a stale vote tally expires after 4s so a stray code can't
   pre-expire the settle window, and the session whose target equals the
   spoken language can emit pure garbage ("ja" + a katakana transcript for
   plain English — those codes cast no global vote).
4. **Which session reported a code is itself evidence** (#83/#84,
   2026-08-10). Alongside the global tally, `TurnLogic` keeps a per-session
   record of that session's own votes — keyed by the raw code, so unmapped
   ones like "ja"/"pt" compete rather than vanish. This exists because the
   earlier tell, token overlap between an output and what was heard, was
   deciding who spoke on the strength of plurals and apostrophes. Measured
   across 50 kept replay logs: every mis-hearing round-trip turn shows the
   **crossed** pattern — the home session votes the partner language
   unanimously while the partner session, which heard the German correctly,
   votes home — and no genuinely-foreign turn ever has the partner session
   reading home. So a high-overlap home output counts as an echo only when
   the partner's own reading corroborates that home speech happened, and the
   foreign-language veto yields only for that complete crossed shape:
   partner settle **plus** partner-home evidence that predates the settle
   **plus** a corroborated round-trip echo. The corroboration bar is a
   strict plurality within that session's own votes and a quorum of three —
   two strays were reproduced committing an English echo as Heiko's own
   bubble. Per-session evidence expires with the global tally, settled or
   not; a dead context must not lift a live veto.

   The same corroboration runs in the other direction: when the codes settle
   on **home** and the FULL crossed shape is present — each session reporting
   the other's language by its own plurality and quorum — the home session's
   output no longer gets to overrule them. Device evidence (build 2.3.48,
   2026-08-10) had exactly that state — codes settled `de`, partner session
   voting home nine times, home session mis-hearing nine times — and the
   direction still flipped six times in four seconds, because
   `homeIsRealTranslation` is consulted first and an echo shorter than
   `echoMinTokens` cannot be recognised as an echo, so the size ratio decided
   each streamed chunk.

   The crossed shape is required rather than just "settled home + partner
   agrees", because **those two are not independent**: `spokenLang` is derived
   from a pooled tally that already contains the partner session's votes, so a
   partner session emitting a quorum of stray home codes satisfies both halves
   with the same three votes. That version committed an ordinary foreign turn
   as Heiko's own bubble (L1.64e). The home session's own reading is what
   partner noise cannot forge. And this is deliberately *not* "a home settle
   wins": L1.20 is a measured turn where the codes lie about home and the home
   session's substantial translation is right to beat them — there the home
   session reads HOME, so the crossed shape never forms.
5. Pre-commit a direction is **provisional and re-derivable**. Streaming can
   set `.foreignSpoken` from an echo prefix that arrives before the votes
   exposing it, so a direction whose evidence no longer holds is cleared
   rather than latched — in both directions, since a `homeSpoken` resolved
   before the codes arrive must also clear when a late foreign settle arms
   the veto. Only the translator session's audio plays (energy-gated by RMS
   to skip near-silence), and it is released **only through
   `TurnLogic.committedTranslator`** — a pure gate that names a session only
   after a successful commit. Playing PCM is irreversible and can speak the
   other person's words in Heiko's voice, so a guess is never enough;
   translated audio arriving earlier is buffered so the head of a
   translation isn't clipped.
6. **When the speaker has stopped is decided by `SpeechEndPolicy`**, pure for
   the same reason `FinalizePolicy` is (#21): L1 and the L3 harness run the
   rule the app runs. The transcript-idle timer proposes at 1.4s; the
   microphone disposes. A speech-level mic buffer within 0.5s of the attempt
   means the speaker is plausibly still going, so the release defers and
   re-checks every 0.25s — device evidence had the idle timer firing 148ms
   after a loud buffer, mid-sentence. Accumulated deferral is capped at 2.5s
   so a loud room degrades to the old behaviour instead of holding a turn
   open: the RMS floor was calibrated speech-vs-silence, not speech-vs-babble,
   and the cap is what makes that ignorance safe. A normally-ending turn is
   unaffected — the mic is already quiet when the timer fires.
7. A turn finalizes when translated audio has been quiet for 0.45s
   (`outputTailTimeout`) — but never while input transcription is still
   progressing, since a pause in the translation mid-sentence is a breath,
   not the end of the turn (truncating there was the long-sentence R5
   failure) — or, if no translation audio ever arrived, when input
   transcription has been idle for 1.6s (`inputIdleTimeout`), a watchdog
   that stops a stale translator swallowing the next utterance. The
   server's `turnComplete` is parsed but ignored: this preview model
   doesn't send it reliably (see wire findings below), so the idle
   timeouts are the only turn-end signal.
8. `TurnLogic.commit` enforces SPEC §5.1's gates (language known — with a
   plurality fallback for short turns that never settled, something said,
   translation present, not already committed) and produces exactly one
   bubble per utterance. The committed original prefers the **translator
   session's transcript** (its target never equals the spoken language, so
   it avoids the garbage-transcript quirk). The commit also logs what *both*
   sessions heard, escaped onto one line — diagnostic only, and deliberately
   not the transcript-selection input, so a log can distinguish a selection
   failure from a shared mis-transcription. Then per-turn state resets;
   `activePartner` (the direction memory) survives.

## Audio: full-duplex with real echo cancellation

`.playAndRecord` + `.voiceChat` + `setVoiceProcessingEnabled(true)` on the
input node engages the hardware voice-processing I/O unit — real acoustic
echo cancellation. The mic keeps streaming while a translation plays (so
speech during playback isn't lost, SPEC R6 the honest way) and the AEC stops
the app re-hearing its own output. `.voiceChat` mode alone does **not**
enable AEC for an `AVAudioEngine`; the explicit call matters. Playback is
24kHz PCM through an `AVAudioPlayerNode`.

## Wire protocol — verified against the live API, not just docs

Findings from direct protocol testing (2026-07-19, `Tools/livetest.py`) and
the L3 replay harness (2026-07-25, `Tools/l3replay.sh` — real audio through
the real session and turn logic), all reflected in the code:

- Each session re-announces the detected input language roughly once per
  second, keeps doing so for ~2s **after** an utterance completes, and the
  first ~1s of a new utterance can misdetect — even unanimously across both
  sessions. Hence the settle window, straggler grace, and plurality
  rules in `TurnLogic` (tested at L1.15–L1.18).
- A *short* German sentence immediately after Spanish context can stay
  misdetected as Spanish for its whole duration, transcripts included. No
  client logic can recover that (SPEC §6 accepts it); longer German speech
  self-corrects after ~1s.

- `inputAudioTranscription`/`outputAudioTranscription` must be **siblings of
  `generationConfig`** inside `setup` — the server rejects the nested form.
- This preview model does **not reliably send `turnComplete`** — 60+
  messages for a correctly transcribed and translated sentence, no
  `turnComplete` anywhere. Hence the idle-timeout turn resolution.
- Sessions have a bounded duration and send `goAway`; the client must close
  promptly or get force-closed with a 1008. The service closes its side and
  reconnects (SPEC R7); transport errors after a close are expected noise
  and stay out of the UI.
- Any server message shape the code doesn't recognize surfaces via
  `.raw(...)` into the console log rather than being silently dropped —
  check there first if audio stops coming back.

## Cost

Google's published pricing for the dedicated Live Translate model is about
$0.0053/min audio-in and $0.0315/min audio-out. Both sessions of the pair
stream input concurrently for every open-mic minute (≈2× input cost,
≈$0.011/min), and a typical utterance is translated by one of them. Still a
small fraction of a dollar per conversation — but the app streams
continuously while the mic is open and has **no offline mode**.

## Failure handling

- **The microphone can come up dead on the first start of a process.**
  Measured on device 2026-07-27, when three sessions still ran: all of them
  reached
  `setupComplete` in 4.3s while the input tap delivered *zero* buffers —
  enabling voice processing reconfigures the input hardware out from under
  the freshly installed tap. Rebuilding the audio path fixes it instantly,
  which is what the manual mute/unmute ritual was really doing. A watchdog
  now checks at 0.5s and rebuilds automatically (twice at most).
- **A turn must not end while its translation is still streaming.** Same
  session: `"…wir haben im Moment keine"` committed as one bubble and the
  rest of that sentence, `"Gurken mehr."`, landed in the next one against
  unrelated English. Finalizing now requires the *output* side to have been
  quiet for 0.9s as well as the input side.
- **Held translation audio must survive a late direction.** Measured
  2026-07-29 (degraded LTE): the partner session's whole translation
  arrived in one burst shorter than the 1.2s home-silence confirm, so no
  event ever re-evaluated the direction — the audio sat in
  `pendingOutput` until the post-commit reset silently dropped it, and
  the first translation was never heard. The fix, hardened by an
  adversarial review of its first draft:
  - `speakerStopped` re-evaluates `noteOutputs` (the confirm is
    time-based), and a 0.25s recheck clock keeps re-evaluating while
    audio waits on an unknown direction.
  - A successful commit plays whatever is still held before the reset.
  - Loud audio chunks update `lastOutputAt` (they used not to), so the
    finalize gate's "output quiet ≥0.9s" can't fire mid-stream of the
    translation's audio.
  - After a commit the translator's chunks keep playing straight through
    for a 2.5s linger window (text can commit seconds before its audio
    on a starved uplink) instead of being misfiled into the next turn's
    buffers; new speech cancels the linger.
  - Safety: `noteOutputs` applies the same codes-veto as commit before
    resolving homeSpoken, because the partner session *echoes* foreign
    speech (measured: en session echoed English input while de stayed
    silent) and that echo must never play as a translation. Trade-off,
    accepted: if codes ever mis-settle on a foreign language while the
    home language was really spoken, the audio is now withheld along
    with the bubble (pre-veto the audio played while the bubble was
    rejected — audible and visible behavior now agree). Residual known
    gap: with codes never settling at all, an echo can still resolve
    homeSpoken after 1.2s of home silence — pre-existing, needs
    foreign speech + a silent home session + unsettled codes at once.
- **A settled language can be poisoned — two guards.** Measured
  2026-07-29 15:03 (device): straggler codes from the previous English
  turn kept arriving through 8s of pure silence (mic peaks 0–5) and
  settled the NEXT turn's language as "en" before its speech began; the
  German that followed sent twelve unanimous "de" codes, but a settle
  was immutable, so the codes-veto swallowed the turn — audio and
  bubble. Worse, it was a cascade: the straggler-grace filter was aimed
  at the wrong language because the previous turn's settle had itself
  been poisoned. Guards: (1) the service drops codes until the mic has
  actually heard speech this turn (silence-era codes are stragglers by
  construction; floor 400 RMS vs 991–5263 measured speech); (2)
  `TurnLogic` re-settles after three CONSECUTIVE votes for one other
  language — the normal lying-code noise alternates (en,de,en,de) and
  never reaches three in a row (L1.25/L1.25b).
- **Short answers are real translations.** Measured 2026-07-29 15:27: a
  spoken number's home translation ("14 Euro", 7 chars) fell under the
  8-char false-start floor and the turn was swallowed. The floor now
  applies only while the codes don't corroborate: once they settle on a
  non-home language, foreign speech is confirmed and any nonempty home
  output counts (L1.26/L1.26b keep the "Ich" false-start guard intact).

- **Session errors retry with backoff** (2s/5s/10s, attempts reset on a
  successful setup). Only a persistently failing session stays dead, with
  its error on screen. The mic-open gate counts only live sessions, so one
  failed handshake can't hold the app in "Verbinde…" forever.
- **Session expiry** (`goAway`, observed ~9 min) surfaces as `.closed` and
  reconnects silently (SPEC R7) — verified live by `Tools/l2expiry.sh`.
- **A replacement session hears nothing until its own `setupComplete`.**
  The connect path always guarded against premature audio; the renewal path
  did not — the sending loops selected on "not dead" and `reconnect` never
  cleared readiness, so every goAway renewal fed the fresh WebSocket
  `realtimeInput` mid-handshake (GitHub #15). Readiness is now cleared at
  `.closed` and in `reconnect`, sending selects on readiness, and speech
  during the window is held per language — a rolling ~3.2s of newest chunks,
  delivered once after the new setup, so a renewal mid-sentence loses
  nothing (R4) while a slow reconnect can't flush stale history into a
  fresh turn. A session error drops its held audio instead.
- **Audio interruptions and backgrounding** (phone call, Siri, app switch):
  the view model stops the sessions and resumes listening by itself when
  the app is active again — the user never has to know.
- **Permission denial** is re-explained on every tap of the button (the
  start path always goes through the permission gate), so a denied mic
  never becomes a silently dead app (R8).
- The launch/connecting phase shows "Verbinde…"; the red "Mikrofon
  pausiert" appears only for an actual mute (SPEC §4.3).
- **Connection quality is inferred, not read** — iOS exposes no public
  signal-strength API. `ConnectionQuality {good, degraded, silent,
  offline}` in the service: `NWPathMonitor` decides *offline*; while mic
  audio is streaming, a >3s gap in server events is *degraded* and >6s is
  *silent* (measured 2026-07-29 on 2-bar LTE: the uplink starves while
  the path stays "satisfied", so path monitoring alone is blind to it).
  Hysteresis — degrade immediately, recover after 3 consecutive good
  heartbeats — keeps the SPEC §4.5 banner from flickering.

## Accepted tradeoffs

- No offline fallback — the entire conversation needs a live connection.
- Language detection is the model's; short/noisy speech can misdetect, and
  the app does not try to out-guess it (SPEC §6).
- Preview API — shapes can change under us; the `.raw` logging and
  `Tools/livetest.py` exist to catch that quickly.
