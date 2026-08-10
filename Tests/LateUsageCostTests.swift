import XCTest
@testable import HeikoTranslate

/// GitHub #4: usage frames in flight at a teardown were dropped by the
/// registry token check before `handle()` could record them, while the dead
/// else-branch in `handle()` read as if they were being kept. Cost is now
/// recorded in the session callback, ahead of the token check — the one
/// recording point — so a mute or a goAway renewal no longer loses the
/// frames it had in flight, and a current session's frame is not counted
/// twice.
///
/// These drive the REAL callback route: the fakes hold the same event
/// closure a real session would own, token check included.
@MainActor
final class LateUsageCostTests: XCTestCase {

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

    /// The measured `usageMetadata` shape (CostTracker's doc comment), with
    /// the growing TEXT context that must stay excluded.
    private func usageFrame(input: Int, output: Int) -> [String: Any] {
        [
            "promptTokenCount": input,
            "promptTokensDetails": [
                ["modality": "TEXT", "tokenCount": 581],
                ["modality": "AUDIO", "tokenCount": input],
            ],
            "responseTokenCount": output,
            "responseTokensDetails": [["modality": "AUDIO", "tokenCount": output]],
            "totalTokenCount": input + output,
        ]
    }

    private func drain() async { for _ in 0..<25 { await Task.yield() } }

    private func startedService() throws -> (GeminiLiveTranslationService, Sockets) {
        let sockets = Sockets()
        let service = GeminiLiveTranslationService()
        service.skipAudioIOForTesting = true
        service.sessionFactoryForTesting = { lang, onEvent in
            let fake = FakeSocket(onEvent: onEvent)
            sockets.current[lang] = fake
            return fake
        }
        try service.start(
            home: .de, partner: .en,
            onPartialInput: { _ in }, onUtterance: { _, _, _ in },
            onActivity: { _ in }, onError: { _ in })
        return (service, sockets)
    }

    // A usage frame still in flight when the run stops must be counted:
    // billing happened whether or not the session is still current.
    func testUsageArrivingAfterStopStillCounts() async throws {
        let (service, sockets) = try startedService()
        let en = sockets.current[.en]!
        let inputBefore = CostTracker.shared.audioInputTokens
        let outputBefore = CostTracker.shared.audioOutputTokens

        service.stopSession()          // clears the registry — the token is stale
        en.onEvent(.usage(usageFrame(input: 25, output: 50)))
        await drain()

        XCTAssertEqual(CostTracker.shared.audioInputTokens, inputBefore + 25,
                       "the teardown must not lose the frame that was in flight")
        XCTAssertEqual(CostTracker.shared.audioOutputTokens, outputBefore + 50)
    }

    // A current session's frame is counted exactly once — the recording
    // moved, it did not gain a second site.
    func testCurrentUsageCountsExactlyOnce() async throws {
        let (service, sockets) = try startedService()
        let en = sockets.current[.en]!
        let before = CostTracker.shared.audioInputTokens

        en.onEvent(.usage(usageFrame(input: 25, output: 0)))
        await drain()

        XCTAssertEqual(CostTracker.shared.audioInputTokens, before + 25,
                       "one frame, one tally — not two")
        service.stopSession()
    }

    // A superseded instance's frame (goAway renewal replaced it) counts too.
    func testSupersededSessionsUsageCounts() async throws {
        let (service, sockets) = try startedService()
        let firstEN = sockets.current[.en]!
        firstEN.onEvent(.closed(expected: true))   // replaced; token superseded
        await drain()
        let before = CostTracker.shared.audioInputTokens

        firstEN.onEvent(.usage(usageFrame(input: 25, output: 0)))
        await drain()

        XCTAssertEqual(CostTracker.shared.audioInputTokens, before + 25,
                       "the replaced instance's last frames were still billed")
        service.stopSession()
    }
}
