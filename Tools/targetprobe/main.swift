import Foundation

// Target-language probe: does the live model accept a given
// targetLanguageCode and produce a translation? Run before adding any
// language to the app's picker — evidence first.
//
//   Tools/targetprobe.sh fr ko zh
//
// Streams en_short.wav to one session per code and prints what came back.

// Arguments before the key: called with none, the probe explains itself and
// exits without needing Secrets.plist — which is also what lets the launcher
// be smoke-checked offline (GitHub #21).
let codes = Array(CommandLine.arguments.dropFirst())
guard !codes.isEmpty else {
    fputs("usage: targetprobe <lang-code> [more codes]\n", stderr)
    exit(2)
}
let apiKey = loadAPIKey()
let pcm = loadWAV("TestAudio/en_short.wav")

for code in codes {
    var output = ""
    var errorText: String?
    var ready = false
    let sem = DispatchSemaphore(value: 0)
    let q = DispatchQueue(label: "probe-\(code)")

    let session = GeminiLiveSession(targetLanguageCode: code, apiKey: apiKey) { event in
        q.async {
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
        print("\(code): ✗ \(q.sync { errorText } ?? "no setupComplete in 15s")")
        session.close()
        continue
    }
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + 2048, pcm.count)
        session.sendAudio(pcm.subdata(in: offset..<end))
        offset = end
        Thread.sleep(forTimeInterval: 0.064)
    }
    let silence = Data(count: 2048)
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        session.sendAudio(silence)
        Thread.sleep(forTimeInterval: 0.064)
        if let e = q.sync(execute: { errorText }) { print("\(code): ✗ \(e)"); break }
        if q.sync(execute: { output.count }) > 10 { break }
    }
    session.close()
    let text = q.sync { output }.trimmingCharacters(in: .whitespacesAndNewlines)
    print("\(code): \(text.isEmpty ? "✗ no output" : "✓ \(text.prefix(80))")")
}
