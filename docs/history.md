# Heiko Translate — Original Project Plan (historical)

> **Historical document — do not build against this.** This is the original
> design/architecture writeup, kept for the reasoning record (why Gemini
> Live, why voice-to-voice, what the protocol testing found). Where it
> disagrees with `SPEC.md`, `docs/ARCHITECTURE.md`, or the code, **those
> win.** Known drift as of 2026-07-25: the Diktat/Freisprechen mode switch
> and the manual 🇺🇸/🇲🇽 partner toggle described below no longer exist (the
> app is one button; German's target follows the conversation, SPEC §3.1);
> the app runs **three** concurrent sessions, not two; and the scratchpad
> test scripts referenced below were preserved as `Tools/livetest.py`.

A one-button iPhone app that does live speech translation for conversations
between the user, a German speaker with no English, and Mexican Spanish
speakers. Built as a welcome gift to give him more independence.

## Decisions locked in

- **Languages:** English, German, Mexican Spanish (es-MX), auto-detected from speech.
- **Translation direction:** German is the hub; each conversation is one
  language paired bidirectionally with German, selected by the 🇺🇸/🇲🇽 toggle:
  - **🇺🇸 USA:** English heard → spoken in German, and German heard → spoken
    in English.
  - **🇲🇽 Mexico:** Spanish (MX) heard → spoken in German, and German heard →
    spoken in Spanish (MX).
  Both directions matter for both partners — Heiko needs to hear whichever
  language he's currently paired with, and that other person needs to hear
  Heiko's German translated back. There is no direct English↔Spanish
  translation; German is always one side of the pair.
- **Modes:**
  - **Diktat (Dictation):** push-to-talk. Tap the button, say one sentence, tap
    again (or it auto-stops on silence) → translated and spoken back once.
  - **Freisprechen (Open mic):** continuous hands-free conversation. The app
    keeps listening, auto-segments each utterance on a pause, translates and
    speaks it, then resumes listening — until muted.
- **UI:** one screen. One big circular mic/mute button is the only *control*
  that does something. A small mode switch (Diktat / Freisprechen) sits below
  it — not a "button" in the push-to-talk sense, just a state toggle. A
  second small toggle (🇺🇸 / 🇲🇽) selects which language is currently paired
  with German — see "Why the partner toggle is required" below, it's not
  optional polish. A text area shows the last transcript + translation, in
  large type, so Heiko (who reads German fine) can visually confirm what was
  heard. All UI copy is in German, since his phone/eyes are the ones that
  matter most.
- **Visual style:** built entirely from stock SwiftUI/HIG components rather
  than custom-designed chrome — `NavigationStack` with a standard large
  title, segmented `Picker`s grouped into a card matching Settings.app's
  inset-grouped list style (`.secondarySystemGroupedBackground`, 14pt
  continuous corners), system semantic colors throughout. Forced into dark
  mode (`.preferredColorScheme(.dark)`) rather than following the system
  setting, for this phase — deliberately reads as "an Apple app," not a
  custom brand.
- **Distribution:** Apple Developer Program ($99/yr) + TestFlight. Testers are
  invited by email; TestFlight builds are valid ~90 days, and updates go over
  the internet without needing the device in hand.
- **Voice engine:** Google's Gemini Live API (`gemini-3.5-live-translate-preview`),
  chosen over on-device STT→Claude→TTS and over OpenAI's Realtime API — see
  "Why Gemini Live" below.

## Architecture (v2 — voice-to-voice via Gemini Live)

The first version of this app chained three separate steps (on-device speech
recognition → Claude text translation → on-device speech synthesis) because
Claude has no native voice API. Gemini's Live API does true voice-to-voice
translation in one streaming connection — audio in, translated audio out,
no text hop — so the app now talks to it directly:

```
 mic audio (16-bit PCM, 16kHz, mono)
    │
    ├──────────────────────────────┬──────────────────────────────┐
    ▼                              ▼
[Gemini Live session #1]      [Gemini Live session #2]
 target language: German       target language: partner's
                                (English for 🇺🇸, Spanish for 🇲🇽)
    │                              │
    ▼                              ▼
 translated audio (if source    translated audio (if source
 language wasn't German)        language wasn't the partner
                                 language)
    │                              │
    └──────────────┬───────────────┘
                    ▼
          arbitration (see below)
                    ▼
             speaker output
```

### Why two sessions, and why the partner toggle is required

Gemini Live Translate's `translationConfig` supports exactly **one fixed
target language per session**, with the source language auto-detected across
70+ languages — there's no way to scope which source languages a session
should react to, and no per-session support for "translate into whichever
of two languages the input *isn't*."

That's a real problem here, and not just an engineering inconvenience:
**German's own translation target can't be recovered from the audio at
all.** English and Spanish are each unambiguous — they only ever need to
become German. But German needs to become *whichever language the current
listener speaks*, and that's a fact about who Heiko is talking to right
now, not something the sound of his German encodes. No amount of auto-detection
sophistication fixes that — the app has no way to know, from audio alone,
whether the person about to hear the translation understands English or
Spanish. So the 🇺🇸/🇲🇽 toggle (`ConversationPartner.swift`) isn't a nice-to-have
fallback for shaky detection — it's supplying the one piece of context
Gemini structurally cannot infer.

Given the partner is known (from the toggle), the app runs **two sessions
concurrently** against the same microphone audio — one fixed to
`targetLanguageCode: "de"`, one fixed to the partner's language
(`targetLanguageCode: "en"` or `"es"`) — and normally exactly one of the two
produces audio for any given utterance, since the two target languages are
each other's complement:

| Spoken language | DE session (target=de) | Partner session (target=partner) | What plays |
|---|---|---|---|
| Partner's language (English or Spanish) | translates → German audio | silent (it's the partner session's own target language) | German |
| German | silent (German = the DE session's own target language) | translates → partner's language | Partner's language |

Both sessions see identical audio, so in practice they finish a "turn"
within a short window of each other. The app waits ~400ms after either
session signals a turn is complete before deciding a winner, to give the
other one a chance to finish too. If detection is ever ambiguous enough that
both sessions produce audio for the same turn (not expected in normal use,
since the two targets are complementary — but kept as a defensive
tie-break), the German session's output wins and the partner session's is
discarded.

### Why Gemini Live over OpenAI Realtime

Both offer genuine voice-to-voice streaming with a dedicated
translation-specific model (not just "chat about translating"). Gemini Live
won out on three fronts for this app specifically:
- **Integration simplicity:** Gemini officially supports direct client
  WebSocket connections from app code. OpenAI's Realtime API explicitly
  recommends WebRTC for mobile/browser clients (WebSocket is positioned for
  server-to-server use) — meaning OpenAI would have pushed us toward either
  a WebRTC stack in Swift or standing up a backend relay server, neither of
  which this "dead simple gift app" needs.
- **Cost:** Gemini's dedicated translate model runs roughly $0.0053/min
  audio-in and $0.0315/min audio-out — cheaper than OpenAI's published
  figures for its translation endpoint.
- **Voice quality:** Gemini 3.5 Live Translate is voice-*preserving* — it
  keeps the original speaker's pitch, pacing, and intonation in the
  translated output, so Heiko hears something closer to "you, speaking
  German" rather than a generic narrator voice. OpenAI's dedicated
  translation model is also trained for natural, interpreter-quality
  delivery, but from a fixed set of ~9 voices rather than preserving the
  original speaker's voice.

### Real tradeoffs versus the original on-device-STT design

- **No offline fallback.** The old design used on-device Apple Speech + TTS
  and only needed network for a short text call. This version needs a live
  network connection for the entire conversation, continuously streaming
  audio both ways.
- **Continuous per-minute cost**, not per-sentence text tokens — still cheap
  for personal use, but non-zero for the whole time the mic is open, not
  just while someone is actually talking.
- **Echo/feedback risk in open-mic mode:** with both mic capture and speaker
  playback active at once, the audio session runs in `.voiceChat` mode
  specifically for its built-in echo cancellation, so the app doesn't
  re-hear (and re-translate) its own spoken output. If that's not enough in
  practice, the fallback is to manually mute mic capture while audio is
  playing, as the old design did.

### Preview-API wire format — verified directly, not just from docs

`gemini-3.5-live-translate-preview` is a preview model, and the WebSocket
message shapes in `GeminiLiveSession.swift` were originally assembled from
Google's published docs rather than tested. On 2026-07-19, once a real API
key existed, that assumption was checked directly with a standalone Python
script talking to the live endpoint (bypassing the app and the phone
entirely — see scratchpad `test_gemini_live*.py`), which found two real
bugs docs alone hadn't surfaced:

1. **Setup message shape was wrong.** `inputAudioTranscription` /
   `outputAudioTranscription` must be siblings of `generationConfig` inside
   `setup`, not nested inside it — the server rejected the nested form
   outright with `Unknown name "inputAudioTranscription" at
   'setup.generation_config'`. Fixed.
2. **`turnComplete` is not reliably sent.** A real English sentence,
   correctly transcribed (`"Hello, how are you doing today?..."`) and
   correctly translated (`"Hallo, wie geht es Ihnen heute?..."`), produced
   60+ server messages with no `turnComplete` field anywhere — contrary to
   the general Live API docs. The app no longer waits for it:
   `GeminiLiveTranslationService` now resolves a turn after ~1s of no new
   messages from either session (an idle timeout), with `turnComplete`
   kept only as a fast path in case a future API version does send it.

Every server message the code still doesn't recognize continues to log via
`print("GeminiLive[...] unrecognized message: ...")` rather than being
silently dropped.

**Not yet verified this way:** the German→partner-language direction (only
tested partner→German so far), and whether Gemini's own server-side voice
activity detection in continuous open-mic mode (no `audioStreamEnd` ever
sent) segments turns sensibly without it — both need the real app, since a
scripted test can't easily fake a natural back-and-forth conversation.

## Milestones

1. ~~**Spike:** confirm audio round-trips.~~ Done via direct protocol
   testing — see above. Remaining spike risk is specifically audio
   hardware behavior (mic capture, format conversion, playback, echo
   cancellation), which does need the real device.
2. **Verify both directions in both partner modes on the real device:** in
   🇺🇸 mode, try an English sentence then a German sentence; switch to 🇲🇽
   mode and try a Spanish sentence then a German sentence. Confirm exactly
   one language plays each time and the German→partner-language direction
   actually works (untested so far, per above).
3. **Open-mic mode:** confirm the `.voiceChat` echo cancellation is
   sufficient in practice, and that Gemini's own turn segmentation behaves
   reasonably over a continuous, un-ended audio stream.
4. **Polish for Heiko:** large German UI text, app icon (done — using an
   actual photo of Heiko), name it "Heiko Translate."
5. **Ship:** Apple Developer enrollment → TestFlight build → send the invite
   → walk the tester through installing TestFlight and accepting it.

## Cost

Gemini's dedicated Live Translate model: roughly $3.50/1M ($0.0053/min)
audio-input tokens and $21/1M ($0.0315/min) audio-output tokens, per
Google's published pricing. Because two sessions run concurrently for every
minute the mic is open, cost is roughly double a single-session estimate —
still a small fraction of a dollar per typical conversation, but check
ai.google.dev/gemini-api/docs/pricing before relying on an exact number, and
consider this in mind if data caps ever matter (this app is not
offline-capable at all in this architecture).

## Not in scope for v1 (possible later upgrades)

- More partner languages beyond English/Spanish (straightforward to add —
  another `ConversationPartner` case plus its BCP-47 code — but each
  conversation is still one partner language at a time; German still can't
  target two languages simultaneously without knowing which listener is
  which).
- Conversation history / saved transcripts.
- A manual mute-during-playback fallback, if `.voiceChat` echo cancellation
  turns out not to be enough in practice.
