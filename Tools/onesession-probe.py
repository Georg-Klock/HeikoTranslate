#!/usr/bin/env python3
"""Can ONE session pick the translation target itself? (GitHub #135, #138)

    Tools/onesession-probe.py TestAudio/de_short.wav --pair de fr
    Tools/onesession-probe.py TestAudio/es_short.wav --pair de es --model models/gemini-3.1-flash-live-preview

WHY THIS EXISTS

The app runs two sessions because of one sentence in docs/ARCHITECTURE.md:
"Gemini Live Translate supports exactly one fixed target language per session
(source auto-detected)." The target is fixed at setup, so the app opens one
session per side of the pair and infers which language was SPOKEN from which
session produced a real translation.

Every piece of arbitration in TurnLogic exists to make that inference safe —
the vote tallies, the codes-veto, the straggler windows, the settle-overturn
rule, the impossible-settle yield, and the whole second-witness search in
#135. All of it reconstructs a decision the translate model was never able to
express.

A general Live model can express it: give it both languages in a system
instruction and it chooses the target per utterance. If that works at
acceptable latency and quality, most of that machinery becomes unnecessary
rather than merely better-refereed.

WHAT IT MEASURES, PER CLIP

  chose      the language it actually produced (the whole question)
  correct    whether that is the OTHER side of the pair from what was spoken
  first      seconds from end-of-audio to the first output token
  full       seconds to the end of the turn

Latency is reported because it is the thing that decides this. The dedicated
translate model presumably exists because it is faster; a general model that
is right but slow is not obviously better for a user standing at a till.

This talks to the real API and costs a fraction of a cent per clip.

NOT the shipping path. Tools/l2probe.sh rides the app's own GeminiLiveSession
on purpose (#76: the Python twin went silent server-side while the Swift path
kept working, and a probe that tests a path the app does not ship stops being
evidence about the app). This is a protocol experiment against a DIFFERENT
model, which the app cannot currently speak to at all — so a standalone client
is the only way to ask the question. If the answer is promising, the next step
is to teach GeminiLiveSession the general-model setup and re-measure THERE
before believing any of it.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import plistlib
import sys
import time
import wave
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENDPOINT = ("wss://generativelanguage.googleapis.com/ws/"
            "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")

NAMES = {"de": "German", "en": "English", "es": "Spanish",
         "fr": "French", "ko": "Korean", "zh": "Mandarin Chinese"}


def api_key() -> str:
    """Read the key the app uses. Never printed, never logged."""
    path = REPO / "HeikoTranslate/Resources/Secrets.plist"
    try:
        with path.open("rb") as handle:
            key = plistlib.load(handle).get("GEMINI_API_KEY", "")
    except OSError as exc:
        raise SystemExit(f"cannot read Secrets.plist: {exc}") from exc
    if not key:
        raise SystemExit("Secrets.plist has no GEMINI_API_KEY")
    return key


def read_wav(path: Path) -> tuple[bytes, float]:
    with wave.open(str(path), "rb") as handle:
        if handle.getnchannels() != 1 or handle.getsampwidth() != 2 or handle.getframerate() != 16000:
            raise SystemExit(f"{path.name}: need 16kHz mono 16-bit, the format the app's mic tap produces")
        frames = handle.readframes(handle.getnframes())
    return frames, len(frames) / 2 / 16000.0


def instruction(home: str, partner: str) -> str:
    """The whole experiment is in this string.

    It states the pair and asks for the other side — deliberately WITHOUT
    naming which one will be spoken, because that is the decision under test.
    'Say only the translation' matters: a conversational model will otherwise
    answer the question it just heard, which is a different product.
    """
    return (
        f"You are a live interpreter between {NAMES[home]} and {NAMES[partner]}. "
        f"Whatever language you hear, translate it into the OTHER one of those two: "
        f"{NAMES[home]} in means {NAMES[partner]} out, and {NAMES[partner]} in means "
        f"{NAMES[home]} out. Say only the translation itself — never answer, comment, "
        f"explain, or add anything. If you hear no speech, say nothing."
    )


async def probe(path: Path, home: str, partner: str, model: str, key: str,
                quiet_seconds: float, fixed_target: str | None = None) -> dict:
    import websockets

    audio, duration = read_wav(path)
    # `fixed_target` reproduces the SHIPPING setup — the translate model with
    # one target nailed down at setup — so latency can be compared against the
    # general model on the same harness, same clips, same clock. Comparing a
    # number from here against one quoted from elsewhere would measure the
    # harness.
    if fixed_target:
        generation = {"responseModalities": ["AUDIO"],
                      "translationConfig": {"targetLanguageCode": fixed_target,
                                            "echoTargetLanguage": False}}
    else:
        generation = {"responseModalities": ["AUDIO"]}
    setup = {"setup": {
        "model": model,
        "generationConfig": generation,
        # Siblings of generationConfig, not nested — the server rejects the
        # nested form ("Unknown name 'inputAudioTranscription' at
        # 'setup.generation_config'"). Verified for the translate model in
        # GeminiLiveSession; the same holds here.
        "inputAudioTranscription": {},
        "outputAudioTranscription": {},
    }}
    if not fixed_target:
        setup["setup"]["systemInstruction"] = {"parts": [{"text": instruction(home, partner)}]}

    result = {"file": path.name, "heard": "", "said": "", "turns": [],
              "first": None, "full": None, "error": None}

    try:
        async with websockets.connect(f"{ENDPOINT}?key={key}", max_size=None) as socket:
            await socket.send(json.dumps(setup))
            raw = await asyncio.wait_for(socket.recv(), timeout=30)
            if "setupComplete" not in str(raw):
                result["error"] = f"no setupComplete: {str(raw)[:200]}"
                return result

            # Stream in real time rather than dumping the file: the model's
            # turn-taking is driven by the pace of arrival, and a clip pushed
            # in one frame measures a regime the microphone never produces.
            chunk = 16000 * 2 // 25          # 40ms
            for offset in range(0, len(audio), chunk):
                await socket.send(json.dumps({"realtimeInput": {"audio": {
                    "mimeType": "audio/pcm;rate=16000",
                    "data": base64.b64encode(audio[offset:offset + chunk]).decode(),
                }}}))
                await asyncio.sleep(0.04)
            await socket.send(json.dumps({"realtimeInput": {"audioStreamEnd": True}}))
            ended = time.monotonic()

            # Collect EVERY turn, not just the first. A fixture like
            # de_after_en is English, a 6s gap, then German — two utterances in
            # one stream — and stopping at the first turnComplete reported the
            # model as WRONG when it had answered the first utterance
            # correctly and never been asked about the second. That fixture is
            # also the most interesting test here: whether ONE session tracks a
            # language switch mid-conversation, which is the behaviour that
            # motivated this experiment.
            turn = {"said": "", "first": None, "full": None}
            while True:
                try:
                    raw = await asyncio.wait_for(socket.recv(), timeout=quiet_seconds)
                except asyncio.TimeoutError:
                    break
                message = json.loads(raw)
                content = message.get("serverContent", {})
                if text := content.get("inputTranscription", {}).get("text"):
                    result["heard"] += text
                if text := content.get("outputTranscription", {}).get("text"):
                    if turn["first"] is None:
                        turn["first"] = time.monotonic() - ended
                    turn["said"] += text
                if content.get("turnComplete") or content.get("generationComplete"):
                    if turn["said"].strip():
                        turn["full"] = time.monotonic() - ended
                        result["turns"].append(turn)
                    turn = {"said": "", "first": None, "full": None}
            if turn["said"].strip():
                turn["full"] = time.monotonic() - ended
                result["turns"].append(turn)
            if result["turns"]:
                result["first"] = result["turns"][0]["first"]
                result["full"] = result["turns"][-1]["full"]
                result["said"] = " ⏸ ".join(t["said"].strip() for t in result["turns"])
    except Exception as exc:                       # noqa: BLE001 - report, don't raise
        result["error"] = f"{type(exc).__name__}: {exc}"

    if result["full"] is None and result["first"] is not None:
        result["full"] = result["first"]
    result["duration"] = duration
    return result


def detect(text: str) -> str:
    """Which of the six the OUTPUT is in.

    Character-set and stopword heuristics, not a classifier — this only has to
    separate six known languages in clean model output, and bringing a model in
    to judge a model's output adds a failure mode to the thing being measured.
    """
    if not text.strip():
        return "-"
    lowered = f" {text.lower()} "
    if any("一" <= c <= "鿿" for c in text):
        return "zh"
    if any("가" <= c <= "힯" for c in text):
        return "ko"
    # Elisions are the highest-signal French tokens and the easiest to miss:
    # "J'aimerais un café" was scored as unknown by an earlier version of this
    # function and reported as a WRONG target, when the model had in fact
    # answered correctly. A weak detector understating the result is the worst
    # failure a measurement tool can have, because it looks like a finding.
    scores = {
        "de": sum(w in lowered for w in (" der ", " die ", " das ", " ist ", " ich ", " nicht ",
                                         " und ", " sie ", " wie ", " danke", " bitte", " guten ",
                                         " ein ", " eine ", " einen ", " gern", " hätte ", " mir ",
                                         " gut", " tag", " wo ", " kaffee")),
        "en": sum(w in lowered for w in (" the ", " is ", " you ", " what ", " where ", " how ",
                                         " please", " thank", " and ", " good ", " coffee",
                                         " i'd ", " like ", " a ", " of ")),
        "es": sum(w in lowered for w in (" el ", " la ", " es ", " qué ", " dónde ", " gracias",
                                         " por favor", " usted ", " buenos ", " está ", " un ",
                                         " una ", " café", " sí", " quisiera")),
        "fr": sum(w in lowered for w in (" le ", " la ", " est ", " vous ", " où ", " merci",
                                         " bonjour", " je ", " avec ", " un ", " une ", " café",
                                         " oui", " gare", " voudrais", " aimerais")),
    }
    # Apostrophe forms: unambiguously French among these six.
    scores["fr"] += 2 * sum(form in lowered for form in
                            ("j'", "s'il", "c'est", "qu'", "l'", "d'", "n'"))
    scores["de"] += sum(c in text for c in "äöüß")
    scores["es"] += sum(c in text for c in "¿¡ñ")
    scores["fr"] += sum(c in text for c in "àèùçêôéîû")
    # é is common to French and Spanish; the accent alone must not decide.
    if "é" in text and scores["es"]:
        scores["fr"] -= 1
    best = max(scores, key=scores.get)
    return best if scores[best] else "?"


async def main() -> int:
    parser = argparse.ArgumentParser(description="Does one session pick its own target? (#135)")
    parser.add_argument("clips", type=Path, nargs="+", help="16kHz mono WAV files")
    parser.add_argument("--pair", nargs=2, metavar=("HOME", "PARTNER"), required=True)
    parser.add_argument("--model", default="models/gemini-3.1-flash-live-preview")
    parser.add_argument("--spoken", help="language of every clip, if the filename does not say")
    parser.add_argument("--quiet", type=float, default=6.0,
                        help="seconds of silence that end a turn")
    parser.add_argument("--fixed-target", metavar="CODE",
                        help="baseline: the SHIPPING setup, translate model with this fixed target")
    args = parser.parse_args()

    home, partner = args.pair
    key = api_key()
    print(f"\nmodel  {args.model}")
    print(f"pair   {home}/{partner} — the target is NOT specified; the model chooses\n")
    header = f"{'clip':<22} {'spoke':>5} {'chose':>5} {'ok':>3} {'first':>7} {'full':>6}  said"
    print(header)
    print("-" * (len(header) + 20))

    right = scored = 0
    for path in args.clips:
        spoken = args.spoken or path.stem.split("_")[0]
        result = await probe(path, home, partner, args.model, key, args.quiet,
                             fixed_target=args.fixed_target)
        if result["error"]:
            print(f"{path.name:<22} {spoken:>5}  ERROR  {result['error'][:60]}")
            continue

        per_turn = [detect(t["said"]) for t in result["turns"]]
        chose = "/".join(per_turn) if per_turn else "-"
        want = partner if spoken == home else home
        ok = chose == want
        if spoken in (home, partner):
            scored += 1
            right += int(ok)
        first = f"{result['first']:.2f}s" if result["first"] is not None else "   --"
        full = f"{result['full']:.2f}s" if result["full"] is not None else "   --"
        said = result["said"].strip().replace("\n", " ")[:44]
        print(f"{path.name:<22} {spoken:>5} {chose:>5} {'yes' if ok else 'NO':>3} "
              f"{first:>7} {full:>6}  {said}")

    if scored:
        print(f"\ntarget chosen correctly: {right}/{scored}")
    print("\nA correct target here is the whole two-session architecture becoming "
          "unnecessary.\nLatency is the counter-argument: compare `first` against the "
          "translate model before\nbelieving it, and re-measure on GeminiLiveSession "
          "before believing that.\n")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
