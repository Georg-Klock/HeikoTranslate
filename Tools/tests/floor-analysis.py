#!/usr/bin/env python3
"""Pins floor_measurement.analyze — the pure half of #29's calibration —
against canned records, so the analysis cannot drift while the live
campaign waits on API weather. No network; runs with the other L0 scripts."""
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "floor_measurement", os.path.join(here, "..", "floor_measurement.py"))
fm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fm)

failures = 0


def case(name, ok, detail=""):
    global failures
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"  ({detail})"))
    if not ok:
        failures += 1


def rec(home, sample, out_chars, in_chars=20, failed=False):
    r = {"home": home, "sample": sample, "input_chars": in_chars}
    if failed:
        r["failed"] = True
    else:
        r["output_chars"] = out_chars
    return r


# A German-like home: short answers 2-13 chars, controls near ratio 1.
de = [rec("de", "yes", 3), rec("de", "no", 5), rec("de", "thanks", 6),
      rec("de", "good", 8), rec("de", "time", 13),
      rec("de", "price", 19), rec("de", "overthere", 24), rec("de", "station", 19),
      rec("de", "control1", 42, in_chars=41), rec("de", "control2", 55, in_chars=59)]
a = fm.analyze(de)["homes"]["de"]
case("German-like: corroborated floor capped at today's 5",
     a["suggested_corroborated_floor"] == 3 or a["suggested_corroborated_floor"] <= 5,
     str(a))
case("German-like: decisive floor keeps the 8:5 shape above the corroborated",
     a["suggested_decisive_floor"] > a["suggested_corroborated_floor"], str(a))
case("German-like: ratio floor is 0.67 of the observed minimum",
     abs(a["suggested_ratio_floor"] - round(min(42 / 41, 55 / 59) * 0.67, 2)) < 0.001,
     str(a))

# A CJK-like home: the same MEANINGS in 1-6 characters — the whole point
# of #29 is that today's shared 5/8 floors would reject most of these.
zh = [rec("zh", "yes", 1), rec("zh", "no", 2), rec("zh", "thanks", 2),
      rec("zh", "good", 2), rec("zh", "time", 4),
      rec("zh", "price", 6), rec("zh", "overthere", 7), rec("zh", "station", 5),
      rec("zh", "control1", 12, in_chars=41), rec("zh", "control2", 16, in_chars=59)]
z = fm.analyze(zh)["homes"]["zh"]
case("CJK-like: corroborated floor drops to the observed minimum",
     z["suggested_corroborated_floor"] == 1, str(z))
case("CJK-like: ratio floor sits far below the Latin 0.4",
     z["suggested_ratio_floor"] < 0.4, str(z))
case("CJK-like: floors never go BELOW one observed short answer",
     z["suggested_corroborated_floor"] >= 1, str(z))

# Failures are excluded, never counted as zero-length translations.
mixed = de + [rec("de", "yes", 0, failed=True)]
case("a failed probe changes nothing",
     fm.analyze(mixed)["homes"]["de"] == a, "failure leaked into the stats")

# A home with too few samples reports itself instead of guessing.
thin = [rec("ko", "yes", 2)]
case("insufficient data says so",
     fm.analyze(thin)["homes"]["ko"].get("insufficient") is True,
     str(fm.analyze(thin)["homes"]["ko"]))

if failures:
    print(f"==> floor-analysis: {failures} failure(s)")
    sys.exit(1)
print("==> floor-analysis: all cases pass")
