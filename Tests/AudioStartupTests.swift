import AVFoundation
import XCTest
@testable import HeikoTranslate

/// GitHub #16: every `startAudioIO()` re-attached and re-connected the same
/// player node (nothing documents that as safe, and the watchdog rebuild plus
/// every mute/unmute did it), and a failure partway through startup threw
/// without teardown — the next attempt inherited a half-configured graph and
/// an activated audio session. The choreography now runs against the
/// `AudioGraphControlling` seam, so ordering, the once-only wiring and the
/// rollback are pinned as deterministic cases; sessions are faked at the
/// `LiveTranslationSocket` seam so no test touches the network.
@MainActor
final class AudioStartupTests: XCTestCase {

    private struct Boom: Error {}

    private final class FakeAudioGraph: AudioGraphControlling {
        var events: [String] = []
        var activateError: Error?
        var aecError: Error?
        var engineError: Error?
        var reportedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

        func activateSession() throws { events.append("activate"); if let e = activateError { throw e } }
        func enableVoiceProcessing() throws { events.append("aec"); if let e = aecError { throw e } }
        func wirePlayer() { events.append("wire") }
        func startEngine() throws { events.append("engine"); if let e = engineError { throw e } }
        func inputFormat() -> AVAudioFormat { reportedFormat }
        func installTap(_ block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) { events.append("tap") }
        func removeTap() { events.append("removeTap") }
        func startPlayback() { events.append("play") }
        func stopPlaybackAndEngine() { events.append("stopEngine") }
        func deactivateSession() { events.append("deactivate") }
    }

    private final class FakeSocket: LiveTranslationSocket {
        func connect() {}
        func close() {}
        func sendAudio(_ pcm16kData: Data) {}
    }

    private func makeService(graph: FakeAudioGraph) -> GeminiLiveTranslationService {
        let service = GeminiLiveTranslationService()
        service.audioGraphForTesting = graph
        service.sessionFactoryForTesting = { _, _ in FakeSocket() }
        return service
    }

    private func start(_ service: GeminiLiveTranslationService) throws {
        try service.start(
            home: .de, partner: .en,
            onPartialInput: { _ in }, onUtterance: { _, _, _ in },
            onActivity: { _ in }, onError: { _ in })
    }

    // The ownership model: attach/connect happen exactly once per engine
    // lifetime, however many stop/start cycles run.
    func testStartStopStartWiresThePlayerOnce() throws {
        let graph = FakeAudioGraph()
        let service = makeService(graph: graph)

        try start(service)
        XCTAssertEqual(graph.events, ["activate", "aec", "wire", "engine", "tap", "play"],
                       "the documented order: session, AEC, wiring, engine, tap, playback")

        service.stopSession()
        XCTAssertEqual(Array(graph.events.suffix(3)), ["removeTap", "stopEngine", "deactivate"],
                       "stop removes the tap it installed and gives the session back")

        try start(service)
        XCTAssertEqual(graph.events.filter { $0 == "wire" }.count, 1,
                       "the player is wired once for the engine's lifetime, not once per start")
        XCTAssertEqual(graph.events.filter { $0 == "tap" }.count, 2,
                       "the tap, unlike the wiring, cycles with every start")
    }

    // An engine-start failure unwinds through the shared teardown: no tap,
    // no playback, session deactivated — and the next attempt works.
    func testEngineFailureRollsBackAndTheNextStartSucceeds() throws {
        let graph = FakeAudioGraph()
        let service = makeService(graph: graph)
        graph.engineError = Boom()

        XCTAssertThrowsError(try start(service))
        XCTAssertEqual(graph.events, ["activate", "aec", "wire", "engine", "stopEngine", "deactivate"],
                       "a failed start tears down what it built — no tap, no playback, no active session left")
        XCTAssertFalse(service.isRunning)

        graph.engineError = nil
        try start(service)
        XCTAssertEqual(graph.events.filter { $0 == "wire" }.count, 1,
                       "the wiring survives the rollback — it belongs to the engine, not the attempt")
        XCTAssertEqual(graph.events.last, "play")
    }

    // A converter failure (the placeholder 0 Hz format a cold launch can
    // report) rolls back the same way instead of leaving the session active.
    func testConverterFailureRollsBack() {
        let graph = FakeAudioGraph()
        let service = makeService(graph: graph)
        graph.reportedFormat = AVAudioFormat()

        XCTAssertThrowsError(try start(service))
        XCTAssertEqual(Array(graph.events.suffix(2)), ["stopEngine", "deactivate"],
                       "the throw unwinds through the same teardown the normal stop uses")
        XCTAssertFalse(graph.events.contains("tap"), "no tap was installed, so none may linger")
    }

    // AEC failing is logged, not fatal — the app runs full-duplex without it
    // rather than not at all (that decision predates this fix; pinned so the
    // transaction cannot silently change it).
    func testAECFailureIsNonFatal() throws {
        let graph = FakeAudioGraph()
        let service = makeService(graph: graph)
        graph.aecError = Boom()

        try start(service)
        XCTAssertEqual(graph.events.last, "play")
        XCTAssertFalse(graph.events.contains("deactivate"))
    }

