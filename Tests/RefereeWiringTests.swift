import XCTest
import AVFoundation
@testable import HeikoTranslate

/// GitHub #135 Phase 1: the language referee, held by the real service and
/// allowed to do exactly one thing — write a line to the diagnostic log.
///
/// These drive the REAL `GeminiLiveTranslationService` — `start()`, the event
/// route, the finalize timers on a `ManualClock`, the shared teardown — with
/// the sockets, the audio graph and the referee faked at their seams. The
/// referee fake records what the service asked of it; routing is compared
/// against the same event sequence with the inert referee every phone before
/// iOS 26 runs, so "log only" is a measured claim rather than a comment.
@MainActor
final class RefereeWiringTests: XCTestCase {

    // MARK: - Fakes

    private final class RecordingReferee: LanguageRefereeing {
        var starts: [[TurnLogic.Lang]] = []
        var stops = 0
        var turnEnds = 0
        var appended = 0
        private var pair: (home: TurnLogic.Lang, partner: TurnLogic.Lang)?
        let marker: String

        init(marker: String) { self.marker = marker }

        func start(home: TurnLogic.Lang, partner: TurnLogic.Lang) {
            starts.append([home, partner])
            pair = (home, partner)
        }

        // Called from the tap block, which these tests invoke on the main
        // thread themselves.
        func append(_ buffer: AVAudioPCMBuffer) { appended += 1 }

        func turnEnded() -> RefereeEvidence? {
            turnEnds += 1
            guard let pair else { return nil }
            return RefereeEvidence(
                home: .init(lang: pair.home, text: "\(marker) home words", confidence: 0.9),
                partner: .init(lang: pair.partner, text: "partner words", confidence: 0.2))
        }

        func stop() {
            stops += 1
            pair = nil
        }
    }

    private final class FakeSocket: LiveTranslationSocket {
        let onEvent: (GeminiLiveSession.Event) -> Void
        init(onEvent: @escaping (GeminiLiveSession.Event) -> Void) { self.onEvent = onEvent }
        func connect() {}
        func close() {}
        func sendAudio(_ pcm16kData: Data) {}
    }

    private final class Sockets {
        var current: [TurnLogic.Lang: FakeSocket] = [:]
    }

    /// What the user sees from a run: every bubble, and every request to
    /// repeat. The thing that must not move with the referee.
    private final class Outcome: Equatable {
        var bubbles: [String] = []
        var unresolved = 0
        static func == (a: Outcome, b: Outcome) -> Bool {
            a.bubbles == b.bubbles && a.unresolved == b.unresolved
        }
    }

    private final class FactoryCalls { var count = 0 }

    private let clock = ManualClock()

    private func drain() async { for _ in 0..<25 { await Task.yield() } }

    private func marker() -> String { "wiring\(Int.random(in: 100_000...999_999))" }

    private func service(referee: @escaping () -> LanguageRefereeing,
                         calls: FactoryCalls = FactoryCalls())
        -> (GeminiLiveTranslationService, Sockets) {
        let sockets = Sockets()
        let service = GeminiLiveTranslationService(clock: clock)
        service.skipAudioIOForTesting = true
        service.refereeFactoryForTesting = {
            calls.count += 1
            return referee()
        }
        service.sessionFactoryForTesting = { lang, onEvent in
            let fake = FakeSocket(onEvent: onEvent)
            sockets.current[lang] = fake
            return fake
        }
        return (service, sockets)
    }

    private func start(_ service: GeminiLiveTranslationService, _ sockets: Sockets,
                       home: TurnLogic.Lang = .de, partner: TurnLogic.Lang = .en,
                       outcome: Outcome = Outcome()) async throws {
        try service.start(
            home: home, partner: partner,
            onPartialInput: { _ in },
            onUtterance: { original, translation, wasHome in
                outcome.bubbles.append("\(wasHome ? "RIGHT" : "LEFT") \(original) → \(translation)")
            },
            onActivity: { _ in }, onError: { _ in },
            onTurnUnresolved: { outcome.unresolved += 1 })
        sockets.current[home]?.onEvent(.setupComplete)
        sockets.current[partner]?.onEvent(.setupComplete)
        await drain()
    }

