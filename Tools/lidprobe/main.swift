// Phase 0 of GitHub #135: does an independent on-device language witness
// separate the two populations — and does it separate them with a GAP?
//
// Feeds each labelled fixture to TWO `SpeechTranscriber`s, one per side of the
// pair, and prints every reading and every candidate score from #135 §3. Then,
// per score, it prints both populations' ranges and whether there is a gap
// with nothing in it. It never fits a cut-off: "the ranges do not overlap" is a
// fact about the table, a threshold between them would be a choice.
//
// The scores and the verdict are computed by the APP's
// `RefereeEvidence`, compiled in through Tools/session_sources.sh, so this
// measures the code the app would run rather than a copy of it (#103).
//
//   Tools/lidprobe.sh                           # the whole TestAudio corpus
//   Tools/lidprobe.sh TestAudio/de_short.wav    # specific fixtures
//   Tools/lidprobe.sh --assets-only             # locale support and installs
//   Tools/lidprobe.sh --request-sf-authorization  # the TCC control, see below
//
// Silent by construction: audio is read from disk into the analyzer and never
// routed to an output device.
//
// On-device only: `SpeechTranscriber` has no network recognition mode at all —
// its interface has no `requiresOnDeviceRecognition` because there is nothing
// to turn off. What does touch the network is the one-time MODEL download
// through `AssetInventory`, which fetches Apple's model and sends no audio.

import Foundation
import AVFoundation
import Speech

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

private func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

private func f2(_ x: Double?) -> String { x.map { String(format: "%+.3f", $0) } ?? "n/a" }
private func p2(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "n/a" }

private let args = Array(CommandLine.arguments.dropFirst())

// MARK: - The TCC control
//
// The permission question (#135 §5) is answered by what the transcriber run
// below does NOT do: this binary carries no usage description, and on the
// 2026-08-17 run `SFSpeechRecognizer.requestAuthorization` from a swiftc-built
// tool was terminated by TCC for exactly that. This mode repeats that request,
// so a clean transcriber run on the same machine, the same day, is compared
// against a control that shows TCC is still enforcing — not assumed to be.

private func runAuthorizationControl() -> Never {
    print("control: SFSpeechRecognizer.authorizationStatus() = \(describe(SFSpeechRecognizer.authorizationStatus()))")
    print("control: calling SFSpeechRecognizer.requestAuthorization …")
    let done = DispatchSemaphore(value: 0)
    SFSpeechRecognizer.requestAuthorization { status in
        print("control: requestAuthorization returned \(describe(status))")
        done.signal()
    }
    if done.wait(timeout: .now() + 20) == .timedOut {
        print("control: no answer within 20 s (a prompt may be waiting)")
        exit(2)
    }
    exit(0)
}

if args.first == "--request-sf-authorization" { runAuthorizationControl() }

guard #available(macOS 26.0, *) else {
    fail("SpeechTranscriber needs macOS 26 — this machine is older")
}

// MARK: - Fixtures

private enum Label {
    case spoken(TurnLogic.Lang)
    case noSpeech           // silence.wav, noise.wav — the false-positive check
    case skipped(String)    // a language outside the app's set
}

private struct Fixture {
    let url: URL
    let label: Label
    /// Two utterances in two languages joined with a gap (make_test_audio.sh
    /// builds these for the direction-memory tests). The app would see two
    /// turns; a single reading of the whole file is not a one-language turn.
    /// Declared here BEFORE any measurement, and reported both ways.
    let composite: Bool
    var name: String { url.lastPathComponent }
}

private let compositeNames: Set<String> = ["de_after_en.wav", "de_after_es.wav"]

private func label(for url: URL) -> Label {
    let name = url.deletingPathExtension().lastPathComponent
    if name == "silence" || name == "noise" { return .noSpeech }
    let prefix = String(name.prefix { $0 != "_" })
    if let lang = TurnLogic.Lang(rawValue: prefix) { return .spoken(lang) }
    return .skipped("language '\(prefix)' is not in the app's set")
}

// MARK: - Assets

private let home = TurnLogic.Lang.de
private let partners: [TurnLogic.Lang] = TurnLogic.Lang.allCases.filter { $0 != home }

private func transcriber(for locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(locale: locale,
                      transcriptionOptions: [],
                      reportingOptions: [.alternativeTranscriptions],
                      attributeOptions: [.transcriptionConfidence])
}

