#!/usr/bin/env python3
"""Measure what a SHORT real translation looks like in each home language.

GitHub #29: TurnLogic's output-substance floors are character counts
calibrated on German (`minDecisiveHomeOutput = 8`, the corroborated floor 5,
`homeOutputRatioFloor = 0.4`) — but eight characters of German is one short
word while eight of Chinese is a substantial clause, and a genuine zh
translation of an en sentence can sit far below 0.4 on length alone. The
issue requires replacement values DERIVED FROM MEASUREMENT, the way the
originals were. This is that measurement, in two separable halves:

- `analyze(records)` is PURE: given (home, sample_id, output_chars,
  input_chars) records it produces the per-language table and the suggested
  floors. Pinned offline by Tools/tests/floor-analysis.py, so the analysis
  cannot drift while waiting on API weather.
- The driver (`__main__`) is the live half: it runs Tools/livetest.py once
  per (home language, sample) and records what came back. It refuses to
  emit floors from a run with failures — a degraded API must not calibrate
  anything (#65's empty-result shape would read as "floor 0").

Samples are INVENTED utterances (the repo's privacy rule), spoken by the
PARTNER side so the output is a translation INTO the home language — the
exact text the floors judge. The set brackets the German calibration
points on purpose: bare yes/no answers, a number with a unit, a short
directive, and two mid-length controls for the ratio.

Usage (talks to the live API; ~80 probes, a few cents):
    python3 Tools/floor_measurement.py --out measurements.json
    python3 Tools/floor_measurement.py --analyze measurements.json
"""
import argparse
import json
import re
import subprocess
import sys
import os

HOMES = ["de", "en", "es", "fr", "ko", "zh"]

# What the partner says; the probe translates INTO each home language.
# For the "en" home the partner speaks German (the app's real pairing);
# every other home hears English. IDs are stable so runs can be compared.
SAMPLES = [
    ("yes",        "Yes.",                             "Ja."),
    ("no",         "No.",                              "Nein."),
    ("thanks",     "Thank you.",                       "Danke."),
    ("good",       "Very good.",                       "Sehr gut."),
    ("price",      "That costs 14 euros.",             "Das kostet 14 Euro."),
    ("overthere",  "It's over there, on the left.",    "Es ist da drüben, links."),
    ("time",       "At half past three.",              "Um halb vier."),
    ("station",    "Where is the train station?",      "Wo ist der Bahnhof?"),
    ("control1",   "Two blocks down, then left at the lights.",
                   "Zwei Blocks weiter, dann links an der Ampel."),
    ("control2",   "The next train leaves in twenty minutes from platform two.",
                   "Der nächste Zug fährt in zwanzig Minuten von Gleis zwei."),
]

SPOKE_LINE = re.compile(r"^spoke\s+\([^)]*\):\s?(.*)$")


def run_probe(livetest: str, text: str, target: str) -> dict | None:
    """One live probe. Returns a record, or None when the probe failed —
    the caller counts failures; it never fabricates a length from one."""
    proc = subprocess.run(
        [sys.executable, "-u", livetest, "--text", text, "--target", target,
         "--tail", "5"],
        capture_output=True, text=True, timeout=300)
    out = proc.stdout + proc.stderr
    if "L2 OK" not in out:
        return None
    spoke = ""
    for line in out.splitlines():
        m = SPOKE_LINE.match(line.strip())
        if m:
            spoke = m.group(1).strip()
    if not spoke:
        return None
    return {"output_chars": len(spoke), "output_text": spoke}


def analyze(records: list) -> dict:
    """The pure half: records -> per-language stats and suggested floors.

    Suggested floors keep the German DOCTRINE and re-derive only the
    numbers: the corroborated floor sits between the largest observed
    false-start-like fragment and the smallest genuine short answer —
    which for German was between "Ich" (3) and "14 Euro"/"Ja" territory.
    With no false-start corpus per language, the conservative derivation
    is: corroborated floor = min(observed short-answer length), capped at
    the German value so no language gets STRICTER than today; decisive
    floor keeps the same ratio to it that German's 8:5 has. The ratio
    floor is derived from the observed min(output/input) across the
    controls, with the same 0.67 safety factor 0.4 had against German's
    measured ~0.6 minimum.
    """
    by_home: dict = {}
    for r in records:
        if r.get("failed"):
            continue
        by_home.setdefault(r["home"], []).append(r)
    out = {"homes": {}, "total_records": len(records)}
    for home, rs in sorted(by_home.items()):
        short = [r["output_chars"] for r in rs if r["sample"] in
                 ("yes", "no", "thanks", "good", "time")]
        answers = [r["output_chars"] for r in rs if r["sample"] in
                   ("price", "overthere", "station")]
        ratios = [r["output_chars"] / r["input_chars"] for r in rs
                  if r["sample"] in ("control1", "control2") and r.get("input_chars")]
        if not short or not answers:
            out["homes"][home] = {"insufficient": True, "n": len(rs)}
            continue
        corroborated = min(min(short), 5)
        decisive = max(corroborated + 1, round(corroborated * 8 / 5))
        entry = {
            "n": len(rs),
            "short_min": min(short), "short_max": max(short),
            "answer_min": min(answers), "answer_max": max(answers),
            "suggested_corroborated_floor": corroborated,
            "suggested_decisive_floor": decisive,
        }
        if ratios:
            entry["ratio_min"] = round(min(ratios), 2)
            entry["suggested_ratio_floor"] = round(min(ratios) * 0.67, 2)
        out["homes"][home] = entry
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="run the live campaign, write records here")
    ap.add_argument("--analyze", help="analyze an existing records file")
    args = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    if args.analyze:
        records = json.load(open(args.analyze))
        print(json.dumps(analyze(records), indent=2, ensure_ascii=False))
        return 0
    if not args.out:
        ap.error("need --out (live campaign) or --analyze <records.json>")
    livetest = os.path.join(here, "livetest.py")
    records, failures = [], 0
    for home in HOMES:
        for sample_id, en_text, de_text in SAMPLES:
            text = de_text if home == "en" else en_text
            rec = {"home": home, "sample": sample_id,
                   "input_chars": len(text)}
            probe = run_probe(livetest, text, home)
            if probe is None:
                failures += 1
                rec["failed"] = True
            else:
                rec.update(probe)
            records.append(rec)
            print(f"{home}/{sample_id}: "
                  f"{'FAILED' if probe is None else probe['output_chars']}",
                  flush=True)
    json.dump(records, open(args.out, "w"), indent=1, ensure_ascii=False)
    if failures:
        print(f"\n{failures} of {len(records)} probes FAILED — a degraded "
              f"API must not calibrate anything; re-run before deriving "
              f"floors (#29, #65).", file=sys.stderr)
        return 1
    print(json.dumps(analyze(records), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
