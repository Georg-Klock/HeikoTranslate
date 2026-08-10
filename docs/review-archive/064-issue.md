# issue #64 — Make the L2 protocol probe exit nonzero for server errors or empty results

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:41:02Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/64

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `Tools/livetest.py:70-169`
- `Tools/livetest.py:197-216`
- `TESTING.md:11-14, 233-247`

## What's wrong

`livetest.py` collects server errors, closed state, transcripts, returned audio size, and message count, but `main()` only prints those values. It has no validation branch or nonzero exit after `asyncio.run`. A script or person invoking L2 can receive an API error, no setup/content, no transcription, and no output audio while still receiving exit status 0.

## Why it matters — moderate

The documented L2 protocol check can report a false green result. That undermines a safety step intended to prove that the live API still accepts setup, processes microphone audio, and returns usable translation output.

## Suggested fix

Track setup acknowledgement explicitly and validate the returned result before exiting. Extract the predicate into a pure function so it can be unit-tested:

```python
def validation_error(result):
    if result["errors"]:
        return f"server errors: {result['errors']}"
    if not result["setup_complete"]:
        return "no setupComplete"
    if not result["input_transcript"]:
        return "empty input transcript"
    if not result["output_transcript"] or result["audio_bytes"] == 0:
        return "no translated output"
    return None

problem = validation_error(res)
if problem:
    print(f"L2 FAILED: {problem}", file=sys.stderr)
    raise SystemExit(1)
```

Match the exact success criteria to the intended probe mode, but do not let collected errors or an empty result return success.

## Acceptance checks

- A fake result with a server error exits nonzero.
- Missing setup acknowledgement, empty transcript, and zero returned audio each exit nonzero.
- A complete fake success result exits zero.
- The normal output still prints useful transcripts and diagnostics.
