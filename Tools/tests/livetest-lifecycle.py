#!/usr/bin/env python3
"""Executable proof of the #65 lifecycle changes, against a LOCAL WebSocket
server — no API key, no network beyond loopback, CI-safe. The #67 review
was right that mutating fake results proves the validator, not the probe:
these drive livetest.run() itself through the three behaviours the change
claims — deadline expiry with clean task teardown, prompt goAway closure,
and a close landing mid-send.

Requires the same `websockets` dependency livetest itself documents.
"""
import asyncio
import importlib.util
import json
import os
import sys

import websockets

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "livetest", os.path.join(here, "..", "livetest.py"))
lt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lt)
lt.load_api_key = lambda: "local-test-key"

failures = 0


def case(name, ok, detail=""):
    global failures
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"  ({detail})"))
    if not ok:
        failures += 1


PCM = b"\x00\x01" * 16000  # 2s of tone-ish 16kHz PCM16


async def serve(behavior):
    """Start a one-connection server running `behavior(ws)`; returns (server, port, state)."""
    state = {"closed_clean": None, "got_audio": 0}

    async def handler(ws):
        try:
            await behavior(ws, state)
        except websockets.ConnectionClosed:
            pass
        state["closed_clean"] = ws.close_code in (1000, 1001, None)

    server = await websockets.serve(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    return server, port


async def run_against(port, timeout, tail=1.0, realtime=False):
    lt.ENDPOINT = f"ws://127.0.0.1:{port}"
    res: dict = {}
    timed_out = False
    try:
        await asyncio.wait_for(
            lt.run(PCM, "de", realtime=realtime, quiet_tail=tail, result=res),
            timeout=timeout)
    except (asyncio.TimeoutError, TimeoutError):
        timed_out = True
        res["deadline_exceeded"] = True
    return res, timed_out


async def main():
    # 1. Runaway stream: the server never goes quiet, so only the deadline
    #    can end the run — and it must cancel the reader and release the
    #    socket rather than leaving work behind.
    async def runaway(ws, state):
        async for raw in ws:
            msg = json.loads(raw)
            if "setup" in msg:
                await ws.send(json.dumps({"setupComplete": {}}))
                break
        while True:
            await ws.send(json.dumps({"serverContent": {"outputTranscription": {"text": "x"}}}))
            await asyncio.sleep(0.05)

    baseline = len(asyncio.all_tasks())
    server, port = await serve(runaway)
    res, timed_out = await run_against(port, timeout=2.0, tail=10.0)
    await asyncio.sleep(0.3)   # let cancellation land
    case("runaway: only the deadline ends the run", timed_out)
    case("runaway: the named verdict fires",
         "deadline exceeded" in (lt.validation_error(res) or ""), str(lt.validation_error(res)))
    case("runaway: no reader task survives the timeout",
         len(asyncio.all_tasks()) <= baseline, f"{len(asyncio.all_tasks())} tasks")
    server.close(); await server.wait_closed()

    # 2. goAway during the tail: the probe closes promptly and cleanly — the
    #    filed run lingered into the server's 1008 instead.
    async def goaway_tail(ws, state):
        async for raw in ws:
            msg = json.loads(raw)
            if "setup" in msg:
                await ws.send(json.dumps({"setupComplete": {}}))
            if isinstance(msg.get("realtimeInput"), dict) and msg["realtimeInput"].get("audioStreamEnd"):
                await ws.send(json.dumps({"goAway": {}}))

    server, port = await serve(goaway_tail)
    res, timed_out = await run_against(port, timeout=10.0)
    case("goAway/tail: run returns without the deadline", not timed_out)
    case("goAway/tail: recorded as goAway", res.get("closed") == "goAway", str(res.get("closed")))
    case("goAway/tail: no 1008 — our side closed cleanly",
         not any("1008" in str(e) for e in res.get("errors", [])), str(res.get("errors")))
    server.close(); await server.wait_closed()

    # 3. goAway mid-send: our prompt close lands while audio is still being
    #    sent; the guard records it instead of crashing out.
    async def goaway_early(ws, state):
        async for raw in ws:
            msg = json.loads(raw)
            if "setup" in msg:
                await ws.send(json.dumps({"setupComplete": {}}))
                await ws.send(json.dumps({"goAway": {}}))
                break
        # keep the connection open until the client closes it
        try:
            async for _ in ws:
                pass
        except websockets.ConnectionClosed:
            pass

    server, port = await serve(goaway_early)
    res, timed_out = await run_against(port, timeout=15.0, realtime=True)
    case("goAway/mid-send: run returns", not timed_out)
    case("goAway/mid-send: the close is recorded, not thrown",
         res.get("closed") == "goAway"
         and (not res.get("errors") or any("closed while sending" in str(e) for e in res["errors"])),
         f"closed={res.get('closed')} errors={res.get('errors')}")
    server.close(); await server.wait_closed()


asyncio.run(main())
if failures:
    print(f"==> livetest-lifecycle: {failures} failure(s)")
    sys.exit(1)
print("==> livetest-lifecycle: all cases pass")