    /// An English turn on de↔en the way the wire delivers it; `translated`
    /// nil leaves the home session silent, which the app must reject.
    private func englishTurn(_ service: GeminiLiveTranslationService, _ sockets: Sockets,
                             heard: String, translated: String?) async {
        service.markSpeechHeardForTesting()
        for _ in 0..<2 {
            sockets.current[.en]?.onEvent(.inputLanguage("en"))
            sockets.current[.de]?.onEvent(.inputLanguage("en"))
            await drain()
        }
        sockets.current[.en]?.onEvent(.inputTranscript(heard))
        sockets.current[.de]?.onEvent(.inputTranscript(heard))
        await drain()
        if let translated {
            sockets.current[.de]?.onEvent(.outputTranscript(translated))
            await drain()
        }
    }

    /// Past the finalize chain and every deferral (#21): a second at a time,
    /// so each timer a firing timer arms gets its main-actor hops drained.
    private func settle(seconds: Int = 16) async {
        for _ in 0..<seconds {
            clock.advance(by: 1)
            await drain()
        }
    }

    private func loggedLines(containing text: String) -> [String] {
        DiagnosticLog.shared.exportText()
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(text) }
    }

    // MARK: - Lifecycle

    /// L1.121 — the referee is started for the run's pair, stopped by the
    /// run's teardown, and started again, for the new pair, by the next run.
    /// One referee for the service's life: the factory runs once.
    func testL1_121_theRefereeFollowsTheRun() async throws {
        let calls = FactoryCalls()
        let referee = RecordingReferee(marker: marker())
        let (service, sockets) = service(referee: { referee }, calls: calls)

        try await start(service, sockets)
        XCTAssertEqual(referee.starts, [[.de, .en]])
        XCTAssertEqual(referee.stops, 0)

        service.stopSession()
        XCTAssertEqual(referee.stops, 1, "a mute stops the referee")

        try await start(service, sockets, home: .de, partner: .es)
        XCTAssertEqual(referee.starts, [[.de, .en], [.de, .es]], "the next run starts it again, for its own pair")
        XCTAssertEqual(referee.stops, 1)

        // A start over a running service tears the old run down first, and
        // the referee with it.
        try await start(service, sockets, home: .de, partner: .ko)
        XCTAssertEqual(referee.stops, 2)
        XCTAssertEqual(referee.starts.last, [.de, .ko])

        service.stopSession()
        XCTAssertEqual(referee.stops, 3)
        XCTAssertEqual(calls.count, 1, "one referee per service")
    }

    /// L1.121b — the tap feeds the referee the raw buffer, and a watchdog
    /// rebuild (#129) reinstalls the tap without stopping the referee: the
    /// rebuilt tap feeds the same instance.
    func testL1_121b_aRebuiltTapKeepsFeedingTheSameReferee() throws {
        final class Graph: AudioGraphControlling {
            var taps: [(AVAudioPCMBuffer, AVAudioTime) -> Void] = []
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                       channels: 1, interleaved: false)!
            func activateSession() throws {}
            func enableVoiceProcessing() throws {}
            func wirePlayer() {}
            func startEngine() throws {}
            func inputFormat() -> AVAudioFormat { format }
            func installTap(_ block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) { taps.append(block) }
            func removeTap() {}
            func startPlayback() {}
            func stopPlaybackAndEngine() {}
            func deactivateSession() {}
        }
        let graph = Graph()
        let calls = FactoryCalls()
        let referee = RecordingReferee(marker: marker())
        let service = GeminiLiveTranslationService(clock: clock)
        service.audioGraphForTesting = graph
        service.refereeFactoryForTesting = { calls.count += 1; return referee }
        service.sessionFactoryForTesting = { _, onEvent in FakeSocket(onEvent: onEvent) }
        try service.start(home: .de, partner: .en,
                          onPartialInput: { _ in }, onUtterance: { _, _, _ in },
                          onActivity: { _ in }, onError: { _ in })

        let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        let when = AVAudioTime(hostTime: 0)
        XCTAssertEqual(graph.taps.count, 1)
        graph.taps[0](buffer, when)
        XCTAssertEqual(referee.appended, 1, "the tap hands the referee its buffer")

        // Buffers flow, then stop: the mid-run watchdog rebuilds the path.
        for _ in 0..<50 {
            service.noteMicBufferForTesting()
            clock.advance(by: 0.1)
        }
        clock.advance(by: MicLiveness.stallThreshold + 1.05)
        XCTAssertEqual(graph.taps.count, 2, "precondition: the stall rebuilt the tap")
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(referee.stops, 0, "a rebuild is not a stop — the referee keeps listening")
        XCTAssertEqual(referee.starts.count, 1)

        graph.taps[1](buffer, when)
        XCTAssertEqual(referee.appended, 2, "the rebuilt tap feeds the same referee")
        XCTAssertEqual(calls.count, 1)
        service.stopSession()
        XCTAssertEqual(referee.stops, 1)
    }

    // MARK: - Turn boundary, and routing unchanged

    private func committedTurn(_ referee: @escaping () -> LanguageRefereeing) async throws -> Outcome {
        let outcome = Outcome()
        let (service, sockets) = service(referee: referee)
        try await start(service, sockets, outcome: outcome)
        await englishTurn(service, sockets, heard: "Where is the nearest station?",
                          translated: "Wo ist der nächste Bahnhof?")
        await settle()
        service.stopSession()
        return outcome
    }

    private func rejectedTurn(_ referee: @escaping () -> LanguageRefereeing) async throws -> Outcome {
        let outcome = Outcome()
        let (service, sockets) = service(referee: referee)
        try await start(service, sockets, outcome: outcome)
        await englishTurn(service, sockets, heard: "Where is the nearest station?", translated: nil)
        await settle()
        service.stopSession()
        return outcome
    }

    /// L1.121c — a committed turn: the boundary rotates the referee exactly
    /// once, writes exactly one referee line naming the app's commit, and the
    /// bubble is the one the inert referee's run produces.
    func testL1_121c_aCommittedTurnIsLoggedAndRoutedAsWithoutTheReferee() async throws {
        let mark = marker()
        let referee = RecordingReferee(marker: mark)
        let withReferee = try await committedTurn({ referee })
        let inert = try await committedTurn({ InertLanguageReferee(reason: .unsupportedOS) })

        XCTAssertEqual(withReferee.bubbles, ["LEFT Where is the nearest station? → Wo ist der nächste Bahnhof?"],
                       "precondition: the turn commits")
        XCTAssertEqual(withReferee, inert, "the referee changes nothing the user sees")
        XCTAssertEqual(referee.turnEnds, 2, "one boundary at start, one for the turn")

        let lines = loggedLines(containing: mark)
        XCTAssertEqual(lines.count, 1, "exactly one referee line for the turn — got \(lines)")
        XCTAssertTrue(lines.first?.contains("referee: home (home more confident)") ?? false, "\(lines)")
        XCTAssertTrue(lines.first?.contains("| app: LEFT/foreign |") ?? false,
                      "the line carries what the app did — got \(lines)")
    }

    /// L1.121d — a rejected turn: the app's rejection is untouched by the
    /// referee — the same deferrals, the same request to repeat — and the
    /// referee line records the rejection beside its own verdict.
    func testL1_121d_aRejectedTurnIsLoggedAndRejectedAsWithoutTheReferee() async throws {
        let mark = marker()
        let referee = RecordingReferee(marker: mark)
        let withReferee = try await rejectedTurn({ referee })
        let inert = try await rejectedTurn({ InertLanguageReferee(reason: .unsupportedOS) })

        XCTAssertEqual(withReferee.bubbles, [], "precondition: nothing commits without a translation")
        XCTAssertEqual(withReferee.unresolved, 1, "precondition: the turn is given up on")
        XCTAssertEqual(withReferee, inert, "the referee changes nothing the user sees")
        XCTAssertEqual(referee.turnEnds, 2)

        let lines = loggedLines(containing: mark)
        XCTAssertEqual(lines.count, 1, "got \(lines)")
        XCTAssertTrue(lines.first?.contains("| app: REJECTED: ") ?? false, "got \(lines)")
    }

    // MARK: - The line

    /// L1.121e — the line's format, pinned on the real formatter: verdict,
    /// scores, the app's outcome, then both readings with availability, text
    /// and confidence — escaped, so a transcript cannot forge a log entry.
    func testL1_121e_theRefereeLineCarriesBothReadingsOnOneLine() {
        let e = RefereeEvidence(
            home: .init(lang: .de, text: "Wo ist \"der\"\nBahnhof", confidence: 0.957),
            partner: .init(lang: .es, availability: .assetsNotInstalled))
        let line = GeminiLiveTranslationService.refereeDiagnosticLine(e, appOutcome: "RIGHT/home")
        XCTAssertEqual(line,
                       "  referee: inconclusive (unavailable) score=delta:n/a len:+1.000 weighted:n/a chars:15/0"
                       + " | app: RIGHT/home"
                       + " | referee[de] ready \"Wo ist \\\"der\\\"\\nBahnhof\" conf=0.957"
                       + "   referee[es] model-not-installed \"\" conf=n/a")
        XCTAssertFalse(line.contains("\n"))

        let none = GeminiLiveTranslationService.refereeDiagnosticLine(e, appOutcome: nil)
        XCTAssertTrue(none.contains("| app: no commit attempted |"))
    }

    /// L1.121f — the line is written only for a turn with something in it:
    /// not for a quiet boundary with an inert referee, which keeps a phone
    /// before iOS 26 logging exactly what it did before.
    func testL1_121f_aQuietTurnWritesNoLine() {
        let inert = RefereeEvidence(home: .init(lang: .de, availability: .unsupportedOS),
                                    partner: .init(lang: .en, availability: .unsupportedOS))
        XCTAssertFalse(GeminiLiveTranslationService.refereeTurnHadContent(inert, heardSpeech: false))
        XCTAssertTrue(GeminiLiveTranslationService.refereeTurnHadContent(inert, heardSpeech: true),
                      "a spoken turn is logged even when the referee could not testify")

        let transcriberOnly = RefereeEvidence(home: .init(lang: .de, text: "ja", confidence: 0.5),
                                              partner: .init(lang: .en))
        XCTAssertTrue(GeminiLiveTranslationService.refereeTurnHadContent(transcriberOnly, heardSpeech: false),
                      "words only the transcriber heard are worth a line")

        let silent = RefereeEvidence(home: .init(lang: .de, text: " . "), partner: .init(lang: .en))
        XCTAssertFalse(GeminiLiveTranslationService.refereeTurnHadContent(silent, heardSpeech: false))
    }

    // MARK: - Log only, in code

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func codeWithoutComments(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let r = line.range(of: "//") else { return line }
                return line[..<r.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// L1.121g — the log-only invariant, enforced in code: the decision layer
    /// cannot see the referee. `TurnLogic.swift` and every other file under
    /// `Models/` name no referee type or value, so no routing, commit or
    /// direction rule can read its evidence. Phase 2 (#135) would change this
    /// test on purpose, and visibly.
    func testL1_121g_theDecisionLayerCannotSeeTheReferee() throws {
        let models = repoRoot.appendingPathComponent("HeikoTranslate/Models")
        let files = try FileManager.default.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "RefereeEvidence.swift" }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "TurnLogic.swift" },
                      "sanity: the scan reads TurnLogic")
        XCTAssertGreaterThan(files.count, 3, "sanity: the scan found the Models sources")
        for file in files {
            let source = try codeWithoutComments(at: file)
            XCTAssertNil(source.range(of: "referee", options: .caseInsensitive),
                         "\(file.lastPathComponent) references the referee — it is log only (#135)")
        }
    }

    // MARK: - Downloads only on an unmetered network

    /// L1.121h — the download guard's flag: unknown answers no, and so does
    /// an offline, expensive (cellular, hotspot) or constrained (Low Data
    /// Mode) path. Only a path known to be none of those allows a download.
    func testL1_121h_speechModelsDownloadOnlyOnAKnownUnmeteredNetwork() {
        let network = UnmeteredNetwork()
        XCTAssertFalse(network.allowsDownloads(), "unknown counts as metered")

        network.update(satisfied: true, expensive: false, constrained: false)
        XCTAssertTrue(network.allowsDownloads(), "Wi-Fi without Low Data Mode")

        network.update(satisfied: true, expensive: true, constrained: false)
        XCTAssertFalse(network.allowsDownloads(), "cellular or roaming")

        network.update(satisfied: true, expensive: false, constrained: true)
        XCTAssertFalse(network.allowsDownloads(), "Low Data Mode")

        network.update(satisfied: false, expensive: false, constrained: false)
        XCTAssertFalse(network.allowsDownloads(), "offline")

        network.update(satisfied: true, expensive: false, constrained: false)
        XCTAssertTrue(network.allowsDownloads(), "the latest path decides")
    }
}
