// Phase 0 of GitHub #135: does an independent on-device language witness
// separate the two populations, and does it separate them with a GAP?
//
// Feeds a recorded fixture to TWO on-device speech recognizers — one per side
// of the pair — and prints every candidate discriminator per utterance, so
// the choice of rule is made on a table rather than on the first two points
// somebody looked at. That is the #32 lesson stated as a procedure: echoShare
// failed because two turns scored 0.429 with opposite correct answers, and
// the rule that worked measured 0 against 2.
//
// This harness deliberately reaches NO verdict about the discriminator. It
// prints the evidence. `RefereeEvidence.verdict` decides only the structural
// case (one recognizer heard words, the other heard none) and reports
// everything else inconclusive.
//
//   Tools/lidprobe.sh                      # the labelled corpus
//   Tools/lidprobe.sh de es TestAudio/de_after_es.wav=de
//
// Runs entirely on this machine: `requiresOnDeviceRecognition` is set on
// every request, which is an INVARIANT rather than a setting — with it off,
// audio goes to Apple and docs/privacy-policy.md becomes untrue (#135 §6).

import Foundation
import AVFoundation
import Speech

private let recognitionTimeout: TimeInterval = 60

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

// MARK: - Arguments

private struct Fixture {
    let url: URL
    /// The language actually spoken, when the caller labelled it. Unlabelled
    /// fixtures still print their scores; they just cannot be scored correct.
    let truth: TurnLogic.Lang?
    var name: String { url.lastPathComponent }
}

private let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    fail("usage: lidprobe <home> <partner> <file>[=<spoken>] …")
}
guard let home = TurnLogic.Lang(rawValue: args[0]),
      let partner = TurnLogic.Lang(rawValue: args[1]) else {
    fail("unknown language in pair '\(args[0])/\(args[1])'")
}
guard home != partner else { fail("home and partner must differ") }

private let fixtures: [Fixture] = args.dropFirst(2).map { spec in
    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
    let path = parts[0]
    var truth: TurnLogic.Lang?
    if parts.count == 2 {
        guard let t = TurnLogic.Lang(rawValue: parts[1]) else {
            fail("unknown spoken language '\(parts[1])' for \(path)")
        }
        truth = t
    }
    return Fixture(url: URL(fileURLWithPath: path), truth: truth)
}

// MARK: - Authorization
//
// This probe deliberately NEVER calls `SFSpeechRecognizer.requestAuthorization`.
//
// Measured 2026-08-17 on macOS 15: requesting speech authorization from a
// tool built by swiftc is terminated by TCC before any of our code runs —
//
//   namespace TCC, "This app has crashed because it attempted to access
//   privacy-sensitive data without a usage description. The app's Info.plist
//   must contain an NSSpeechRecognitionUsageDescription key…"
//
// — and it happens with the usage description present in every form the
// platform offers: linked into `__TEXT,__info_plist` (verified present with
// `otool -s __TEXT __info_plist`), ad-hoc code-signed, and again inside a
// real `.app` bundle with `CFBundleExecutable`/`CFBundlePackageType` set and
// the bundle signed. Same SIGABRT in all four configurations, sandboxed and
// unsandboxed. TCC appears to want a launch through LaunchServices and a
// human at the prompt, neither of which a measurement harness has.
//
// So the probe READS the status and refuses to run without it, rather than
// asking. That keeps the failure legible — a usage message instead of an
// unexplained abort — and it costs nothing once the grant exists.
//
// Recorded rather than worked around: the same authorization is required on
// the phone, where it costs Heiko a second permission dialog (#135 §5), and
// where it will actually be grantable. See TESTING.md §L0 for the practical
// consequence — Phase 0's corpus measurement belongs on iOS, not here.

private func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not determined"
    @unknown default: return "unknown (\(status.rawValue))"
    }
}

// MARK: - One recognizer's reading

private func transcribe(_ url: URL, as lang: TurnLogic.Lang) -> RefereeEvidence.Reading {
    let identifier = RefereeEvidence.speechLocaleIdentifier(for: lang)
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else {
        return .init(lang: lang, availability: .failed("no recognizer for \(identifier)"))
    }
    guard recognizer.isAvailable else {
        return .init(lang: lang, availability: .failed("recognizer for \(identifier) is not available"))
    }
    // The privacy invariant. A locale with no on-device model stands down;
    // it must NEVER silently fall back to network recognition.
    guard recognizer.supportsOnDeviceRecognition else {
        return .init(lang: lang, availability: .noOnDeviceModel)
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false

    var text = ""
    var confidence = 0.0
    var failure: String?
    let done = DispatchSemaphore(value: 0)
    var settled = false
    let lock = NSLock()
    let finish: () -> Void = {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        done.signal()
    }

    let task = recognizer.recognitionTask(with: request) { result, error in
        if let error {
            failure = error.localizedDescription
            finish()
            return
        }
        guard let result, result.isFinal else { return }
        text = result.bestTranscription.formattedString
        let segments = result.bestTranscription.segments
        if !segments.isEmpty {
            let total = segments.reduce(0.0) { $0 + Double($1.confidence) }
            confidence = total / Double(segments.count)
        }
        finish()
    }

    do {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                break
            }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            request.append(buffer)
        }
    } catch {
        task.cancel()
        return .init(lang: lang, availability: .failed("read: \(error.localizedDescription)"))
    }
    request.endAudio()

    if done.wait(timeout: .now() + recognitionTimeout) == .timedOut {
        task.cancel()
        return .init(lang: lang, availability: .failed("timed out after \(Int(recognitionTimeout))s"))
    }
    if let failure {
        // An empty on-device result surfaces as an error on some releases.
        // Recorded as a failure rather than as silence, because "the
        // recognizer could not run" and "the recognizer heard nothing" are
        // different testimony and the structural rule treats them differently.
        return .init(lang: lang, availability: .failed(failure))
    }
    return .init(lang: lang, availability: .ready, text: text, confidence: confidence)
}

