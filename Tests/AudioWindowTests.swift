import AVFoundation
import XCTest
@testable import HeikoTranslate

/// GitHub #131: the audio windows are stated in seconds and sized from the
/// chunk the tap actually delivers, not from a 64ms chunk it never did.
@MainActor
final class AudioWindowTests: XCTestCase {

    /// L1.107 — the arithmetic, at the chunk sizes that matter: the assumed
    /// 64ms (the old constants exactly), 1024 frames at 48kHz (the issue's
    /// 21ms), and 4096 at 48kHz (the ~85ms the 2026-08-18 logs suggest).
    func testL1_107_windowsAreSizedFromTheChunk() {
        XCTAssertEqual(AudioWindow.chunks(spanning: 3.2, chunkDuration: 0.064), 50, "the old replacement cap")
        XCTAssertEqual(AudioWindow.chunks(spanning: 16, chunkDuration: 0.064), 250, "the old launch cap")
        XCTAssertEqual(AudioWindow.chunks(spanning: 3.2, chunkDuration: 1024.0 / 48000), 150)
        XCTAssertEqual(AudioWindow.chunks(spanning: 3.2, chunkDuration: 4096.0 / 48000), 38)
        XCTAssertEqual(AudioWindow.chunks(spanning: 3.2, chunkDuration: 0), 50, "a bad duration falls back, never divides")
        XCTAssertEqual(AudioWindow.chunks(spanning: 0.001, chunkDuration: 1), 1, "never fewer than one chunk")
        XCTAssertNil(AudioWindow.chunkDuration(frames: 0, sampleRate: 48000))
        XCTAssertEqual(AudioWindow.chunkDuration(frames: 1024, sampleRate: 16000)!, 0.064, accuracy: 1e-9)
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

    private func drain() async { for _ in 0..<25 { await Task.yield() } }

    /// L1.107b — the service's windows follow the reported chunk, once per
    /// audio path, and the replacement queue really rolls at the new cap.
    func testL1_107b_theReplacementQueueRollsAtTheMeasuredCap() async throws {
        let sockets = Sockets()
        let service = GeminiLiveTranslationService(clock: ManualClock())
        service.skipAudioIOForTesting = true
        service.sessionFactoryForTesting = { lang, onEvent in
            let fake = FakeSocket(onEvent: onEvent); sockets.current[lang] = fake; return fake
        }
        try service.start(home: .de, partner: .en,
                          onPartialInput: { _ in }, onUtterance: { _, _, _ in },
                          onActivity: { _ in }, onError: { _ in })
        XCTAssertEqual(service.replacementWindowChunksForTesting, 50, "before any buffer: the old constant")
        XCTAssertEqual(service.pendingWindowChunksForTesting, 250)

        service.noteMicChunkShapeForTesting(frames: 4096, sampleRate: 48000)
        XCTAssertEqual(service.replacementWindowChunksForTesting, 38)
        XCTAssertEqual(service.pendingWindowChunksForTesting, 188)
        service.noteMicChunkShapeForTesting(frames: 1024, sampleRate: 48000)
        XCTAssertEqual(service.replacementWindowChunksForTesting, 38, "measured once per audio path — a later buffer does not re-size")

        sockets.current[.de]?.onEvent(.setupComplete)
        sockets.current[.en]?.onEvent(.setupComplete)
        await drain()
        sockets.current[.en]?.onEvent(.closed(expected: true))   // open a replacement window
        await drain()
        let replacement = sockets.current[.en]!
        for i in 0..<60 { service.forward(Data([UInt8(i)])) }
        replacement.onEvent(.setupComplete)
        await drain()
        XCTAssertEqual(replacement.sent.count, 38, "the rolling window is the measured 3.2s, not 50 chunks")
        XCTAssertEqual(replacement.sent.first, Data([22]), "newest chunks win")
        service.stopSession()
    }

    // MARK: - Once per audio path, not once per service (#158)

    private final class FakeAudioGraph: AudioGraphControlling {
        var events: [String] = []
        func activateSession() throws { events.append("activate") }
        func enableVoiceProcessing() throws { events.append("aec") }
        func wirePlayer() { events.append("wire") }
        func startEngine() throws { events.append("engine") }
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

    private func start(_ service: GeminiLiveTranslationService) throws {
        try service.start(home: .de, partner: .en,
                          onPartialInput: { _ in }, onUtterance: { _, _, _ in },
                          onActivity: { _ in }, onError: { _ in })
    }

    /// L1.124 — a new run starts unmeasured. The service outlives a run (the
    /// view model reuses it across every mute/unmute), and the measurement
    /// used to outlive it too: run two on a 1024-frame path kept run one's
    /// 38-chunk cap — 0.8s across a reconnect instead of 3.2s — and never
    /// measured its own chunk.
    ///
    /// Fail-first: before the fix the second start reads 38/188, not 50/250.
    func testL1_124_aNewRunMeasuresItsOwnChunk() throws {
        let service = GeminiLiveTranslationService(clock: ManualClock())
        service.skipAudioIOForTesting = true
        service.sessionFactoryForTesting = { _, onEvent in FakeSocket(onEvent: onEvent) }
        try start(service)
        service.noteMicChunkShapeForTesting(frames: 4096, sampleRate: 48000)
        XCTAssertEqual(service.replacementWindowChunksForTesting, 38)
        service.stopSession()

        try start(service)
        XCTAssertEqual(service.replacementWindowChunksForTesting, 50,
                       "before run two's first buffer: the fallback, not run one's measurement")
        XCTAssertEqual(service.pendingWindowChunksForTesting, 250)
        service.noteMicChunkShapeForTesting(frames: 1024, sampleRate: 48000)
        XCTAssertEqual(service.replacementWindowChunksForTesting, 150, "run two's own 3.2s")
        XCTAssertEqual(service.pendingWindowChunksForTesting, 750, "run two's own 16s")
        service.stopSession()
    }

    /// L1.124b — a rebuild within a run is a new tap, and a new tap can land
    /// on a new route: its first buffer measures again. The caps it already
    /// has stay until then, because a rebuild can happen while a replacement
    /// queue is holding speech that a fallback cap would cut.
    ///
    /// Fail-first: before the fix the rebuilt path's 1024-frame chunk is
    /// ignored and the cap stays at 38.
    func testL1_124b_aRebuiltTapMeasuresAgain() throws {
        let graph = FakeAudioGraph()
        let clock = ManualClock()
        let service = GeminiLiveTranslationService(clock: clock)
        service.audioGraphForTesting = graph
        service.sessionFactoryForTesting = { _, onEvent in FakeSocket(onEvent: onEvent) }
        try start(service)
        service.noteMicChunkShapeForTesting(frames: 4096, sampleRate: 48000)
        for _ in 0..<30 { service.noteMicBufferForTesting(); clock.advance(by: 0.1) }
        XCTAssertEqual(graph.engineStarts, 1)

        clock.advance(by: MicLiveness.stallThreshold + 1.05)   // the tap goes quiet: #129 rebuilds
        XCTAssertEqual(graph.engineStarts, 2, "the stall rebuilt the audio path")
        XCTAssertEqual(service.replacementWindowChunksForTesting, 38,
                       "a rebuild keeps the caps it has until the new tap reports")

        service.noteMicChunkShapeForTesting(frames: 1024, sampleRate: 48000)
        XCTAssertEqual(service.replacementWindowChunksForTesting, 150, "the rebuilt tap's own chunk")
        XCTAssertEqual(service.pendingWindowChunksForTesting, 750)
        service.stopSession()
    }
}
