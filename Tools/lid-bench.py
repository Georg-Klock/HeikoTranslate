#!/usr/bin/env python3
"""Score candidate language deciders against labelled audio (GitHub #135).

The point of this file is that "which decider is better" stops being an
argument and becomes a table. Every candidate answers the same question on the
same clips: given audio and the two languages currently configured, which one
was spoken?

    Tools/lid-bench.py TestAudio                    # the committed TTS corpus
    Tools/lid-bench.py captures/ --pair de es       # a device capture
    Tools/lid-bench.py TestAudio --models silero    # one candidate only
    Tools/lid-bench.py TestAudio --clip 2.0         # truncate to 2s first

WHAT IT MEASURES, AND WHY IT IS SHAPED THIS WAY

Every candidate is scored TWICE: open-set (its own argmax over all the
languages it knows) and pair-restricted (its probabilities renormalised over
just the two configured languages). The gap between those two columns is the
single most useful number here. The app always knows the pair in advance, so
the open-set score is the one nobody needs and the pair-restricted score is
the one that decides the design. Google's tuplemax-loss paper (ICASSP 2019,
arXiv:1811.12290) reports 2.33% pairwise error against 3.85% for plain softmax
on the same model; Whisper's own paper shows 64.5% -> 80.3% on FLEURS purely
from excluding languages that cannot be the answer. This column is where that
effect shows up or fails to.

Agreement with the app's own verdict is reported separately from accuracy. A
candidate that is accurate AND disagrees with the app on the turns the app got
wrong is the goal; a candidate that is accurate and agrees everywhere is not a
second witness, it is a second opinion from the same witness. That is the
failure that killed the third-session experiment (#125, measured 6/10 against
a 5/10 baseline), and marginal accuracy will not reveal it — only the joint
distribution will.

TWO WARNINGS, BOTH LOAD-BEARING

1. TTS is not the test. `TestAudio/` is macOS `say` output: no disfluency, no
   breath, no room. TESTING.md already records that a TTS fixture could not
   reproduce #32. A clean score here is a lead, not a verdict.

2. Accent is not language. A June 2025 paper (arXiv:2506.00628) measures
   off-the-shelf LID at 93.4% on mainstream-accented German and 61.3% on
   L2-accented German — these models are substantially accent classifiers.
   Every device recording this project has is one tester speaking both
   languages, so the non-native side carries their accent (TESTING.md, "Who is
   speaking, and why it changes what the evidence means"). Scoring a candidate
   on that audio will reject a good model for failing on German-accented
   Spanish — a condition that does not occur in deployment, where both sides
   are native speakers. Use `Tools/l4-partner.sh` audio, or native speakers.

INSTALLING THE CANDIDATES

Nothing here is a hard dependency: a model that is not installed is reported
as "not installed" and the rest of the table still prints. That is deliberate
— the bench must be runnable before deciding which model to commit to.

    python3 -m venv Tools/.venv && source Tools/.venv/bin/activate
    pip install numpy onnxruntime            # silero
    pip install speechbrain torch torchaudio  # ecapa
    pip install faster-whisper                # whisper

Model weights download on first use to ~/.cache. Silero's classifier is MIT
(4.2M params, ~17MB); SpeechBrain's VoxLingua107 ECAPA is Apache-2.0 (~85MB);
Whisper is MIT. None is copyleft. No API key, no network at inference time.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import wave
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# The app's six, plus the two secondary languages, as ISO-639-1. Kept here
# rather than imported so the bench can score a model on a language the app
# does not yet offer.
LANGS = ["de", "en", "es", "fr", "ko", "zh", "tl", "vi"]


# --------------------------------------------------------------------------
# Corpus loading
# --------------------------------------------------------------------------

def load_wav(path: Path, clip_seconds: float | None) -> tuple["object", int]:
    """Read a 16-bit mono WAV as float32 in [-1, 1].

    Deliberately strict about the format instead of resampling: every path
    that produces audio for this bench (the app's capture, make_test_audio.sh,
    l4-partner.sh) already writes 16 kHz mono, and silently resampling
    something else would hide a real mismatch between what is being measured
    and what the app hears.
    """
    import numpy as np

    with wave.open(str(path), "rb") as w:
        if w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError(f"{path.name}: need 16-bit mono, got "
                             f"{w.getnchannels()}ch/{w.getsampwidth() * 8}bit")
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())

    audio = np.frombuffer(frames, dtype="<i2").astype("float32") / 32768.0
    if clip_seconds is not None:
        audio = audio[: int(clip_seconds * rate)]
    return audio, rate


def labelled_clips(source: Path, pair: tuple[str, str] | None,
                   clip_seconds: float | None) -> list[dict]:
    """Collect (path, truth, pair, app_decision) from a directory.

    Two layouts are understood, because the corpus arrives two ways:

    - A `manifest.jsonl` written by the app's TurnAudioCapture. Its `truth`
      field is null until a human labels it; unlabelled rows are reported and
      skipped rather than guessed at, since a bench that invents ground truth
      measures nothing.
    - Bare WAVs named `<lang>_*.wav`, which is what `make_test_audio.sh`
      produces. The prefix before the first underscore is the truth.
    """
    manifest = source / "manifest.jsonl"
    clips: list[dict] = []

    if manifest.exists():
        unlabelled = 0
        for line in manifest.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                print(f"  skipping malformed manifest row: {line[:60]}", file=sys.stderr)
                continue
            if not row.get("truth"):
                unlabelled += 1
                continue
            path = source / row["file"]
            if not path.exists():
                continue
            clips.append({
                "path": path,
                "truth": row["truth"],
                "pair": (row.get("home", ""), row.get("partner", "")),
                "decision": row.get("decision"),
            })
        if unlabelled:
            print(f"  {unlabelled} capture(s) have no `truth` yet — label them in "
                  f"{manifest.relative_to(REPO) if manifest.is_relative_to(REPO) else manifest} "
                  f"and rerun\n", file=sys.stderr)
        return clips

    for path in sorted(source.glob("*.wav")):
        truth = path.stem.split("_")[0]
        if truth not in LANGS:
            continue  # noise.wav, silence.wav — not language clips
        clips.append({
            "path": path,
            "truth": truth,
            "pair": pair or (truth, "??"),
            "decision": None,
        })
    return clips


# --------------------------------------------------------------------------
# Candidates
#
# Each returns {lang: probability} over whatever languages it knows, or raises
# NotInstalled. The pair restriction is applied uniformly afterwards, so no
# candidate can accidentally get a different version of the advantage.
# --------------------------------------------------------------------------

class NotInstalled(Exception):
    pass


class Silero:
    """Silero lang_classifier_95 — 4.2M params, ~17MB, MIT.

    Smallest thing in the field that covers all eight languages. Its 85%/95-way
    figure is author-reported with no independent check and no short-clip
    breakdown, and the model was deprecated in April 2023 — which matters for
    support, not for a frozen artifact. Whether it holds up at 1-3s is exactly
    what this bench exists to find out.

    LOADED AS ONNX FROM A MIRROR, and both halves of that are forced rather
    than chosen:

    - The classifier was dropped from the repo in v5 (June 2024), so
      `torch.hub.load` against master fails outright with "Cannot find callable
      silero_lang_detector_95 in hubconf". Only the v4.0 tag still declares it.
    - v4.0's hubconf then fetches weights from `models.silero.ai`, which does
      not respond at all (measured 2026-08-17: connection timeout, no HTTP
      status). The vendor host for a deprecated model is not a dependency worth
      having.

    So this reads the 17MB ONNX and the label dictionary from the `deepghs`
    mirror on HuggingFace. That is also the artifact you would ship — MIT,
    4.2M params, no torch at inference — so the bench and any eventual
    integration measure the same file.
    """

    name = "silero"
    MIRROR = "https://huggingface.co/deepghs/silero-lang95-onnx/resolve/main"

    def __init__(self):
        try:
            import onnxruntime
        except ImportError as exc:
            raise NotInstalled("pip install onnxruntime") from exc

        cache = REPO / ".build" / "silero-lang95"
        try:
            model_path = self._fetch("lang_classifier_95.onnx", cache)
            dict_path = self._fetch("lang_dict_95.json", cache)
        except Exception as exc:
            raise NotInstalled(f"could not fetch from the mirror: {exc}") from exc

        # The graph has two heads: output 0 is the 95-language classifier
        # (verified shape (batch, 95)), output 1 is a 58-way language-GROUP
        # head exported with a frozen batch of 8. Only the first is read here.
        # The second makes onnxruntime warn once per clip that {8,58} does not
        # match {1,58}; it is an export artifact of a deprecated model, not a
        # problem with the result, so the log level is raised rather than
        # letting 19 identical warnings bury the table.
        options = onnxruntime.SessionOptions()
        options.log_severity_level = 3
        self.session = onnxruntime.InferenceSession(
            str(model_path), options, providers=["CPUExecutionProvider"])
        self.input_name = self.session.get_inputs()[0].name
        self.lang_dict = json.loads(dict_path.read_text())

    @staticmethod
    def _fetch(name: str, cache: Path) -> Path:
        import urllib.request
        cache.mkdir(parents=True, exist_ok=True)
        target = cache / name
        if not target.exists() or target.stat().st_size == 0:
            urllib.request.urlretrieve(f"{Silero.MIRROR}/{name}", target)
        return target

    def probs(self, audio, rate: int) -> dict[str, float]:
        import numpy as np

        batch = np.ascontiguousarray(audio, dtype="float32").reshape(1, -1)
        logits = self.session.run(None, {self.input_name: batch})[0][0]
        # The ONNX graph emits raw logits; softmax here rather than trusting
        # the export to have baked one in.
        shifted = np.exp(logits - np.max(logits))
        scores = shifted / shifted.sum()

        out: dict[str, float] = {}
        for index, prob in enumerate(scores.tolist()):
            # Labels look like "de, German" — the ISO code is the first field.
            label = str(self.lang_dict.get(str(index), ""))
            code = label.split(",")[0].strip().lower()
            if code in LANGS:
                out[code] = out.get(code, 0.0) + float(prob)
        return out


class Ecapa:
    """SpeechBrain ECAPA-TDNN on VoxLingua107 — ~85MB, Apache-2.0.

    Carries the only independently measured short-utterance number in the
    field: 6.54% error over 107 languages on 3,255 clips averaging 2.54s
    (arXiv:2303.16511). That is a 107-way number, so pair restriction should
    improve on it substantially — the pair-restricted column below is the test
    of whether it does.
    """

    name = "ecapa"

    def __init__(self):
        try:
            from speechbrain.inference.classifiers import EncoderClassifier
        except ImportError as exc:
            raise NotInstalled("pip install speechbrain torch torchaudio") from exc
        try:
            self.model = EncoderClassifier.from_hparams(
                source="speechbrain/lang-id-voxlingua107-ecapa",
                savedir=str(REPO / ".build" / "ecapa-voxlingua107"),
            )
        except Exception as exc:
            raise NotInstalled(f"could not load weights: {exc}") from exc
        import torch
        self.torch = torch

    def probs(self, audio, rate: int) -> dict[str, float]:
        import numpy as np
        tensor = self.torch.from_numpy(np.ascontiguousarray(audio)).unsqueeze(0)
        out_prob, _, _, _ = self.model.classify_batch(tensor)
        scores = self.torch.softmax(out_prob[0], dim=-1) if out_prob.dim() > 1 else out_prob
        labels = self.model.hparams.label_encoder.ind2lab
        result: dict[str, float] = {}
        for index, prob in enumerate(scores.tolist()):
            code = str(labels[index]).split(":")[0].strip().lower()[:2]
            if code in LANGS:
                result[code] = result.get(code, 0.0) + float(prob)
        return result


class Whisper:
    """Whisper tiny's language token, via faster-whisper — MIT.

    Included as the reference point rather than as a favourite. Two structural
    problems: the encoder pads to 30s, so a 2s clip is 93% silence and silence
    is a documented corruptor of Whisper's LID (whisper.cpp #1104, open since
    2023); and it is another large multilingual ASR model trained on scraped
    web audio, i.e. the same family as the model whose errors we are trying to
    get an independent read on. If it wins here anyway, that is worth knowing.
    """

    name = "whisper"

    def __init__(self, size: str = "tiny"):
        try:
            from faster_whisper import WhisperModel
        except ImportError as exc:
            raise NotInstalled("pip install faster-whisper") from exc
        try:
            self.model = WhisperModel(size, device="cpu", compute_type="int8")
        except Exception as exc:
            raise NotInstalled(f"could not load {size}: {exc}") from exc

    def probs(self, audio, rate: int) -> dict[str, float]:
        # `all_language_probs` is the whole point — the argmax alone cannot be
        # renormalised over a pair.
        _, info = self.model.transcribe(audio, language=None, beam_size=1)
        pairs = getattr(info, "all_language_probs", None)
        if not pairs:
            return {info.language: 1.0} if info.language in LANGS else {}
        return {code: float(prob) for code, prob in pairs if code in LANGS}


CANDIDATES = {"silero": Silero, "ecapa": Ecapa, "whisper": Whisper}


# --------------------------------------------------------------------------
# Scoring
# --------------------------------------------------------------------------

def restrict(probs: dict[str, float], pair: tuple[str, str]) -> str | None:
    """Renormalise over the configured pair and return the winner.

    This is the whole trick, and it is four lines. Every error of the form
    "true=de, predicted=some third language" becomes correct whenever
    P(de) > P(es). What survives is only genuine de-vs-es confusion.
    """
    home, partner = pair
    if home not in LANGS or partner not in LANGS or home == partner:
        return None
    ph, pp = probs.get(home, 0.0), probs.get(partner, 0.0)
    if ph == 0.0 and pp == 0.0:
        return None
    return home if ph >= pp else partner


def run(candidate, clips: list[dict], clip_seconds: float | None) -> dict:
    open_hits = pair_hits = pair_scored = out_of_pair = 0
    agree = disagree_right = disagree_wrong = 0
    confusion: dict[tuple[str, str], int] = defaultdict(int)
    per_pair: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    failures = 0

    for clip in clips:
        try:
            audio, rate = load_wav(clip["path"], clip_seconds)
            probs = candidate.probs(audio, rate)
        except Exception as exc:
            failures += 1
            print(f"    {clip['path'].name}: {exc}", file=sys.stderr)
            continue

        truth = clip["truth"]
        if probs:
            open_pick = max(probs, key=probs.get)
            open_hits += int(open_pick == truth)
            confusion[(truth, open_pick)] += 1

        # A clip whose language is not one of the configured two cannot be
        # scored on the pair-restricted question — the restriction forces an
        # answer from a set the right answer is not in, so it is wrong by
        # construction. Counting those as errors made the pair-restricted
        # column read WORSE than open-set on the mixed TestAudio corpus, which
        # is the opposite of what restriction does. Excluded and reported,
        # not silently dropped.
        if truth not in clip["pair"]:
            out_of_pair += 1
            continue

        pick = restrict(probs, clip["pair"])
        if pick is not None:
            pair_scored += 1
            correct = pick == truth
            pair_hits += int(correct)
            key = "/".join(sorted(clip["pair"]))
            per_pair[key][0] += int(correct)
            per_pair[key][1] += 1

            # The joint distribution against the app. This is the column that
            # says whether the candidate is an INDEPENDENT witness rather than
            # an accurate one, and it is the question #125 answered wrongly.
            decision = clip.get("decision")
            if decision in LANGS:
                if decision == pick:
                    agree += 1
                elif correct:
                    disagree_right += 1
                else:
                    disagree_wrong += 1

    return {
        "n": len(clips),
        "failures": failures,
        "open": (open_hits, len(clips) - failures),
        "pair": (pair_hits, pair_scored),
        "out_of_pair": out_of_pair,
        "agree": agree,
        "rescues": disagree_right,
        "breaks": disagree_wrong,
        "per_pair": dict(per_pair),
        "confusion": dict(confusion),
    }


def pct(hits: int, total: int) -> str:
    return f"{100.0 * hits / total:5.1f}%" if total else "    --"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Score language deciders against labelled audio (#135).")
    parser.add_argument("source", type=Path, nargs="?", default=REPO / "TestAudio",
                        help="directory of WAVs, or a capture dir with manifest.jsonl")
    parser.add_argument("--models", default=",".join(CANDIDATES),
                        help=f"comma-separated subset of {','.join(CANDIDATES)}")
    parser.add_argument("--pair", nargs=2, metavar=("HOME", "PARTNER"),
                        help="pair to restrict to, for corpora without a manifest")
    parser.add_argument("--clip", type=float, metavar="SECONDS",
                        help="truncate every clip, to measure the short-utterance case")
    parser.add_argument("--confusion", action="store_true",
                        help="print the open-set confusion pairs")
    args = parser.parse_args()

    if not args.source.is_dir():
        print(f"no such directory: {args.source}", file=sys.stderr)
        return 2

    pair = tuple(args.pair) if args.pair else None
    clips = labelled_clips(args.source, pair, args.clip)
    if not clips:
        print(f"no labelled clips in {args.source}. Bare WAVs must be named "
              f"<lang>_*.wav; captures need `truth` filled in in manifest.jsonl.",
              file=sys.stderr)
        return 1

    where = args.source.relative_to(REPO) if args.source.is_relative_to(REPO) else args.source
    clipped = f", truncated to {args.clip}s" if args.clip else ""
    print(f"\n{len(clips)} labelled clips from {where}{clipped}")
    if not pair and not (args.source / "manifest.jsonl").exists():
        print("  no pair given and no manifest — pair-restricted column needs --pair")
    print()

    header = f"{'candidate':<10} {'open-set':>9} {'pair-restricted':>16} {'agree':>7} {'rescues':>8} {'breaks':>7}"
    print(header)
    print("-" * len(header))

    results = {}
    for name in [m.strip() for m in args.models.split(",") if m.strip()]:
        factory = CANDIDATES.get(name)
        if factory is None:
            print(f"{name:<10} unknown candidate", file=sys.stderr)
            continue
        try:
            candidate = factory()
        except NotInstalled as exc:
            print(f"{name:<10} not installed — {exc}")
            continue
        result = run(candidate, clips, args.clip)
        results[name] = result
        print(f"{name:<10} {pct(*result['open']):>9} {pct(*result['pair']):>16} "
              f"{result['agree']:>7} {result['rescues']:>8} {result['breaks']:>7}")
        if result["out_of_pair"]:
            print(f"{'':<10} {result['out_of_pair']} clip(s) excluded from the "
                  f"pair-restricted column: their language is not in the configured pair.")

    if not results:
        print("\nNo candidate ran. Install at least one (see the header of this file).")
        return 1

    for name, result in results.items():
        if len(result["per_pair"]) > 1:
            print(f"\n{name} by pair:")
            for key, (hits, total) in sorted(result["per_pair"].items()):
                print(f"  {key:<10} {pct(hits, total)}  ({hits}/{total})")

    if args.confusion:
        for name, result in results.items():
            wrong = {k: v for k, v in result["confusion"].items() if k[0] != k[1]}
            if wrong:
                print(f"\n{name} open-set confusions:")
                for (truth, pick), count in sorted(wrong.items(), key=lambda kv: -kv[1]):
                    print(f"  {truth} heard as {pick}: {count}")

    print("\n`rescues` = candidate disagreed with the app AND was right; "
          "`breaks` = disagreed and was wrong.")
    print("Both are zero when the corpus has no app decisions (a TTS corpus "
          "has none). A candidate with high accuracy and zero rescues is not "
          "an independent witness — see #125.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
