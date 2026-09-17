import AVFoundation
import XCTest
@testable import HeikoTranslate

/// GitHub #160: the tap hands each buffer to the main actor in unstructured
/// tasks, and those tasks used to check only `isRunning`. A buffer the tap had
/// already delivered when its tap was removed — by a stop, or by a rebuild —
/// was still queued when the next tap went live, and was counted as the NEW
/// tap's: it satisfied the startup watchdog, fed the mid-run liveness clock
/// and entered the new run's audio. Each installed tap now carries a
/// generation, and a buffer from a superseded one is dropped on arrival.
///
/// These drive the real tap block: the graph double keeps the block the
/// service installs and calls it with a real `AVAudioPCMBuffer`, the way the
/// render thread would, without yielding — so the main-actor hops are queued
/// behind whatever the test does next, exactly the window the issue names.
@MainActor
final class StaleTapBufferTests: XCTestCase {

    private final class CapturingAudioGraph: AudioGraphControlling {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        private(set) var tap: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
        private(set) var starts = 0
        func activateSession() throws {}
        func enableVoiceProcessing() throws {}
        func wirePlayer() {}
        func startEngine() throws { starts += 1 }
        func inputFormat() -> AVAudioFormat { format }
        func installTap(_ block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) { tap = block }
        func removeTap() { tap = nil }
        func startPlayback() {}
        func stopPlaybackAndEngine() {}
        func deactivateSession() {}
    }

    private final class FakeSocket: LiveTranslationSocket {
        let onEvent: (GeminiLiveSession.Event) -> Void
        var sent: [Data] = []
        init(onEvent: @escaping (GeminiLiveSession.Event) -> Void) { self.onEvent = onEvent }
        func connect() {}
        func close() {}
        func sendAudio(_ pcm16kData: Data) { sent.append(pcm16kData) }
    }
    private final class Sockets { var current: [TurnLogic.Lang: FakeSocket] = [:] }

    private func makeService(_ graph: CapturingAudioGraph, _ clock: ManualClock,
                             _ sockets: Sockets = Sockets()) -> GeminiLiveTranslationService {
        let service = GeminiLiveTranslationService(clock: clock)
        service.audioGraphForTesting = graph
        service.sessionFactoryForTesting = { lang, onEvent in
            let fake = FakeSocket(onEvent: onEvent); sockets.current[lang] = fake; return fake
        }
        return service
    }

    private func start(_ service: GeminiLiveTranslationService) throws {
        try service.start(home: .de, partner: .en,
                          onPartialInput: { _ in }, onUtterance: { _, _, _ in },
                          onActivity: { _ in }, onError: { _ in })
    }

