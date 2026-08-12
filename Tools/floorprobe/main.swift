import Foundation

// The #29 measurement's live driver, on the WIRE PATH THE APP SHIPS: one
// WAV, one target language, one session, and the accumulated output
// transcript printed on a marker line for Tools/floor_measurement.py to
// parse. This exists because the Python probe went silent while
// GeminiLiveSession kept working (#76) — a calibration must ride the
// client whose behaviour it calibrates anyway.
//
//   Tools/floorprobe.sh <wav> <target-code>
//
// Prints exactly one of:
//   FLOORPROBE-OUT: <transcript>     (success; may be short — that is the point)
//   FLOORPROBE-ERR: <reason>         (and exits 1)

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else {
    fputs("usage: floorprobe <wav-path> <target-code>\n", stderr)
    exit(2)
}
let apiKey = loadAPIKey()
let pcm = loadWAV(args[0])
let code = args[1]

var output = ""
var errorText: String?
var ready = false
var lastEventAt = Date()
let q = DispatchQueue(label: "floorprobe")
let sem = DispatchSemaphore(value: 0)

let session = GeminiLiveSession(targetLanguageCode: code, apiKey: apiKey) { event in
    q.async {
        lastEventAt = Date()
        switch event {
        case .setupComplete: ready = true; sem.signal()
        case .outputTranscript(let t): output += t
        case .error(let m): errorText = m; sem.signal()
        default: break
        }
    }
}
session.connect()
guard sem.wait(timeout: .now() + 15) == .success, q.sync(execute: { ready }) else {
    print("FLOORPROBE-ERR: \(q.sync { errorText } ?? "no setupComplete in 15s")")
    session.close()
    exit(1)
}

// Real-time pacing, like the mic tap: 2048 bytes = 64ms at 16kHz PCM16.
var offset = 0
while offset < pcm.count {
    let end = min(offset + 2048, pcm.count)
    session.sendAudio(pcm.subdata(in: offset..<end))
    offset = end
    Thread.sleep(forTimeInterval: 0.064)
}

// Silence until the transcript goes quiet (or a hard deadline): short
// answers arrive fast, but the tail must not clip a longer control sample.
let silence = Data(count: 2048)
let hardDeadline = Date().addingTimeInterval(25)
var lastOutputCount = 0
var quietSince = Date()
while Date() < hardDeadline {
    session.sendAudio(silence)
    Thread.sleep(forTimeInterval: 0.064)
    if let e = q.sync(execute: { errorText }) {
        print("FLOORPROBE-ERR: \(e)")
        session.close()
        exit(1)
    }
    let count = q.sync { output.count }
    if count != lastOutputCount {
        lastOutputCount = count
        quietSince = Date()
    } else if count > 0, Date().timeIntervalSince(quietSince) > 2.5 {
        break   // the translation arrived and has been stable
    }
}
session.close()

let text = q.sync { output }.trimmingCharacters(in: .whitespacesAndNewlines)
guard !text.isEmpty else {
    print("FLOORPROBE-ERR: no output transcript before the deadline")
    exit(1)
}
print("FLOORPROBE-OUT: \(text)")