/// Resolves every app language to the OS's equivalent locale and installs any
/// that are supported but missing. Returns the usable locale per language.
private func prepareAssets(install: Bool) async -> [TurnLogic.Lang: Locale] {
    print("SpeechTranscriber.isAvailable = \(SpeechTranscriber.isAvailable)")
    let supported = await SpeechTranscriber.supportedLocales
    let installed = await SpeechTranscriber.installedLocales
    print("supportedLocales = \(supported.count)  installedLocales = \(installed.count)  maximumReservedLocales = \(AssetInventory.maximumReservedLocales)")
    print("installed: \(installed.map(\.identifier).sorted().joined(separator: ", "))")
    print("reserved:  \(await AssetInventory.reservedLocales.map(\.identifier).sorted().joined(separator: ", "))")

    var ready: [TurnLogic.Lang: Locale] = [:]
    for lang in TurnLogic.Lang.allCases {
        let wanted = Locale(identifier: RefereeEvidence.localeIdentifier(for: lang))
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            print("  \(lang.rawValue): \(wanted.identifier) UNSUPPORTED by this OS")
            continue
        }
        let module = transcriber(for: locale)
        let before = await AssetInventory.status(forModules: [module])
        var line = "  \(lang.rawValue): \(wanted.identifier) → \(locale.identifier)  status=\(before)"
        if before == .installed {
            ready[lang] = locale
            print(line)
            continue
        }
        guard install else {
            print(line + "  (install disabled)")
            continue
        }
        do {
            let clock = ContinuousClock()
            let started = clock.now
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            let took = clock.now - started
            let after = await AssetInventory.status(forModules: [module])
            line += "  → installed in \(String(format: "%.1f", Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18)) s, status=\(after)"
            if after == .installed { ready[lang] = locale }
        } catch {
            line += "  → install FAILED: \(error.localizedDescription)"
        }
        print(line)
    }
    return ready
}

// MARK: - One recognizer's reading

private func read(_ url: URL, as lang: TurnLogic.Lang, locale: Locale?) async -> RefereeEvidence.Reading {
    guard let locale else {
        return .init(lang: lang, availability: .assetsNotInstalled)
    }
    let module = transcriber(for: locale)
    let collector = Task { () throws -> [SpeechTranscriber.Result] in
        var out: [SpeechTranscriber.Result] = []
        for try await result in module.results { out.append(result) }
        return out
    }
    do {
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [module])
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let results = try await collector.value

        var text = ""
        var weighted = 0.0
        var counted = 0
        var alternatives: [String] = []
        for result in results {
            text += String(result.text.characters)
            for run in result.text.runs {
                guard let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { continue }
                let n = result.text[run.range].characters.count
                weighted += c * Double(n)
                counted += n
            }
            let own = String(result.text.characters)
            for alt in result.alternatives.map({ String($0.characters) }) where alt != own {
                alternatives.append(alt)
            }
        }
        return .init(lang: lang, availability: .ready, text: text,
                     confidence: counted > 0 ? weighted / Double(counted) : nil,
                     alternatives: alternatives)
    } catch {
        collector.cancel()
        return .init(lang: lang, availability: .failed(error.localizedDescription))
    }
}

// MARK: - Run

private let authBefore = SFSpeechRecognizer.authorizationStatus()
print("SFSpeechRecognizer.authorizationStatus() before = \(describe(authBefore))  (read only; this probe never requests it)")
print("usage description in this binary: NSSpeechRecognitionUsageDescription=\(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") == nil ? "absent" : "present")")
print("")

private let installAllowed = !args.contains("--no-install")
private let locales = await prepareAssets(install: installAllowed)
print("")
if args.contains("--assets-only") { exit(0) }

private let paths = args.filter { !$0.hasPrefix("--") }
guard !paths.isEmpty else { fail("usage: lidprobe [--no-install] [--assets-only] <file.wav> …") }

private let fixtures = paths.map { path -> Fixture in
    let url = URL(fileURLWithPath: path)
    return Fixture(url: url, label: label(for: url), composite: compositeNames.contains(url.lastPathComponent))
}

private struct Observation {
    let fixture: Fixture
    let partner: TurnLogic.Lang
    /// true = home (de) was spoken, false = the partner was, nil = neither.
    let homeSpoken: Bool?
    let evidence: RefereeEvidence
}

private var observations: [Observation] = []
private var unreadable = 0

