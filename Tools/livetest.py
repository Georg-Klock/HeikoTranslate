#!/usr/bin/env python3
"""
Standalone harness for testing Gemini Live Translate the same way the app
uses it — but without the phone, so behaviour can be iterated on quickly.

It speaks the SAME wire protocol as GeminiLiveSession.swift: same setup
message, same realtimeInput audio frames (16-bit PCM, 16kHz, mono), and the
same response parsing. So what it reproduces here is what the app will do.

Usage:
    python3 Tools/livetest.py --text "a long sentence to test" --target de
    python3 Tools/livetest.py --audio some.wav --target de

Reads the API key from HeikoTranslate/Resources/Secrets.plist.
Requires: pip install websockets
"""

import argparse
import asyncio
import base64
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import wave

ENDPOINT = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
)
MODEL = "models/gemini-3.5-live-translate-preview"
CHUNK_MS = 64  # roughly what the app's audio tap produces


def load_api_key() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    plist_path = os.path.join(here, "..", "HeikoTranslate", "Resources", "Secrets.plist")
    with open(plist_path, "rb") as f:
        return plistlib.load(f)["GEMINI_API_KEY"]


def say_to_pcm16k(text: str, voice: str) -> bytes:
    """Render text to speech with macOS `say`, return 16kHz mono PCM16."""
    with tempfile.TemporaryDirectory() as td:
        aiff = os.path.join(td, "s.aiff")
        wav = os.path.join(td, "s.wav")
        subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav],
            check=True,
        )
        return read_wav_pcm16k(wav)


def read_wav_pcm16k(path: str) -> bytes:
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2, "expected 16-bit PCM"
        assert w.getnchannels() == 1, "expected mono"
        assert w.getframerate() == 16000, f"expected 16kHz, got {w.getframerate()}"
        return w.readframes(w.getnframes())


async def run(pcm: bytes, target: str, realtime: bool, quiet_tail: float,
              result: dict, speak_voice: str | None = None) -> dict:
    import websockets  # imported here so --help works without the dep

    url = f"{ENDPOINT}?key={load_api_key()}"
    result.update({
        "setup_complete": False,
        "input_transcript": "",
        "output_transcript": "",
        "input_langs": set(),
        "output_langs": set(),
        "audio_bytes": 0,
        "messages": 0,
        "errors": [],
        "closed": None,
    })

    async with websockets.connect(url, max_size=None) as ws:
        setup = {
            "setup": {
                "model": MODEL,
                "generationConfig": {
                    "responseModalities": ["AUDIO"],
                    "translationConfig": {
                        "targetLanguageCode": target,
                        "echoTargetLanguage": False,
                    },
                },
                "inputAudioTranscription": {},
                "outputAudioTranscription": {},
            }
        }
        if speak_voice:
            setup["setup"]["generationConfig"]["speechConfig"] = {
                "voiceConfig": {"prebuiltVoiceConfig": {"voiceName": speak_voice}}
            }
        await ws.send(json.dumps(setup))

        async def reader():
            try:
                async for raw in ws:
                    result["messages"] += 1
                    try:
                        msg = json.loads(raw)
                    except Exception:
                        continue
                    if "error" in msg:
                        result["errors"].append(msg["error"])
                        continue
                    if "setupComplete" in msg:
                        result["setup_complete"] = True
                        continue
                    if "goAway" in msg:
                        # Close on cue, the way GeminiLiveSession does — the
                        # server force-closes lingerers with a 1008, which is
                        # exactly what the #65 run collected.
                        result["closed"] = "goAway"
                        await ws.close()
                        break
                    sc = msg.get("serverContent")
                    if not sc:
                        continue
                    it = sc.get("inputTranscription") or {}
                    if it.get("languageCode"):
                        result["input_langs"].add(it["languageCode"])
                    if it.get("text"):
                        result["input_transcript"] += it["text"]
                    ot = sc.get("outputTranscription") or {}
                    if ot.get("languageCode"):
                        result["output_langs"].add(ot["languageCode"])
                    if ot.get("text"):
                        result["output_transcript"] += ot["text"]
                    mt = sc.get("modelTurn") or {}
                    for part in mt.get("parts", []):
                        data = (part.get("inlineData") or {}).get("data")
                        if data:
                            result["audio_bytes"] += len(base64.b64decode(data))
            except Exception as e:
                result["errors"].append(f"reader: {e}")

        reader_task = asyncio.create_task(reader())

        bytes_per_chunk = int(16000 * 2 * CHUNK_MS / 1000)
        try:
            for i in range(0, len(pcm), bytes_per_chunk):
                chunk = pcm[i : i + bytes_per_chunk]
                await ws.send(json.dumps({
                    "realtimeInput": {
                        "audio": {
                            "data": base64.b64encode(chunk).decode(),
                            "mimeType": "audio/pcm;rate=16000",
                        }
                    }
                }))
                if realtime:
                    await asyncio.sleep(CHUNK_MS / 1000)

            await ws.send(json.dumps({"realtimeInput": {"audioStreamEnd": True}}))
        except websockets.ConnectionClosed:
            # The goAway path closes our side promptly now, and that close can
            # land mid-send. The tail loop below exits on `closed`, and
            # validation judges what was collected.
            result["errors"].append("connection closed while sending")

        # Wait for the tail of the response.
        last = -1
        stable_for = 0.0
        while stable_for < quiet_tail and not result["closed"]:
            await asyncio.sleep(0.25)
            if result["messages"] != last:
                last = result["messages"]
                stable_for = 0.0
            else:
                stable_for += 0.25

        reader_task.cancel()

    result["input_langs"] = sorted(result["input_langs"])
    result["output_langs"] = sorted(result["output_langs"])
    return result


