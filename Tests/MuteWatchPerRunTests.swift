import XCTest
@testable import HeikoTranslate

/// The mute-session reconnect (#139/#140) kept its state for the life of the
/// process instead of the run: the reconnect budget, and the per-session
/// content and ready clocks it judges against. Found reading the service for
/// #134. These drive the real service through fake sockets on `ManualClock`.
@MainActor
final class MuteWatchPerRunTests: XCTestCase {

    private final class FakeSocket: LiveTranslationSocket {
        let onEvent: (GeminiLiveSession.Event) -> Void
        init(onEvent: @escaping (GeminiLiveSession.Event) -> Void) { self.onEvent = onEvent }
        func connect() {}
        func close() {}
        func sendAudio(_ pcm16kData: Data) {}
    }

    private final class Sockets {
        var current: [TurnLogic.Lang: FakeSocket] = [:]
        var made: [TurnLogic.Lang: Int] = [:]
    }

    private let clock = ManualClock()

    private func drain() async { for _ in 0..<25 { await Task.yield() } }

    private func service() -> (GeminiLiveTranslationService, Sockets) {
        let sockets = Sockets()
        let service = GeminiLiveTranslationService(clock: clock)
        service.skipAudioIOForTesting = true
        service.sessionFactoryForTesting = { lang, onEvent in
            let fake = FakeSocket(onEvent: onEvent)
            sockets.current[lang] = fake
            sockets.made[lang, default: 0] += 1
            return fake
        }
        return (service, sockets)
    }

    private func start(_ service: GeminiLiveTranslationService, _ sockets: Sockets) async throws {
        try service.start(home: .de, partner: .en,
                          onPartialInput: { _ in }, onUtterance: { _, _, _ in },
                          onActivity: { _ in }, onError: { _ in })
        sockets.current[.de]?.onEvent(.setupComplete)
        sockets.current[.en]?.onEvent(.setupComplete)
        await drain()
    }

    /// One session transcribes; the other says nothing.
    private func only(_ lang: TurnLogic.Lang, _ sockets: Sockets, says text: String) async {
        sockets.current[lang]?.onEvent(.inputTranscript(text))
        await drain()
    }

    /// L1.115 — after a pause, a fresh run's first transcript does not get
    /// the other session reconnected.
    ///
    /// Fail-first: with the previous run's content clock kept, the home
    /// session reads as silent for a minute and is replaced on the first beat
    /// after the partner speaks — mid-turn, on a healthy connection.
    func testL1_115_aFreshRunIsNotJudgedByThePreviousRunsSilence() async throws {
        let (service, sockets) = service()
        try await start(service, sockets)
        await only(.de, sockets, says: "Guten Tag")
        await only(.en, sockets, says: "Good day")
        service.stopSession()

        clock.advance(by: 60)                                   // a pause between runs
        try await start(service, sockets)
        let deBefore = sockets.made[.de, default: 0]
        clock.advance(by: 1)
        await only(.en, sockets, says: "Hello there")           // the partner's first words
        service.checkForMuteSessionForTesting()
        await drain()

        XCTAssertEqual(sockets.made[.de, default: 0], deBefore,
                       "a session one second into its run is not mute")
        service.stopSession()
    }

    /// L1.115b — the reconnect budget is per run. A language that spent both
    /// reconnects in one run is watched again in the next.
    ///
    /// Fail-first: with the budget kept for the process, the second run's
    /// genuinely mute session is never reconnected.
    func testL1_115b_theReconnectBudgetIsPerRun() async throws {
        let (service, sockets) = service()

        // Run 1: `de` goes mute twice while `en` keeps talking, spending the budget.
        try await start(service, sockets)
        for _ in 0..<SessionLiveness.maxReconnects {
            for _ in 0..<Int(SessionLiveness.muteLimit) + 2 {
                clock.advance(by: 1)
                await only(.en, sockets, says: "still talking")
            }
            let before = sockets.made[.de, default: 0]
            service.checkForMuteSessionForTesting()
            await drain()
            XCTAssertEqual(sockets.made[.de, default: 0], before + 1, "precondition: run 1 reconnects the mute session")
            sockets.current[.de]?.onEvent(.setupComplete)
            await drain()
        }
        service.stopSession()

        // Run 2: `de` is mute again.
        clock.advance(by: 30)
        try await start(service, sockets)
        for _ in 0..<Int(SessionLiveness.muteLimit) + 2 {
            clock.advance(by: 1)
            await only(.en, sockets, says: "talking in a new run")
        }
        let before = sockets.made[.de, default: 0]
        service.checkForMuteSessionForTesting()
        await drain()
        XCTAssertEqual(sockets.made[.de, default: 0], before + 1,
                       "a fresh run has a fresh budget — a mute session is still recovered")
        service.stopSession()
    }
}
