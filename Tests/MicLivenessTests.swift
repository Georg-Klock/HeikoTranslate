import AVFoundation
import XCTest
@testable import HeikoTranslate

/// GitHub #129: the mic watchdog (#87) only guarded startup — the first
/// buffer ended its chain, so a tap that died mid-conversation was never
/// noticed and the button kept reading as listening. `MicLiveness` watches the
/// buffer count for the rest of the run; the service rebuilds on a stall and
/// gives up loudly when the rebuilds do not bring buffers back.
@MainActor
final class MicLivenessTests: XCTestCase {

    private func t(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 900_000_000 + seconds)
    }

    // MARK: - The pure rule

    /// L1.108 — before the first buffer the startup watchdog owns the case;
    /// acting here as well would rebuild a cold start twice.
    func testL1_108_nothingArrivedYetIsTheStartupWatchdogsCase() {
        var l = MicLiveness()
        XCTAssertEqual(l.check(at: t(10)), .notArmed)
        XCTAssertEqual(l.check(at: t(100)), .notArmed, "however long it has been")
    }

    /// L1.108b — a quiet room is not a stall. The rule reads buffer arrivals,
    /// which a live tap delivers regardless of loudness; nothing here takes a
    /// level at all.
    func testL1_108b_buffersArrivingKeepItHealthy() {
        var l = MicLiveness()
        var now = 0.0
        for _ in 0..<50 {
            l.noteBuffer(at: t(now))
            now += 0.09
            XCTAssertEqual(l.check(at: t(now)), .healthy)
        }
    }

    /// L1.108c — the ladder: a stall rebuilds, each rebuild gets the full
    /// threshold to deliver, and after the budget it gives up.
    func testL1_108c_aStallRebuildsTwiceThenGivesUp() {
        var l = MicLiveness()
        l.noteBuffer(at: t(0))
        XCTAssertEqual(l.check(at: t(1.9)), .healthy, "under the threshold")
        XCTAssertEqual(l.check(at: t(2.0)), .rebuild(attempt: 1))
        XCTAssertEqual(l.check(at: t(3.5)), .healthy, "the rebuilt tap gets its own grace")
        XCTAssertEqual(l.check(at: t(4.0)), .rebuild(attempt: 2))
        XCTAssertEqual(l.check(at: t(5.9)), .healthy)
        XCTAssertEqual(l.check(at: t(6.0)), .giveUp, "both rebuilds spent, still nothing")
    }

    /// L1.108d — a buffer after a rebuild ends the episode: the next stall
    /// starts from attempt 1 with the full budget again, and the recovery is
    /// reported so the log can say it.
    func testL1_108d_aBufferAfterARebuildEndsTheEpisode() {
        var l = MicLiveness()
        l.noteBuffer(at: t(0))
        XCTAssertEqual(l.check(at: t(2.0)), .rebuild(attempt: 1))
        XCTAssertTrue(l.noteBuffer(at: t(2.3)), "this buffer is a recovery")
        XCTAssertFalse(l.noteBuffer(at: t(2.4)), "later buffers are ordinary")
        XCTAssertEqual(l.check(at: t(4.4)), .rebuild(attempt: 1), "a new stall starts a new ladder")
    }

    // MARK: - The real service

    private struct Boom: Error {}

    private final class FakeAudioGraph: AudioGraphControlling {
        var events: [String] = []
        var engineError: Error?
        func activateSession() throws { events.append("activate") }
        func enableVoiceProcessing() throws { events.append("aec") }
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
        var engineStarts: Int { events.filter { $0 == "engine" }.count }
    }

    private final class FakeSocket: LiveTranslationSocket {
        func connect() {}
        func close() {}
        func sendAudio(_ pcm16kData: Data) {}
    }

    private final class GiveUps { var count = 0 }

    private func startedService() throws -> (GeminiLiveTranslationService, FakeAudioGraph, ManualClock, GiveUps) {
        let graph = FakeAudioGraph()
        let clock = ManualClock()
        let giveUps = GiveUps()
        let service = GeminiLiveTranslationService(clock: clock)
        service.audioGraphForTesting = graph
        service.sessionFactoryForTesting = { _, _ in FakeSocket() }
        try service.start(
            home: .de, partner: .en,
            onPartialInput: { _ in }, onUtterance: { _, _, _ in },
            onActivity: { _ in }, onError: { _ in },
            onMicUnrecoverable: { giveUps.count += 1 })
        return (service, graph, clock, giveUps)
    }

    /// Buffers every tenth of a second for `seconds`, advancing the clock.
    private func deliver(_ service: GeminiLiveTranslationService, _ clock: ManualClock, for seconds: TimeInterval) {
        var elapsed = 0.0
        while elapsed < seconds {
            service.noteMicBufferForTesting()
            clock.advance(by: 0.1)
            elapsed += 0.1
        }
    }

    /// L1.108e — a live mic across many seconds is never rebuilt, including
    /// through the startup watchdog's 0.5s and 3s checks.
    func testL1_108e_aLiveMicIsLeftAlone() throws {
        let (service, graph, clock, giveUps) = try startedService()
        XCTAssertEqual(graph.engineStarts, 1)
        deliver(service, clock, for: 10)
        XCTAssertEqual(graph.engineStarts, 1, "no rebuild while buffers flow")
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(giveUps.count, 0)
        service.stopSession()
    }

    /// L1.108f — the #129 case: buffers flow, then stop mid-run. The service
    /// rebuilds through the shared teardown (no second wiring, #16) and keeps
    /// running; buffers returning end the episode.
    ///
    /// Fail-first: without the mid-run check this stays at one engine start
    /// forever — the dead mic the issue describes.
    func testL1_108f_aMicThatDiesMidRunIsRebuilt() throws {
        let (service, graph, clock, giveUps) = try startedService()
        deliver(service, clock, for: 5)
        XCTAssertEqual(graph.engineStarts, 1)

        clock.advance(by: MicLiveness.stallThreshold + 1.05)   // the tap goes quiet
        XCTAssertEqual(graph.engineStarts, 2, "the stall rebuilt the audio path")
        XCTAssertEqual(graph.events.filter { $0 == "wire" }.count, 1, "the player is still wired once")
        XCTAssertTrue(service.isRunning, "a rebuild is not a stop")

        deliver(service, clock, for: 10)                         // the rebuild worked
        XCTAssertEqual(graph.engineStarts, 2, "no further rebuilds once buffers are back")
        XCTAssertEqual(giveUps.count, 0)
        service.stopSession()
    }

    /// L1.108g — when the rebuilds do not bring buffers back, give up loudly
    /// through the existing path (#87): stopped, told once, no third rebuild.
    func testL1_108g_aMicThatStaysDeadGivesUpLoudly() throws {
        let (service, graph, clock, giveUps) = try startedService()
        deliver(service, clock, for: 5)

        clock.advance(by: 30)                                    // dead for good
        XCTAssertFalse(service.isRunning, "a dead mic must not keep looking alive (R8)")
        XCTAssertEqual(giveUps.count, 1, "surfaced exactly once")
        XCTAssertEqual(graph.engineStarts, 1 + MicLiveness.maxRebuilds, "the budget, and not one more")
        XCTAssertEqual(clock.armedCount, 0, "nothing left ticking after the give-up")
    }

    /// L1.108h — stopping the run stops the watch: a muted app is silent by
    /// design and must never be "rebuilt" back to life.
    func testL1_108h_aStoppedRunIsNotWatched() throws {
        let (service, graph, clock, giveUps) = try startedService()
        deliver(service, clock, for: 3)
        service.stopSession()
        clock.advance(by: 60)
        XCTAssertEqual(graph.engineStarts, 1)
        XCTAssertEqual(giveUps.count, 0)
        XCTAssertEqual(clock.armedCount, 0)
    }
}