    // GitHub #87 / L1.68f: the watchdog's exhausted case. Two rebuilds that
    // both come up dead used to end as a silent no-op — `isRunning` stayed
    // true, the button read as listening, and speaking did nothing, the
    // exact state R8 forbids. The third strike must give up LOUDLY: the one
    // shared teardown, exactly once, the callback fired, the run over.
    func testWatchdogExhaustionGivesUpLoudly() throws {
        let graph = FakeAudioGraph()
        let service = makeService(graph: graph)
        var giveUps = 0
        try service.start(
            home: .de, partner: .en,
            onPartialInput: { _ in }, onUtterance: { _, _, _ in },
            onActivity: { _ in }, onError: { _ in },
            onMicUnrecoverable: { giveUps += 1 })

        // Two checks with zero buffers: the two measured rebuild attempts,
        // which #87 deliberately does not touch.
        service.fireMicWatchdogForTesting()
        service.fireMicWatchdogForTesting()
        XCTAssertEqual(graph.events.filter { $0 == "engine" }.count, 3,
                       "the initial start plus exactly two rebuilds")
        XCTAssertTrue(service.isRunning,
                      "mid-recovery the run stays up — the rebuilds are the fix, not the verdict")
        XCTAssertEqual(giveUps, 0, "no verdict while attempts remain")

        // The third check finds the rebuilds spent and the tap still silent.
        let beforeGiveUp = graph.events.count
        service.fireMicWatchdogForTesting()

        XCTAssertFalse(service.isRunning,
                       "a dead mic with no rebuilds left must not keep looking alive (R8)")
        XCTAssertEqual(giveUps, 1, "the give-up is surfaced, exactly once")
        XCTAssertEqual(Array(graph.events.dropFirst(beforeGiveUp)),
                       ["removeTap", "stopEngine", "deactivate"],
                       "the give-up is the shared teardown exactly once — no third rebuild, no partial stop")
    }

    // GitHub #87 / L1.68g: the companion — one buffer before the next check
    // proves the mic alive, and the exhausted cap must not become a hair
    // trigger that kills a session whose rebuild just worked.
    func testABufferAfterARebuildKeepsTheSessionAlive() throws {
        let graph = FakeAudioGraph()
        let service = makeService(graph: graph)
        var giveUps = 0
        try service.start(
            home: .de, partner: .en,
            onPartialInput: { _ in }, onUtterance: { _, _, _ in },
            onActivity: { _ in }, onError: { _ in },
            onMicUnrecoverable: { giveUps += 1 })

        service.fireMicWatchdogForTesting()   // rebuild 1 — still silent
        service.noteMicBufferForTesting()     // the rebuild worked: a buffer lands
        let eventsAfterRecovery = graph.events.count

        service.fireMicWatchdogForTesting()   // would have been rebuild 2
        service.fireMicWatchdogForTesting()   // would have been the give-up

        XCTAssertTrue(service.isRunning, "a live mic ends the watchdog's business")
        XCTAssertEqual(giveUps, 0, "no give-up for a mic that recovered")
        XCTAssertEqual(graph.events.count, eventsAfterRecovery,
                       "no further rebuilds and no teardown — the checks are no-ops once buffers flow")
        service.stopSession()
    }

    // GitHub #87 / L1.68h: what the give-up looks like to the person holding
    // the phone — the button returns to tap-to-start and the EXISTING
    // reviewed sentence explains why, the same pairing the failed automatic
    // resume uses (GitHub #5). No new user-facing copy.
    func testTheGiveUpReturnsTheButtonToTapToStartWithTheReviewedSentence() {
        let vm = ConversationViewModel()
        vm.forceListeningForTesting()
        XCTAssertTrue(vm.isListening, "precondition: the button reads as listening")

        vm.forceMicUnrecoverableForTesting()

        XCTAssertFalse(vm.isListening, "the button is back at tap-to-start — no dead end (R8)")
        XCTAssertEqual(vm.errorMessage, vm.strings.micResumeFailed,
                       "the existing reviewed sentence — actionable, and honest about what happened")
        XCTAssertNil(vm.startHint,
                     "L1.32's rule holds here too: no tap-to-speak hint beside an error")
    }

    // The 0.5s mic watchdog rebuild takes exactly the same safe path: shared
    // teardown, then a restart that does not re-wire the player.
    func testWatchdogRebuildFollowsTheSameSafePath() async throws {
        let graph = FakeAudioGraph()
        let service = makeService(graph: graph)
        try start(service)

        // No mic buffers arrive from a fake graph, so the 0.5s watchdog
        // rebuilds — which is exactly the path under test.
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(graph.events.filter { $0 == "engine" }.count >= 2,
                      "the watchdog rebuilt the audio path")
        XCTAssertEqual(graph.events.filter { $0 == "wire" }.count, 1,
                      "the rebuild follows the same once-only wiring rule")
        let rebuildStart = graph.events.dropFirst(6)
        XCTAssertEqual(Array(rebuildStart.prefix(3)), ["removeTap", "stopEngine", "deactivate"],
                      "the rebuild goes through the shared teardown first")
        service.stopSession()
    }
}
