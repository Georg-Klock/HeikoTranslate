import Foundation

// L2.6 probe (TESTING.md): when a Gemini Live session hits its bounded
// duration, does it end in a way the app can recover from — and does a
// FRESH session work immediately afterwards?
//
// Phase 1 holds a real session open (streaming silence at mic pace, like an
// idle open-mic app) until the server ends it, and asserts that the end
// surfaces as a `.closed` event. That is exactly the regression this probe
// guards: goAway used to be treated as an INTENTIONAL close, so `.closed`
// never fired and the app never reconnected (SPEC R7).
//
// Phase 2 then connects a brand-new session — what the app's reconnect
// does — and replays TestAudio/en_short.wav through it, asserting that
// transcription and translation still arrive.
//
// Run from the repo root: Tools/l2expiry.sh   (expect ~10–20 minutes)

setbuf(stdout, nil) // progress must stream even when piped to a log file

let apiKey = loadAPIKey()
let started = Date()
func stamp() -> String { String(format: "%7.1fs", Date().timeIntervalSince(started)) }

final class Box {
    private let q = DispatchQueue(label: "l2expiry")
    private var _sawGoAway = false
    private var _sawClosed = false
    private var _error: String?
    var sawGoAway: Bool { q.sync { _sawGoAway } }
    var sawClosed: Bool { q.sync { _sawClosed } }
    var error: String? { q.sync { _error } }
    func markGoAway() { q.sync { _sawGoAway = true } }
    func markClosed() { q.sync { _sawClosed = true } }
    func markError(_ m: String) { q.sync { if _error == nil { _error = m } } }
}

// MARK: - Phase 1: hold a session until the server ends it

print("[\(stamp())] Phase 1: holding a 'de' session open until the server ends it (cap 25 min)")
let box = Box()
let phase1Done = DispatchSemaphore(value: 0)

let session = GeminiLiveSession(targetLanguageCode: "de", apiKey: apiKey) { event in
    switch event {
    case .setupComplete:
        print("[\(stamp())] setupComplete — session live, streaming silence")
    case .debug(let message):
        if message.contains("goAway") {
            box.markGoAway()
            print("[\(stamp())] goAway received from server")
        }
    case .closed:
        if !box.sawClosed {
            box.markClosed()
            print("[\(stamp())] .closed emitted — the orchestrator would reconnect here")
            phase1Done.signal()
        }
    case .error(let message):
        box.markError(message)
        print("[\(stamp())] ERROR: \(message)")
        phase1Done.signal()
    default:
        break
    }
}
session.connect()

let silenceChunk = Data(count: 2048) // 64ms of 16kHz 16-bit mono
let streamer = Thread {
    while !box.sawClosed && box.error == nil {
        session.sendAudio(silenceChunk)
        Thread.sleep(forTimeInterval: 0.064)
    }
}
streamer.start()

if phase1Done.wait(timeout: .now() + 25 * 60) != .success {
    print("[\(stamp())] FAIL: session neither closed nor errored within 25 min — cannot verify expiry behavior")
    exit(1)
}
guard box.sawClosed, box.error == nil else {
    print("[\(stamp())] FAIL: session ended with an error instead of a clean .closed — reconnect would not fire")
    exit(1)
}
print("[\(stamp())] Phase 1 PASS (goAway seen: \(box.sawGoAway))")

// MARK: - Phase 2: a fresh session right after expiry must work

print("[\(stamp())] Phase 2: fresh session + en_short.wav replay")
let ready = DispatchSemaphore(value: 0)
let box2 = Box()
final class Transcripts {
    private let q = DispatchQueue(label: "l2expiry.p2")
    private var _input = "", _output = ""
    var input: String { q.sync { _input } }
    var output: String { q.sync { _output } }
    func addInput(_ t: String) { q.sync { _input += t } }
    func addOutput(_ t: String) { q.sync { _output += t } }
}
let got = Transcripts()

let fresh = GeminiLiveSession(targetLanguageCode: "de", apiKey: apiKey) { event in
    switch event {
    case .setupComplete:
        ready.signal()
    case .inputTranscript(let text):
        got.addInput(text)
    case .outputTranscript(let text):
        got.addOutput(text)
    case .error(let message):
        box2.markError(message)
        print("[\(stamp())] Phase 2 ERROR: \(message)")
    default:
        break
    }
}
fresh.connect()
guard ready.wait(timeout: .now() + 20) == .success else {
    print("[\(stamp())] FAIL: fresh session did not reach setupComplete within 20s")
    exit(1)
}
print("[\(stamp())] fresh session live — replaying en_short.wav")

let pcm = loadWAV("TestAudio/en_short.wav")
var offset = 0
while offset < pcm.count {
    let end = min(offset + 2048, pcm.count)
    fresh.sendAudio(pcm.subdata(in: offset..<end))
    offset = end
    Thread.sleep(forTimeInterval: 0.064)
}
// Trailing silence so VAD closes the utterance, while we poll for results.
let deadline = Date().addingTimeInterval(30)
while Date() < deadline {
    fresh.sendAudio(silenceChunk)
    Thread.sleep(forTimeInterval: 0.064)
    if !got.input.isEmpty && !got.output.isEmpty { break }
}
fresh.close()

let pass = !got.input.isEmpty && !got.output.isEmpty && box2.error == nil
print("[\(stamp())] heard:      \(got.input.trimmingCharacters(in: .whitespacesAndNewlines))")
print("[\(stamp())] translated: \(got.output.trimmingCharacters(in: .whitespacesAndNewlines))")
print("[\(stamp())] L2.6 \(pass ? "PASS" : "FAIL"): session end surfaced as .closed and a fresh session translates immediately after")
exit(pass ? 0 : 1)
