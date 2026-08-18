# Heiko Translate — Product Specification

## 1. What this app is

A one-screen iPhone app that lets Heiko (speaks only German) have a real
conversation with someone who speaks English or Mexican Spanish. It listens,
translates, and speaks the translation out loud, in both directions,
automatically.

It is a gift for a non-technical person. **Simplicity beats features.** If a
choice is between "more capable" and "impossible to get wrong", choose the
latter.

## 2. Who uses it

| User | Speaks | Needs |
|---|---|---|
| Heiko | German only | To understand and be understood, without touching settings |
| The other person | English or Mexican Spanish | To be understood by Heiko |

Heiko may be holding the phone, or it may lie on a table between two people.

## 3. Core behaviour (the rules)

### 3.0 Language set (v1)

Four languages, fully interchangeable: **German, English (US), Korean,
Mexican Spanish**. Either side of a pair may be any of them, so v1 offers
six pairs: de↔en, de↔ko, de↔es, en↔ko, en↔es, ko↔es.

This is a deliberate constraint, not a backlog gap. The set is chosen so
that every pair in the mesh is viable. No pair is offered that I would not
hand to a user.

Why these four:

- The turn router infers who spoke from which fixed-language session
  produced plausible output (§3.1, `docs/ARCHITECTURE.md`). That signal is
  circular: a session pinned to one language will transcribe a neighbouring
  language as its own and sound confident about it. Issues #125, #121, #137
  and #128 are all instances of this.
- So pair difficulty is driven by two things: acoustic distance between the
  languages, and shared vocabulary. Two languages that are far apart and
  share no lexicon give the router room to be right by accident. Two that
  are close do not.
- German and English are non-negotiable, they are the app's purpose, and
  they are also the hardest pair in the set, because spoken German carries
  heavy English loanword density. That pair has to be solved regardless.
- Korean and Spanish are both far from the anchors and from each other,
  with effectively no shared lexicon. Korean is included on evidence: it
  worked in live testing.

French was cut for one reason: adding it creates fr↔es and en↔fr edges.
Both are high-cognate, low-distance pairs and would reintroduce the #125
failure mode into an otherwise clean mesh. Excluded on the same grounds:
any Romance-to-Romance pair, Germanic neighbours (nl, sv), and en↔hi, where
speakers code-switch constantly.

**This set is a function of current language-identification quality in the
Gemini Live API, not a permanent product decision.** The constraint is that
turn direction is inferred rather than known. Once the API exposes a
reliable independent language signal, or once the on-device speech
recognition referee in #135 is in place and validated, the acoustic-distance
requirement relaxes and French and other close pairs become candidates.
Revisit then.

