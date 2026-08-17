#!/usr/bin/env python3
"""Fill in the `truth` field for captured turns, one clip at a time (#135).

    Tools/lid-label.py <pulled-log-dir>/turn-audio

Plays each unlabelled clip and asks which language was actually spoken. Writes
the answer back into `manifest.jsonl`, which is what `Tools/lid-bench.py` reads.

WHY THIS IS A SEPARATE STEP FROM THE CAPTURE

The app records its own verdict as `decision`, and that verdict is the thing
under test. If the capture wrote it into `truth` as well, every candidate would
be scored against the app's answer rather than against what was said, and a
model that agreed with the app perfectly would look perfect — including on the
turns the app got wrong, which are the only ones that matter. So `truth` starts
null and a human puts it there. This tool just makes that fast.

It deliberately does NOT show you the app's decision before you answer. Knowing
what the app said while labelling is how a corpus quietly acquires the app's
own bias; the decision is right there in the manifest afterwards if you want to
compare. Pass --show-decision if you are auditing rather than labelling.

Keys: the language code (de/en/es/fr/ko/zh/tl/vi), `r` to replay, `s` to skip,
`x` for unusable (silence, both speakers at once, the app's own output leaking
back), `q` to save and quit. Skipped and unusable clips stay out of the bench
rather than being guessed at.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

LANGS = ["de", "en", "es", "fr", "ko", "zh", "tl", "vi"]


def play(path: Path) -> None:
    """macOS `afplay`. Failure is not fatal — a clip can still be labelled from
    the transcript in the diagnostic log if audio output is unavailable."""
    try:
        subprocess.run(["afplay", str(path)], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        print("  (afplay not found — cannot play audio)", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Label captured turns for the LID bench.")
    parser.add_argument("directory", type=Path, help="a pulled turn-audio directory")
    parser.add_argument("--show-decision", action="store_true",
                        help="show the app's verdict while labelling (auditing only — it biases the labeller)")
    parser.add_argument("--relabel", action="store_true",
                        help="revisit clips that already have a truth value")
    args = parser.parse_args()

    manifest = args.directory / "manifest.jsonl"
    if not manifest.exists():
        print(f"no manifest.jsonl in {args.directory}", file=sys.stderr)
        return 2

    rows = []
    for line in manifest.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            print(f"skipping malformed row: {line[:60]}", file=sys.stderr)

    todo = [r for r in rows if args.relabel or not r.get("truth")]
    if not todo:
        print(f"all {len(rows)} clips already labelled — run Tools/lid-bench.py {args.directory}")
        return 0

    print(f"\n{len(todo)} of {len(rows)} clips to label. "
          f"Keys: {'/'.join(LANGS)} · r replay · s skip · x unusable · q save and quit\n")

    changed = 0
    for index, row in enumerate(todo, start=1):
        path = args.directory / row.get("file", "")
        if not path.exists():
            print(f"[{index}/{len(todo)}] {row.get('file')} — file missing, skipping")
            continue

        pair = f"{row.get('home','?')}/{row.get('partner','?')}"
        seconds = row.get("seconds", "?")
        suffix = f"  app said: {row.get('decision')}" if args.show_decision else ""
        print(f"[{index}/{len(todo)}] {path.name}  pair {pair}  {seconds}s{suffix}")

        play(path)
        while True:
            try:
                answer = input("  spoken language? ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                print()
                answer = "q"

            if answer == "r":
                play(path)
                continue
            if answer == "s":
                break
            if answer == "q":
                write(manifest, rows)
                print(f"\nSaved. {changed} labelled this session.")
                return 0
            if answer == "x":
                row["truth"] = None
                row["unusable"] = True
                changed += 1
                break
            if answer in LANGS:
                row["truth"] = answer
                row.pop("unusable", None)
                changed += 1
                break
            print(f"  not a language code — use one of {', '.join(LANGS)}, or r/s/x/q")

    write(manifest, rows)
    labelled = sum(1 for r in rows if r.get("truth"))
    print(f"\nSaved. {labelled} of {len(rows)} clips now labelled.")
    print(f"Next: Tools/.venv/bin/python Tools/lid-bench.py {args.directory}")
    return 0


def write(manifest: Path, rows: list[dict]) -> None:
    """Rewrite atomically. The manifest is the only record of which audio is
    which; a half-written one after a Ctrl-C would lose the labelling work and
    leave clips that cannot be matched to anything."""
    temporary = manifest.with_suffix(".jsonl.tmp")
    temporary.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    temporary.replace(manifest)


if __name__ == "__main__":
    sys.exit(main())
