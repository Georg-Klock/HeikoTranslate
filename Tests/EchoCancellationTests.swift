import AVFoundation
import XCTest
@testable import HeikoTranslate

/// GitHub #130: when hardware echo cancellation will not switch on, the app
/// keeps running (L1.68d, unchanged) — but it no longer does so invisibly. The
/// warning goes up, a background retry rebuilds the audio path between turns
/// until echo cancellation comes back, and the warning clears when it does.
@MainActor
final class EchoCancellationTests: XCTestCase {

    // MARK: - The pure policy

    /// L1.109 — a retry rebuilds the audio path, so it only runs between
    /// turns (R4): never while someone speaks or a translation plays.
    func testL1_109_aRetryOnlyRunsBetweenTurns() {
        typealias R = EchoCancellationRecovery
        XCTAssertEqual(R.decide(turnInProgress: false, playingOutput: false, recentSpeech: false), .retryNow)
        for (turn, playing, speech) in [(true, false, false), (false, true, false), (false, false, true),
                                        (true, true, true)] {
            XCTAssertEqual(R.decide(turnInProgress: turn, playingOutput: playing, recentSpeech: speech), .waitForIdle,
                           "turn \(turn) playing \(playing) speech \(speech)")
        }
    }

    /// L1.109b — the schedule escalates and then holds: never gives up, never
    /// storms the hardware.
    func testL1_109b_theScheduleEscalatesThenHolds() {
        var r = EchoCancellationRecovery()
        var delays: [TimeInterval] = []
        for _ in 0..<7 { delays.append(r.nextDelay); r.noteAttempt() }
        XCTAssertEqual(delays, [3, 10, 30, 60, 60, 60, 60])
        r.reset()
        XCTAssertEqual(r.nextDelay, 3, "a recovery starts the next episode from the top")
    }

    // MARK: - The real service

    private struct Boom: Error {}

    private final class FakeAudioGraph: AudioGraphControlling {
        var events: [String] = []
        var aecError: Error?
        var engineError: Error?
        func activateSession() throws { events.append("activate") }
        func enableVoiceProcessing() throws { events.append("aec"); if let e = aecError { throw e } }
        func wirePlayer() { events.append("wire") }
        func startEngine() throws { events.append("engine"); if let e = engineError { throw e } }
        func inputFormat() -> AVAudioFormat {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        }
        func installTap(_ block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) { events.append("tap") }
        func removeTap() { events.append("removeTap") }
        func startPlayback() { events.append("play") }
        func stopPlaybackAndEngine() { events.append("stopEngine") }
        func deactivateSession() { events.append("deactivate") }
        var aecAttempts: Int { events.filter { $0 == "aec" }.count }
    }

    private final class FakeSocket: LiveTranslationSocket {
        func connect() {}
        func close() {}
        func sendAudio(_ pcm16kData: Data) {}
    }

    private final class Reports { var values: [Bool] = [] }

    private func startedService(aecFails: Bool) throws
        -> (GeminiLiveTranslationService, FakeAudioGraph, ManualClock, Reports) {
        let graph = FakeAudioGraph()
        graph.aecError = aecFails ? Boom() : nil
        let clock = ManualClock()
        let reports = Reports()
        let service = GeminiLiveTranslationService(clock: clock)
        service.audioGraphForTesting = graph
        service.sessionFactoryForTesting = { _, _ in FakeSocket() }
        try service.start(
            home: .de, partner: .en,
            onPartialInput: { _ in }, onUtterance: { _, _, _ in },
            onActivity: { _ in }, onError: { _ in },
            onEchoCancellation: { reports.values.append($0) })
        return (service, graph, clock, reports)
    }

    /// Advance the clock with the microphone delivering, so neither mic
    /// watchdog (#87, #129) rebuilds anything and every rebuild counted below
    /// is the echo-cancellation retry's own.
    private func run(_ service: GeminiLiveTranslationService, _ clock: ManualClock, for seconds: TimeInterval) {
        var elapsed = 0.0
        while elapsed < seconds {
            service.noteMicBufferForTesting()
            clock.advance(by: 0.1)
            elapsed += 0.1
        }
    }

