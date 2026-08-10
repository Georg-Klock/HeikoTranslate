#!/usr/bin/env python3
"""GitHub #20: the L2 probe must exit nonzero when the live API misbehaved.

Holds `livetest.validation_error` — the pure pass/fail predicate — against
fake results, one broken field at a time. No network, no websockets install
(the import lives inside `run()`), finishes instantly. Run alongside the
other L0 scripts after touching Tools/livetest.py.
"""
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "livetest", os.path.join(here, "..", "livetest.py"))
livetest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(livetest)


def good() -> dict:
    """What a healthy probe run collects."""
    return {
        "setup_complete": True,
        "input_transcript": "Hallo, wie geht es dir?",
        "output_transcript": "Hello, how are you?",
        "input_langs": ["de"],
        "output_langs": ["en"],
        "audio_bytes": 40960,
        "messages": 63,
        "errors": [],
        "closed": None,
    }


failures = 0


def case(name: str, mutate, expect_substring):
    """expect_substring None means the result must PASS validation."""
    global failures
    result = good()
    mutate(result)
    verdict = livetest.validation_error(result)
    if expect_substring is None:
        ok = verdict is None
        detail = f"expected pass, got: {verdict!r}"
    else:
        ok = verdict is not None and expect_substring in verdict
        detail = f"expected failure mentioning {expect_substring!r}, got: {verdict!r}"
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"  ({detail})"))
    if not ok:
        failures += 1


case("a complete healthy result passes", lambda r: None, None)
case("a server error fails", lambda r: r["errors"].append({"code": 400}), "server errors")
case("missing setup acknowledgement fails", lambda r: r.update(setup_complete=False), "setupComplete")
case("empty input transcript fails", lambda r: r.update(input_transcript="  "), "input transcript")
case("empty output transcript fails", lambda r: r.update(output_transcript=""), "nothing was translated")
case("zero returned audio fails", lambda r: r.update(audio_bytes=0), "no translated audio")
case("an error outranks otherwise-good content",
     lambda r: r["errors"].append("late"), "server errors")

if failures:
    print(f"==> livetest-validation: {failures} failure(s)")
    sys.exit(1)
print("==> livetest-validation: all cases pass")
