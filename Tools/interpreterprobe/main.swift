import Foundation

// Latency and correctness for BOTH session modes, on the wire path the app
// ships (GitHub #135).
//
//   Tools/interpreterprobe.sh translate   fr  TestAudio/de_short.wav
//   Tools/interpreterprobe.sh interpreter de fr TestAudio/de_short.wav
//
// Why this and not the Python probe: Tools/onesession-probe.py measured the
// general model at 0.72-1.22s to first token and 9/9 correct targets, but it
// could not measure the SHIPPING model at all — the translate-preview model
// returns setupComplete and then nothing to that client (#76), while the same
// clip through GeminiLiveSession answers correctly. So the one number that
// decides this — is the general model slower than what ships? — cannot come
// from there. It has to be measured on the same client, with the same clock,
// against the same clips.
//
// Prints one marker line:
//   PROBE: mode=<m> first=<s> full=<s> out="<transcript>"
//   PROBE-ERR: <reason>

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    fputs("""
        usage: interpreterprobe translate   <target>        <wav>
               interpreterprobe interpreter <home> <partner> <wav>

        """, stderr)
    exit(2)
}

let mode: GeminiLiveSession.Mode
let wavPath: String
switch args[0] {
case "translate":
    guard args.count == 3 else { fputs("translate takes <target> <wav>\n", stderr); exit(2) }
    mode = .translate(target: args[1])
    wavPath = args[2]
case "interpreter":
    guard args.count == 4 else { fputs("interpreter takes <home> <partner> <wav>\n", stderr); exit(2) }
    // INTERPRETER_MODEL overrides the default, so the general Live models can
    // be compared against each other without a rebuild of intent.
    let chosen = ProcessInfo.processInfo.environment["INTERPRETER_MODEL"]
        ?? GeminiLiveSession.Mode.defaultInterpreterModel
    mode = .interpreter(home: args[1], partner: args[2], model: chosen)
    wavPath = args[3]
default:
    fputs("first argument must be `translate` or `interpreter`\n", stderr)
    exit(2)
}

let apiKey = loadAPIKey()
let pcm = loadWAV(wavPath)

var output = ""
var errorText: String?
var ready = false
// The clock starts when the last real audio byte is sent, NOT when the clip
// starts — "how long after the speaker stops" is the number a user feels, and
// the only one comparable across clips of different lengths.
var audioEndedAt: Date?
var firstTokenAt: Date?
var lastTokenAt: Date?

let q = DispatchQueue(label: "interpreterprobe")
let sem = DispatchSemaphore(value: 0)

let session = GeminiLiveSession(mode: mode, apiKey: apiKey) { event in
    q.async {
        switch event {
        case .setupComplete:
            ready = true
            sem.signal()
        case .outputTranscript(let text):
            if firstTokenAt == nil { firstTokenAt = Date() }
            lastTokenAt = Date()
            output += text
        case .error(let message):
            errorText = message
            sem.signal()
        default:
            break
        }
    }
}
session.connect()
guard sem.wait(timeout: .now() + 20) == .success, q.sync(execute: { ready }) else {
    print("PROBE-ERR: \(q.sync { errorText } ?? "no setupComplete in 20s")")
    session.close()
    exit(1)
}

// Real-time pacing, exactly as the mic tap delivers: 2048 bytes = 64ms.
var offset = 0
while offset < pcm.count {
    let end = min(offset + 2048, pcm.count)
    session.sendAudio(pcm.subdata(in: offset..<end))
    offset = end
    Thread.sleep(forTimeInterval: 0.064)
}
q.sync { audioEndedAt = Date() }

// Keep the socket fed with silence, the way the app does between utterances,
// until the transcript has been stable for a beat.
let silence = Data(count: 2048)
let deadline = Date().addingTimeInterval(25)
var lastCount = 0
var quietSince = Date()
while Date() < deadline {
    session.sendAudio(silence)
    Thread.sleep(forTimeInterval: 0.064)
    if let message = q.sync(execute: { errorText }) {
        print("PROBE-ERR: \(message)")
        session.close()
        exit(1)
    }
    let count = q.sync { output.count }
    if count != lastCount {
        lastCount = count
        quietSince = Date()
    } else if count > 0, Date().timeIntervalSince(quietSince) > 2.0 {
        break
    }
}
session.close()

let text = q.sync { output }.trimmingCharacters(in: .whitespacesAndNewlines)
guard !text.isEmpty, let ended = q.sync(execute: { audioEndedAt }) else {
    print("PROBE-ERR: no output transcript before the deadline")
    exit(1)
}
func seconds(_ date: Date?) -> String {
    guard let date else { return "--" }
    return String(format: "%.2f", date.timeIntervalSince(ended))
}
let label: String
switch mode {
case .translate(let target): label = "translate/\(target)"
case .interpreter(let home, let partner, _): label = "interpreter/\(home)↔\(partner)"
}
print("PROBE: mode=\(label) first=\(q.sync { seconds(firstTokenAt) }) "
    + "full=\(q.sync { seconds(lastTokenAt) }) out=\"\(text)\"")