// MARK: - Run

private let status = SFSpeechRecognizer.authorizationStatus()
guard status == .authorized else {
    fail("""
    speech recognition is \(describe(status)) for this tool, and this probe
    does not ask (asking is terminated by TCC — see the note in main.swift,
    measured 2026-08-17 in four configurations).

    Phase 0's corpus measurement therefore does not run on macOS. Run it on
    iOS instead, where the app bundle carries the usage description and the
    grant is a real dialog — which is also where the referee has to work.

    What still runs here: `Tools/l1.sh` covers RefereeEvidence's rules, and
    this file compiles against the app's own sources through
    Tools/session_sources.sh, so the branch cannot silently rot.
    """)
}

print("pair: home=\(home.rawValue) partner=\(partner.rawValue)")
print("locales: \(RefereeEvidence.speechLocaleIdentifier(for: home)) / \(RefereeEvidence.speechLocaleIdentifier(for: partner))")
print("on-device recognition: required on every request")
print("")

private struct Row {
    let fixture: Fixture
    let homeReading: RefereeEvidence.Reading
    let partnerReading: RefereeEvidence.Reading
    let score: RefereeEvidence.Score
    let verdict: RefereeEvidence.Verdict
}

private var rows: [Row] = []
private var unreadable = 0

for fixture in fixtures {
    guard FileManager.default.fileExists(atPath: fixture.url.path) else {
        print("SKIP  \(fixture.name) — no such file")
        unreadable += 1
        continue
    }
    let h = transcribe(fixture.url, as: home)
    let p = transcribe(fixture.url, as: partner)
    let row = Row(fixture: fixture,
                  homeReading: h,
                  partnerReading: p,
                  score: RefereeEvidence.score(home: h, partner: p),
                  verdict: RefereeEvidence.verdict(home: h, partner: p))
    rows.append(row)

    print("── \(fixture.name)\(fixture.truth.map { "  (spoken: \($0.rawValue))" } ?? "")")
    for reading in [h, p] {
        let label = reading.lang == home ? "home   " : "partner"
        switch reading.availability {
        case .ready:
            print("   \(label) [\(reading.lang.rawValue)] conf=\(String(format: "%.2f", reading.confidence)) chars=\(reading.trimmed.count)")
            print("           “\(reading.trimmed)”")
        case .noOnDeviceModel:
            print("   \(label) [\(reading.lang.rawValue)] NO ON-DEVICE MODEL — referee inert for this side")
        case .unauthorized:
            print("   \(label) [\(reading.lang.rawValue)] UNAUTHORIZED")
        case .failed(let why):
            print("   \(label) [\(reading.lang.rawValue)] FAILED: \(why)")
        }
    }
    let s = row.score
    print("   score  confΔ=\(String(format: "%+.2f", s.confidenceDelta)) lengthRatio=\(String(format: "%.3f", s.lengthRatio)) onlyOneSubstantive=\(s.onlyOneSubstantive)")
    switch row.verdict {
    case .spoke(let lang):
        let mark = fixture.truth.map { $0 == lang ? "✓" : "✗" } ?? "?"
        print("   verdict \(mark) \(lang.rawValue)")
    case .inconclusive(let why):
        print("   verdict — inconclusive (\(why))")
    }
    print("")
}

// MARK: - Summary
//
// The separation table is the deliverable. Printing the per-population RANGE
// of each score is what makes a gap visible — or proves there is none, which
// is the result that stops this experiment (#135 §7).

print("=== separation ===")
private let labelled = rows.filter { $0.fixture.truth != nil }
if labelled.isEmpty {
    print("no labelled fixtures — scores printed above, nothing to separate")
} else {
    for population in [home, partner] {
        let group = labelled.filter { $0.fixture.truth == population }
        guard !group.isEmpty else { continue }
        let deltas = group.map(\.score.confidenceDelta)
        let ratios = group.map(\.score.lengthRatio)
        print("spoken=\(population.rawValue)  n=\(group.count)")
        print("   confΔ       \(String(format: "%+.2f … %+.2f", deltas.min()!, deltas.max()!))")
        print("   lengthRatio \(String(format: "%.3f … %.3f", ratios.min()!, ratios.max()!))")
        print("   onlyOneSubstantive: \(group.filter(\.score.onlyOneSubstantive).count)/\(group.count)")
    }
    let decided = labelled.compactMap { row -> Bool? in
        guard case .spoke(let lang) = row.verdict else { return nil }
        return lang == row.fixture.truth
    }
    print("")
    print("structural verdict: \(decided.filter { $0 }.count) correct, \(decided.filter { !$0 }.count) wrong, \(labelled.count - decided.count) inconclusive (of \(labelled.count) labelled)")
    print("")
    print("Phase 0 asks for a gap with nothing in it, not a narrow one.")
    print("Overlapping ranges above mean no cut-off on that score can be right")
    print("about both populations — the #32 result, one phase earlier.")
}

// Exit status says whether the MEASUREMENT ran, never whether the result was
// encouraging. A harness that overstates the thing it measures is worse than
// none (the numberprobe lesson).
exit(unreadable > 0 || rows.isEmpty ? 1 : 0)