for fixture in fixtures {
    guard FileManager.default.fileExists(atPath: fixture.url.path) else {
        print("MISSING  \(fixture.name)")
        unreadable += 1
        continue
    }
    let pairs: [TurnLogic.Lang]
    let truth: TurnLogic.Lang?
    switch fixture.label {
    case .skipped(let why):
        print("SKIPPED  \(fixture.name) — \(why)")
        continue
    case .noSpeech:
        pairs = partners
        truth = nil
    case .spoken(let lang):
        // A home-language file testifies in every pair; a partner-language
        // file only in its own.
        pairs = lang == home ? partners : [lang]
        truth = lang
    }

    let homeReading = await read(fixture.url, as: home, locale: locales[home])
    print("── \(fixture.name)  spoken=\(truth?.rawValue ?? "none")\(fixture.composite ? "  [composite: two utterances]" : "")")
    printReading("de", homeReading)
    for partner in pairs {
        let partnerReading = await read(fixture.url, as: partner, locale: locales[partner])
        let evidence = RefereeEvidence(home: homeReading, partner: partnerReading)
        observations.append(Observation(fixture: fixture, partner: partner,
                                        homeSpoken: truth.map { $0 == home }, evidence: evidence))
        printReading(partner.rawValue, partnerReading)
        let s = evidence.score
        let mark: String
        switch (evidence.verdict, truth) {
        case (.inconclusive, _): mark = "·"
        case (_, nil): mark = "!"   // named a language for no speech
        case (.home, let t?): mark = t == home ? "✓" : "✗"
        case (.partner, let t?): mark = t == partner ? "✓" : "✗"
        }
        print("     de↔\(partner.rawValue)  confΔ=\(f2(s.confidenceDelta)) lengthBal=\(f2(s.lengthBalance)) weightedBal=\(f2(s.weightedBalance)) onlyOne=\(s.onlyOneSubstantive)  verdict \(mark) \(evidence.verdict) (\(evidence.reason))")
    }
    print("")
}

private func printReading(_ tag: String, _ r: RefereeEvidence.Reading) {
    switch r.availability {
    case .ready:
        print("   [\(tag)] conf=\(p2(r.confidence)) chars=\(r.speechCharacters) “\(r.trimmed)”")
        for alt in r.alternatives.prefix(3) { print("        alt “\(alt.trimmingCharacters(in: .whitespacesAndNewlines))”") }
    default:
        print("   [\(tag)] \(r.availability)")
    }
}

// MARK: - Separation
//
// The deliverable. For each candidate, the two populations' ranges and the
// gap between them: min(home-spoken) − max(partner-spoken). Positive means a
// gap with nothing in it. Zero or negative means no cut-off on that score can
// be right about both populations.

private struct Candidate {
    let name: String
    let value: (RefereeEvidence) -> Double?
}

private let candidates: [Candidate] = [
    .init(name: "home confidence") { $0.home.confidence },
    .init(name: "−partner confidence") { $0.partner.confidence.map { -$0 } },
    .init(name: "confidence delta") { $0.score.confidenceDelta },
    .init(name: "length balance") { $0.score.lengthBalance },
    .init(name: "weighted balance") { $0.score.weightedBalance },
]

private func separation(_ title: String, _ set: [Observation]) {
    let h = set.filter { $0.homeSpoken == true }
    let p = set.filter { $0.homeSpoken == false }
    print("\(title)   n(home spoken)=\(h.count)  n(partner spoken)=\(p.count)")
    guard !h.isEmpty, !p.isEmpty else {
        print("   one population is empty — nothing can be separated")
        return
    }
    for c in candidates {
        let hv = h.compactMap { c.value($0.evidence) }
        let pv = p.compactMap { c.value($0.evidence) }
        guard let hMin = hv.min(), let hMax = hv.max(), let pMin = pv.min(), let pMax = pv.max() else {
            print(String(format: "   %-20@ no values", c.name as NSString))
            continue
        }
        let gap = hMin - pMax
        let verdict = gap > 0 ? String(format: "GAP %.3f", gap) : String(format: "no gap (overlap %.3f)", -gap)
        print(String(format: "   %-20@ home [%+.3f … %+.3f]  partner [%+.3f … %+.3f]  %@",
                     c.name as NSString, hMin, hMax, pMin, pMax, verdict as NSString))
    }
    let decided = set.filter { $0.homeSpoken != nil && $0.evidence.verdict != .inconclusive }
    let right = decided.filter { ($0.evidence.verdict == .home) == $0.homeSpoken! }.count
    print("   RefereeEvidence verdict (margin \(RefereeEvidence.Thresholds.confidenceMargin)): \(right) right, \(decided.count - right) wrong, \(h.count + p.count - decided.count) inconclusive")
}

print("=== separation ===")
private let labelled = observations.filter { $0.homeSpoken != nil }
private let single = labelled.filter { !$0.fixture.composite }
for partner in partners {
    separation("de↔\(partner.rawValue), single utterances", single.filter { $0.partner == partner })
}
separation("ALL PAIRS, single utterances", single)
separation("ALL PAIRS, composites included", labelled)

private let noSpeech = observations.filter { $0.homeSpoken == nil }
private let invented = noSpeech.filter { $0.evidence.verdict != .inconclusive }
print("no-speech fixtures: \(noSpeech.count) readings, \(invented.count) named a language")
print("")
print("SFSpeechRecognizer.authorizationStatus() after = \(describe(SFSpeechRecognizer.authorizationStatus()))")

// Exit status says whether the MEASUREMENT ran, never whether the result was
// encouraging.
exit(unreadable > 0 || observations.isEmpty ? 1 : 0)