    /// L1.109c — a failed enable is still not fatal (L1.68d), and is now
    /// reported: the warning goes up exactly once.
    func testL1_109c_aFailedEnableIsReportedNotFatal() throws {
        let (service, graph, _, reports) = try startedService(aecFails: true)
        XCTAssertTrue(service.isRunning, "not fatal — full-duplex without cancellation beats not running")
        XCTAssertEqual(graph.events.last, "play")
        XCTAssertEqual(reports.values, [false], "reported once, at the start that failed")
        service.stopSession()
    }

    /// L1.109d — while it keeps failing, the retry keeps rebuilding on the
    /// escalating schedule, and the warning is not re-sent on every attempt.
    func testL1_109d_aFailingRetryKeepsTryingWithoutRepeatingTheWarning() throws {
        let (service, graph, clock, reports) = try startedService(aecFails: true)
        XCTAssertEqual(graph.aecAttempts, 1)
        run(service, clock, for: 3.2)
        XCTAssertEqual(graph.aecAttempts, 2, "the first retry at 3s")
        run(service, clock, for: 10.2)
        XCTAssertEqual(graph.aecAttempts, 3, "the second 10s later")
        XCTAssertEqual(reports.values, [false], "one warning for the whole episode")
        XCTAssertTrue(service.isRunning)
        service.stopSession()
    }

    /// L1.109e — the self-heal: a retry that succeeds clears the warning, and
    /// nothing is retried after that.
    ///
    /// Fail-first: without the retry the warning would stay up for the rest
    /// of the run and echo cancellation would never be tried again.
    func testL1_109e_aSuccessfulRetryClearsTheWarning() throws {
        let (service, graph, clock, reports) = try startedService(aecFails: true)
        graph.aecError = nil                                   // the hardware is willing again
        run(service, clock, for: 3.2)
        XCTAssertEqual(reports.values, [false, true], "warning up, then cleared by the retry")
        let attempts = graph.aecAttempts
        run(service, clock, for: 120)
        XCTAssertEqual(graph.aecAttempts, attempts, "healed: no further retries")
        service.stopSession()
    }

    /// L1.109f — a retry falling due mid-turn waits for the turn to end
    /// rather than dropping the microphone under someone who is speaking.
    func testL1_109f_aRetryWaitsForTheTurnToEnd() throws {
        let (service, graph, clock, _) = try startedService(aecFails: true)
        service.forceSpeakerStoppedForTesting()                // a turn is open
        run(service, clock, for: 8)
        XCTAssertEqual(graph.aecAttempts, 1, "never mid-turn, however overdue")
        service.endTurnForTesting()
        run(service, clock, for: 1.2)
        XCTAssertEqual(graph.aecAttempts, 2, "runs within a second of the turn ending")
        service.stopSession()
    }

    /// L1.109g — stopping the run ends the recovery: a muted app is never
    /// rebuilt back to life, and the next start begins fresh.
    func testL1_109g_stoppingTheRunEndsTheRecovery() throws {
        let (service, graph, clock, _) = try startedService(aecFails: true)
        service.stopSession()
        clock.advance(by: 300)
        XCTAssertEqual(graph.aecAttempts, 1)
        XCTAssertEqual(clock.armedCount, 0, "nothing left ticking")
    }

    /// L1.109h — a healthy start reports nothing: no warning, nothing to clear.
    func testL1_109h_aHealthyStartIsSilent() throws {
        let (service, _, clock, reports) = try startedService(aecFails: false)
        run(service, clock, for: 30)
        XCTAssertEqual(reports.values, [])
        service.stopSession()
    }

