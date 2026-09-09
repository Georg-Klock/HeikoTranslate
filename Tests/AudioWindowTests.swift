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
}