def validation_error(result: dict) -> str | None:
    """Why this probe result is NOT a pass — or None if it is one.

    The probe used to print everything it collected and exit 0 regardless, so
    a server error, a rejected setup or a completely empty response all looked
    green to a script or a person checking `$?` (GitHub #20). Pure, so
    `Tools/tests/livetest-validation.py` holds it against fake results without
    the network.
    """
    if result.get("deadline_exceeded"):
        return (f"deadline exceeded — {result['messages']} messages and "
                f"{result['audio_bytes']} audio bytes and still streaming "
                f"(runaway generation, or the quiet tail never fired: #65)")
    if result["errors"]:
        return f"server errors: {result['errors']}"
    if not result.get("setup_complete"):
        return "setup was never acknowledged (no setupComplete)"
    if not result["input_transcript"].strip():
        return "empty input transcript — the audio was not understood"
    if not result["output_transcript"].strip():
        return "no output transcript — nothing was translated"
    if result["audio_bytes"] == 0:
        return "no translated audio came back"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", help="text to synthesize as the spoken input")
    ap.add_argument("--audio", help="path to a 16kHz mono WAV to send instead")
    ap.add_argument("--voice", default="Samantha", help="macOS `say` voice")
    ap.add_argument("--target", default="de", help="target language code")
    ap.add_argument("--fast", action="store_true", help="send audio as fast as possible")
    ap.add_argument("--tail", type=float, default=4.0, help="seconds of quiet before giving up")
    ap.add_argument("--deadline", type=float, default=None,
                    help="hard cap on the whole run, seconds (default: 4x the "
                         "audio length + tail + 30, floor 60). The probe must "
                         "not be able to outlive its session: #65")
    ap.add_argument("--speak-voice", default=None,
                    help="prebuiltVoiceConfig voiceName to request in speechConfig (probe)")
    args = ap.parse_args()

    if args.audio:
        pcm = read_wav_pcm16k(args.audio)
        source = args.audio
    elif args.text:
        pcm = say_to_pcm16k(args.text, args.voice)
        source = f"say({args.voice}): {args.text[:60]}..."
    else:
        ap.error("need --text or --audio")

    secs = len(pcm) / (16000 * 2)
    print(f"input: {source}")
    print(f"audio: {secs:.1f}s -> target={args.target}\n")

    # One hard deadline over the WHOLE session — connect, send, tail. The #65
    # run streamed 2355 messages and ~28 MB for a 7-word sentence: with the
    # server never going quiet, a message-quiet tail can never fire, so the
    # probe rode the session to its ~9-minute goAway. A probe that needs this
    # cap is itself evidence of misbehaviour, and validation fails it by name.
    deadline = args.deadline if args.deadline is not None else max(60.0, secs * 4 + args.tail + 30)
    res: dict = {}

    async def capped():
        await asyncio.wait_for(
            run(pcm, args.target, realtime=not args.fast, quiet_tail=args.tail,
                result=res, speak_voice=args.speak_voice),
            timeout=deadline)

    try:
        asyncio.run(capped())
    except (asyncio.TimeoutError, TimeoutError):
        res["deadline_exceeded"] = True
        res["input_langs"] = sorted(res.get("input_langs") or [])
        res["output_langs"] = sorted(res.get("output_langs") or [])
        res.setdefault("messages", 0); res.setdefault("audio_bytes", 0)
        res.setdefault("input_transcript", ""); res.setdefault("output_transcript", "")
        res.setdefault("errors", []); res.setdefault("closed", None)

    print(f"heard  ({','.join(res['input_langs']) or '?'}): {res['input_transcript']}")
    print(f"spoke  ({','.join(res['output_langs']) or '?'}): {res['output_transcript']}")
    print(f"\naudio back: {res['audio_bytes']} bytes | messages: {res['messages']}")
    if res["closed"]:
        print(f"closed: {res['closed']}")
    if res["errors"]:
        print(f"errors: {res['errors']}")

    # A crude completeness check: did the translation cover the whole input?
    if args.text and res["input_transcript"]:
        in_words = len(res["input_transcript"].split())
        said_words = len(args.text.split())
        print(f"\ninput words spoken={said_words} transcribed={in_words}"
              f" ({in_words / max(said_words,1):.0%} captured)")

    problem = validation_error(res)
    if problem:
        print(f"\nL2 FAILED: {problem}", file=sys.stderr)
        raise SystemExit(1)
    print("\nL2 OK")


if __name__ == "__main__":
    main()