    /// L1.109j — a retry waits for someone who has just started speaking,
    /// before their first transcript has opened a turn, and runs once the
    /// room has been quiet for the window.
    ///
    /// Fail-first: gated on an open turn alone, the retry dropped the mic in
    /// that gap.
    func testL1_109j_aRetryWaitsForSpeechThatHasNotBecomeATurnYet() throws {
        let (service, graph, clock, _) = try startedService(aecFails: true)
        var elapsed = 0.0
        while elapsed < 6 {                                    // talking, no transcript back yet
            service.noteMicBufferForTesting()
            service.noteLoudMicSampleForTesting()
            clock.advance(by: 0.1)
            elapsed += 0.1
        }
        XCTAssertEqual(graph.aecAttempts, 1, "never under someone who has started speaking")
        run(service, clock, for: EchoCancellationRecovery.speechQuietWindow + 1.2)
        XCTAssertEqual(graph.aecAttempts, 2, "runs once the room has been quiet for the window")
        service.stopSession()
    }

    /// L1.109k — a start that fails after echo cancellation failed reports
    /// nothing and leaves nothing armed: no warning over a run that never ran.
    func testL1_109k_aFailedStartPutsNoWarningUp() {
        let graph = FakeAudioGraph()
        graph.aecError = Boom()
        graph.engineError = Boom()
        let clock = ManualClock()
        let reports = Reports()
        let service = GeminiLiveTranslationService(clock: clock)
        service.audioGraphForTesting = graph
        service.sessionFactoryForTesting = { _, _ in FakeSocket() }
        XCTAssertThrowsError(try service.start(
            home: .de, partner: .en,
            onPartialInput: { _ in }, onUtterance: { _, _, _ in },
            onActivity: { _ in }, onError: { _ in },
            onEchoCancellation: { reports.values.append($0) }))
        XCTAssertEqual(reports.values, [], "a start that never ran is not degraded")
        clock.advance(by: 120)
        XCTAssertEqual(graph.aecAttempts, 1, "and nothing retries for it")
    }

    /// L1.109l — a retry that enables echo cancellation but then fails to
    /// bring the audio path up is not a recovery: the warning stays, and the
    /// chain keeps going until a retry brings the whole path back.
    func testL1_109l_aRetryThatBreaksTheEngineIsNotARecovery() throws {
        let (service, graph, clock, reports) = try startedService(aecFails: true)
        graph.aecError = nil
        graph.engineError = Boom()                             // echo cancellation fine, engine not
        run(service, clock, for: 3.2)
        XCTAssertEqual(graph.aecAttempts, 2, "the first retry ran")
        XCTAssertEqual(reports.values, [false], "not reported recovered over a dead audio path")
        graph.engineError = nil
        run(service, clock, for: 10.2)
        XCTAssertEqual(graph.aecAttempts, 3, "the chain survived the throw and tried again")
        XCTAssertEqual(reports.values, [false, true], "recovered once the whole path came up")
        service.stopSession()
    }

    // MARK: - What the person holding the phone sees

    /// L1.109i — the warning's text and severity, and its place in the one
    /// slot under the button: below "muted" and below a connection warning,
    /// above a transient mic notice.
    func testL1_109i_theWarningHasItsPlaceInTheSlot() {
        let vm = ConversationViewModel()
        vm.handleEchoCancellation(active: false)
        let echo = vm.echoWarning
        XCTAssertEqual(echo?.text, vm.strings.echoCancellationOff)
        XCTAssertEqual(echo?.severity, .degraded, "orange, like a poor connection — it still translates")

        typealias VM = ConversationViewModel
        let connection = VM.StatusNotice(text: "connection", severity: .lost)
        let notice = VM.StatusNotice(text: "notice", severity: .info)
        XCTAssertNil(VM.bottomNotice(muted: true, warning: nil, echoWarning: echo, micNotice: notice))
        XCTAssertEqual(VM.bottomNotice(muted: false, warning: connection, echoWarning: echo, micNotice: notice), connection)
        XCTAssertEqual(VM.bottomNotice(muted: false, warning: nil, echoWarning: echo, micNotice: notice), echo)
        XCTAssertEqual(VM.bottomNotice(muted: false, warning: nil, echoWarning: nil, micNotice: notice), notice)

        vm.handleEchoCancellation(active: true)
        XCTAssertNil(vm.echoWarning, "cleared when echo cancellation comes back")
    }
}