    /// One silent 1024-frame buffer through the tap block the service
    /// installed — conversion, the render-thread half, and the two queued
    /// main-actor hops — with no yield, so the hops have not run yet.
    private func deliverQueued(through tap: (AVAudioPCMBuffer, AVAudioTime) -> Void,
                               format: AVAudioFormat) throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        if let samples = buffer.floatChannelData?[0] {
            samples.update(repeating: 0, count: 1024)
        }
        tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48000))
    }

    private func drain() async { for _ in 0..<25 { await Task.yield() } }

    /// L1.125 — the issue's case. Run one's tap delivers a buffer; before its
    /// hops run, the app is stopped and started again; run two's tap is dead.
    /// The old buffer must not count as run two's first: its 0.5s watchdog
    /// still rebuilds.
    ///
    /// Fail-first: before the fix `starts` stays at 2 — the stale buffer told
    /// the watchdog the new microphone was alive.
    func testL1_125_aBufferFromAStoppedRunCannotSatisfyTheNextRunsWatchdog() async throws {
        let graph = CapturingAudioGraph()
        let clock = ManualClock()
        let service = makeService(graph, clock)
        try start(service)
        let oldTap = try XCTUnwrap(graph.tap)
        try deliverQueued(through: oldTap, format: graph.format)

        service.stopSession()
        try start(service)
        await drain()
        clock.advance(by: 0.6)

        XCTAssertEqual(graph.starts, 3, "run two received no buffer of its own, so its watchdog must rebuild")
        service.stopSession()
    }

    /// L1.125b — the same stale buffer does not enter run two's audio. Before
    /// the sessions are ready the tap holds audio for them, and that hold is
    /// flushed on connect: a buffer from the stopped run would have been sent
    /// as the new run's first speech (R4, R6).
    ///
    /// Fail-first: before the fix each session receives the old chunk.
    func testL1_125b_aBufferFromAStoppedRunDoesNotReachTheNextRunsSessions() async throws {
        let graph = CapturingAudioGraph()
        let clock = ManualClock()
        let sockets = Sockets()
        let service = makeService(graph, clock, sockets)
        try start(service)
        let oldTap = try XCTUnwrap(graph.tap)
        try deliverQueued(through: oldTap, format: graph.format)

        service.stopSession()
        try start(service)
        await drain()
        sockets.current[.de]?.onEvent(.setupComplete)
        sockets.current[.en]?.onEvent(.setupComplete)
        await drain()

        XCTAssertEqual(sockets.current[.de]?.sent.count, 0, "run one's audio is not run two's speech")
        XCTAssertEqual(sockets.current[.en]?.sent.count, 0)
        service.stopSession()
    }

    /// L1.125c — within a run. The first tap's buffer is still queued when the
    /// 0.5s watchdog rebuilds the path (#87); it must not be counted as the
    /// rebuilt tap's, so a rebuilt tap that is also dead is rebuilt again.
    ///
    /// Fail-first: before the fix the second check sees one buffer and leaves
    /// the dead rebuilt tap alone.
    func testL1_125c_aBufferFromTheTornDownTapCannotSatisfyTheStartupWatchdog() async throws {
        let graph = CapturingAudioGraph()
        let clock = ManualClock()
        let service = makeService(graph, clock)
        try start(service)
        let firstTap = try XCTUnwrap(graph.tap)
        try deliverQueued(through: firstTap, format: graph.format)

        clock.advance(by: 0.55)                       // the watchdog fires before the hop runs
        XCTAssertEqual(graph.starts, 2, "no buffer counted yet: rebuilt")
        await drain()                                 // the first tap's buffer arrives now
        clock.advance(by: 0.5)

        XCTAssertEqual(graph.starts, 3, "the rebuilt tap delivered nothing of its own")
        service.stopSession()
    }

    /// L1.125d — the mid-run liveness clock (#129) across its own rebuild. A
    /// buffer the torn-down tap delivered lands after the rebuild; it must
    /// not move the stall clock, or a dead rebuilt tap gets a fresh threshold
    /// from a buffer it never produced. The hop is held back 1.5s here so the
    /// effect is a whole check rather than a fraction of one — on device the
    /// delay is however long the main actor is busy, the rebuild's own engine
    /// start included.
    ///
    /// Fail-first: before the fix the second rebuild is postponed past the
    /// check that should run it.
    func testL1_125d_aBufferFromTheTornDownTapCannotFeedMicLiveness() async throws {
        let graph = CapturingAudioGraph()
        let clock = ManualClock()
        let service = makeService(graph, clock)
        try start(service)
        for _ in 0..<30 {                             // a live tap: the watch is armed
            let tap = try XCTUnwrap(graph.tap)
            try deliverQueued(through: tap, format: graph.format)
            await drain()
            clock.advance(by: 0.1)
        }
        XCTAssertEqual(graph.starts, 1)

        let firstTap = try XCTUnwrap(graph.tap)
        try deliverQueued(through: firstTap, format: graph.format)   // queued, then the tap goes quiet
        clock.advance(by: MicLiveness.stallThreshold + 0.05)
        XCTAssertEqual(graph.starts, 2, "the stall rebuilt the path")

        clock.advance(by: 1.45)                       // 1.5s after the rebuild
        await drain()                                 // the torn-down tap's buffer arrives now
        clock.advance(by: 0.55)                       // the check at the rebuilt tap's full threshold

        XCTAssertEqual(graph.starts, 3, "the rebuilt tap delivered nothing of its own: rebuild again")
        XCTAssertTrue(service.isRunning)
        service.stopSession()
    }
}
