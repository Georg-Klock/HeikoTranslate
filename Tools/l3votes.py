#!/usr/bin/env python3
"""Per-session vote mining over saved L3 verbose logs (#83).

For every run log in the given directories, tallies which language each
SESSION voted for, per turn — the evidence `TurnLogic.partnerHeardHome`
is built on. This script produced the measurement in that doc comment:
across 70 scored turns, every mis-hearing round-trip turn (8/8) shows the
crossed pattern (home session votes partner, partner session votes home)
and no genuinely-foreign turn (0/50) has the partner session reading home.

    python3 Tools/l3votes.py .build/day2-baseline-es .build/day2-after-es

Needs logs produced by `L3_VERBOSE=1 Tools/l3replay.sh` (l3direction.sh
saves them per run).
"""
import re
import sys
import glob
from collections import Counter


def mine(logdir: str) -> None:
    for f in sorted(glob.glob(f"{logdir}/run*.log"),
                    key=lambda p: int(re.search(r"run(\d+)", p).group(1))):
        text = open(f).read()
        turn_end = re.search(r"--- turn ended @([\d.]+)s", text)
        codes_lines = re.findall(r"\(verbose\) codes so far: (.*)", text)
        if not turn_end or not codes_lines:
            print(f"{f}: no verbose turn data — was L3_VERBOSE set?")
            continue
        t1end = float(turn_end.group(1))
        votes = re.findall(r"(\w+):(\w+)@([\d.]+)s", codes_lines[-1])
        per_turn: dict[str, dict[str, Counter]] = {"turn1": {}, "turn2": {}}
        for sess, code, ts in votes:
            turn = "turn1" if float(ts) <= t1end else "turn2"
            per_turn[turn].setdefault(sess, Counter())[code] += 1
        b2 = re.search(r"bubble 2: (\w+)", text)
        run = f.split("/")[-1].removesuffix(".log")
        print(f"{logdir}/{run}: bubble2={b2.group(1) if b2 else 'none':5s} "
              f"t1={fmt(per_turn['turn1'])}  t2={fmt(per_turn['turn2'])}")


def fmt(tallies: dict[str, Counter]) -> str:
    return " ".join(f"{s}-sess{dict(c.most_common())}"
                    for s, c in sorted(tallies.items()))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for d in sys.argv[1:]:
        mine(d)