Decided 2026-08-18, and applied to the code in the same session: `Lang` now
holds exactly these four, both settings wheels offer all of them, and the
French, Chinese, Tagalog and Vietnamese cases are gone along with the
partner-only distinction (#30) that Tagalog and Vietnamese existed for. A
phone that stored one of the retired languages loads the default pair
instead, and says so in the diagnostic log.

### 3.1 Translation direction
The app translates between an explicitly selected **language pair**
(language pill → Sprachen): a **home** language (German by default — the phone
owner's reader language) and a **partner** language (English/🇺🇸 by
default). Available: the v1 set in §3.0 — German, English (US), Korean,
Spanish (MX) — every pairing, both directions, either language on either
side. There is no partner-only language: every one of the four renders the
whole UI, so every one of them can be the reader's side.

- Someone speaks the **partner language** → said in the **home language**.
- Someone speaks the **home language** → said in the **partner language**.
- Someone speaks a **third language** → said in the **home language**
  (the home reader is always served).

The home language is always one side of every bubble. The pair is
explicit, so nothing is inferred from the conversation anymore.

### 3.2 The single control
One button. Tap it to mute; tap again to unmute. Nothing else is
interactive.

> **Temporary deviation (2026-07-27):** the app is *supposed* to start
> already listening, and R4 depends on it. On device, speech at launch is
> still being lost (TESTING.md, open bug), so for now the app opens muted
> and says `Zum Sprechen antippen` under the button — honest about not
> listening rather than looking alive while hearing nothing. Restore the
> hot mic once the launch-capture bug is fixed.

### 3.3 Turn-taking
1. A person speaks.
2. The app shows the words appearing live, in the language being spoken.
3. **When they stop** — not before — the app speaks the translation out
   loud. The model is a *simultaneous* interpreter and starts producing
   translated audio mid-sentence; playing it as it arrives talks over the
   speaker and cuts their turn short. So translated audio is held until
   they have been quiet for about a second, then played.
4. The app is ready for the next person immediately after.

## 4. The screen

```
┌─────────────────────────────┐
│  Hello, how are you?        │   ← left, black bubble
│  Hallo, wie geht's?         │      (foreign language spoken)
│                             │
│        Mir geht es gut.     │   ← right, grey bubble
│        I'm doing well.      │      (German spoken)
│                             │
│           🇺🇸                │   ← the one button
│         Verstehe            │   ← status
└─────────────────────────────┘
```

### 4.1 Message bubbles — the rules
- **German spoken → RIGHT side, indigo background.** Always.
- **English or Spanish spoken → LEFT side, dark grey background.** Always.
- Both carry a hairline stroke a shade lighter than their fill. On a
  near-black screen the fills alone lose their silhouette; the stroke is
  what keeps a bubble a bubble.
- The side is decided by **the language that was actually spoken**, never by
  which internal session produced the translation.
- Line order: top is **what was said, in the language it was said in**;
  below it, **the translation** (what the app speaks aloud).
- Type size follows the **language**, not the position: **the German line is
  always the large white one; the English/Spanish line always the smaller
  grey one** — whichever of the two lines it happens to be. Heiko is the
  reader: the line he can read must be the prominent one on both sides of
  the exchange.
- **One utterance = exactly one bubble.** Never two bubbles for one thing
  said.

### 4.2 The button
- Shows a **microphone**. It says start and stop, which is an action; the
  languages are state and live in the pill at the top (§4.4). The button
  used to carry the split flag, doing both jobs at once — and a flag does
  not tell anyone what pressing it will do.
- Voice-driven rings unfold outward while listening; sonar ripples
  emanate while the translation is spoken. Both in a faint lavender.
- Shows a spinner while connecting.
- The glyph grows with the sound reaching the microphone: the app's
  "I can hear you" signal, driven by the mic rather than by anything the
  API has decided yet.

### 4.4 Settings (the language pill, top centre)
A capsule showing **the two flags of the current pair** — partner left,
home right, matching the conversation's sides — opens the language sheet:
two wheel pickers, each parking its selection in a chat bubble on the side
that language occupies in the conversation. Selecting the same language on both
sides swaps them. The choice is remembered; changing it mid-conversation
restarts the translation. This is the ONLY settings surface, deliberately
quiet — Heiko never needs it.

Beneath the wheels sit three quiet rows, all in the reader's language: the
text-size slider, the log-share row ("Protokoll an Georg senden", the one
action he may ever be asked to perform), and a **Datenschutz** row that
opens the published privacy policy in the browser
(`https://www.georgklock.com/heiko-translate-privacy`) — the in-app policy
link App Review 5.1.1(i) requires, placed here so the one-button screen
stays one button (#91).

The pill replaced a gear because the destination is language selection, and
for a user who reads no English two flags say that better than a cog does.
It doubles as the only permanent readout of which pair is active.

**The build number** sits bottom-right, dim and **non-interactive**. It
answers "is my phone current?" and nothing else — deliberately not a second
tappable thing on a one-button screen, and hidden from VoiceOver. It yields
to anything in the status slot below the button.

### 4.3 Status line (German, because Heiko reads it)
| State | Text |
|---|---|
| Connecting | `Verbinde…` |
| Ready, nothing happening | *(blank)* |
| Hearing speech | `Verstehe` |
| Speaking the translation | `Übersetze` |
| Muted | `Mikrofon pausiert` (red) |

### 4.5 Connection warning (German, persistent)

iOS has no public signal-strength API, so quality is inferred from what
the app can observe. While a warning condition holds, a capsule pill sits
in the status slot under the button — where instructions always appear —
never floating over the transcript (a first version did, and covered the
bubbles). The red "Mikrofon pausiert" outranks it:

| Condition | Text | Tint |
|---|---|---|
| Server events lag >3 s while streaming | `Schlechte Verbindung — die Übersetzung kann darunter leiden.` | orange |
| No server events for >6 s while streaming | `Keine Antwort vom Server — bitte Internetverbindung prüfen.` | red |
| Network path down (NWPathMonitor) | `Keine Internetverbindung.` | red |

The banner degrades immediately but recovers only after ~3 s of healthy
traffic, so a marginal connection doesn't make it flicker.

## 5. Rules that must never be broken

These are the invariants. A build that violates any of these is broken,
regardless of what else works.

- **R1 — One utterance, one bubble.** No duplicates, ever.
- **R2 — German is always right, foreign is always left.** No exceptions.
- **R3 — A bubble is only created when the turn is complete.** See §5.1.
- **R4 — Nothing spoken is lost.** Speech from the moment the app opens must
  be captured, even while still connecting.
- **R5 — Long sentences survive.** A 60-word sentence must be fully
  transcribed and fully translated. (Verified: the API handles this; any
  truncation is our bug.)
- **R6 — It never talks to itself.** The app's own spoken output must never
  be treated as new input.
- **R7 — It recovers by itself.** When a translation session expires, it
  reconnects without the user noticing and without losing the conversation.
- **R8 — No dead ends.** The app must never sit in a state where speaking
  does nothing. If something fails, it recovers or says so.

### 5.1 R3 in detail — live text vs. committed bubbles

Two different things appear on screen, with different rules:

| | **Live transcript** | **Bubble** |
|---|---|---|
| When | While someone is speaking | After they finish |
| Look | Faded, provisional | Solid, permanent |
| Changes? | **Yes** — revises constantly | **Never** |
| Lifetime | Replaced by the bubble | Stays in history |

Words streaming in and being revised ("I'm doing well, how" → "I'm doing
well, how are you?") is **correct and wanted** — it is the feedback that
tells the speaker the app is hearing them.

**R3 governs only the bubble.** A bubble may be created only when *all four*
are true:

1. **The spoken language is known.** Otherwise we cannot know which side it
   belongs on.
2. **The speaker has actually stopped** — a real end, not a mid-sentence
   pause.
3. **The translation is present.** A bubble with no translation is broken.
4. **This turn has not already been committed.**

If any is false: keep showing live text and wait. **Never commit early and
correct it afterwards.** The live line becomes the bubble in place — no
flicker, no second copy. (Its styling settles to the §4.1 rules at that
moment: a foreign-language line takes the smaller grey style as the large
German translation appears beneath it. That restyling is expected — what
must never change is the words themselves.)

Why this matters more here than in most apps: **Heiko cannot check the
translation himself.** A line that is visibly still working is honest. A
permanent line that is wrong is not.

Failure modes this prevents (all observed):
- Committing before the language is known → bubble on the wrong side.
- Committing on a mid-sentence pause → truncated sentence.
- Two code paths committing the same turn → duplicate bubbles.

## 6. Known constraints (things we accept)

- **Translation sessions expire** after a few minutes; the app must
  reconnect silently (R7).
- **Language detection is the model's**, and it can be wrong on short or
  noisy speech. We do not try to out-guess it.
- **The de↔es pair inherits the German-after-Spanish mishearing more
  strongly than the old three-session design did**: without an English
  session as a third opinion, a short German sentence right after Spanish
  can be treated as Spanish and land left, translated into German. Longer
  German recovers. Documented in TESTING §L3; an optional referee session
  is the known fix if this matters in practice.
- **Code-switched sentences follow the model's reading.** A German sentence
  opening with English words ("Happy birthday ist mein Lieblingslied") may
  be treated as foreign and land on the left. That is accepted: "which
  language was that?" has no single right answer for mixed speech, and the
  invariant that matters survives — the bubble always carries a large,
  legible German line. Measured in full on 2026-07-29: an utterance that
  opened in English and switched to German mid-sentence became ONE left
  bubble whose transcript rendered the German half as English and whose
  translation partially restated the speaker's own German. Splitting the
  turn at the switch is not buildable: the language codes during a real
  switch (one session says en, the other de, every beat) are byte-for-byte
  identical to the sessions' normal lying-code noise during single-language
  speech — the same log shows both. Rule of thumb for bilingual users:
  one utterance, one language. The gift use-case is immune — each real
  speaker talks in their own language.
- **German's target language is ambiguous** by nature — we follow the
  conversation (§3.1).
- Requires a network connection. There is no offline mode.
- **Hesitation noises are stripped from the text but still heard in the
  audio.** The spoken translation is rendered by the model itself (that is
  what preserves the speaker's own voice), so an "ähm" it chose to
  translate gets said aloud. Editing that audio would mean replacing it
  with a synthetic voice — a worse trade. The transcript is the cleaned
  record; the audio is the natural one.

## 7. Out of scope (v1)

- Saving or exporting conversations
- Text input
- More than one pair at a time (three-way conversations)
