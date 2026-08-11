import XCTest
@testable import HeikoTranslate

/// GitHub #15: on every session renewal — the routine goAway after ~9
/// minutes, or an abrupt drop — the replacement WebSocket was fed mic audio
/// the moment it was created, before its own `setupComplete`, because the
/// sending paths selected on "not dead" while `reconnect` never cleared
/// readiness. These drive the REAL service — `start()`, the event handler,
/// `forward(_:)`, `reconnect` — with the sessions faked at the
/// `LiveTranslationSocket` seam; a fake's events go through the shipping
/// route, registry token check included.
@MainActor
final class ReplacementWindowTests: XCTestCase {

    private final class FakeSocket: LiveTranslationSocket {
        let onEvent: (GeminiLiveSession.Event) -> Void
        var connected = 0
        var closedCalls = 0
        var sent: [Data] = []
        init(onEvent: @escaping (GeminiLiveSession.Event) -> Void) {
            self.onEvent = onEvent
        }
        func connect() { connected += 1 }
        func close() { closedCalls += 1 }
        func sendAudio(_ pcm16kData: Data) { sent.append(pcm16kData) }
    }

    /// Holds the current fake per language; the factory replaces entries as
    /// the service replaces sessions.
    private final class Sockets {
        var current: [TurnLogic.Lang: FakeSocket] = [:]
    }

    private func chunk(_ n: Int) -> Data { Data([UInt8(n % 256), UInt8(n / 256)]) }

    private func drain() async {
        for _ in 0..<25 { await Task.yield() }
    }

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

    private func bringUp(_ sockets: Sockets) async {
        sockets.current[.de]?.onEvent(.setupComplete)
        sockets.current[.en]?.onEvent(.setupComplete)
        await drain()
    }

    // The goAway renewal: the replacement receives NOTHING before its own
    // setupComplete, then the held chunks exactly once, in order, then live.
    func testRenewalReceivesNoAudioBeforeItsOwnSetup() async throws {
        let (service, sockets) = try startedService()
        await bringUp(sockets)
        let firstEN = sockets.current[.en]!

        service.forward(chunk(1))
        XCTAssertEqual(firstEN.sent, [chunk(1)], "sanity: live forwarding reaches a ready session")

        firstEN.onEvent(.closed(expected: true))   // the routine goAway
        await drain()
        let replacement = sockets.current[.en]!
        XCTAssertTrue(replacement !== firstEN, "the goAway session must be replaced")
        XCTAssertGreaterThan(firstEN.closedCalls, 0, "the predecessor is closed, not orphaned")
        XCTAssertEqual(replacement.connected, 1)

        service.forward(chunk(2))
        service.forward(chunk(3))
        XCTAssertEqual(replacement.sent, [],
                       "no realtimeInput before the replacement's own setupComplete")
        XCTAssertEqual(sockets.current[.de]!.sent, [chunk(1), chunk(2), chunk(3)],
                       "the other side of the pair keeps streaming live")

        replacement.onEvent(.setupComplete)
        await drain()
        XCTAssertEqual(replacement.sent, [chunk(2), chunk(3)],
                       "held chunks arrive exactly once, oldest first")

        service.forward(chunk(4))
        XCTAssertEqual(replacement.sent, [chunk(2), chunk(3), chunk(4)],
                       "live forwarding resumes after the flush")
    }

    // The abrupt-drop path gates the same way — including the window BEFORE
    // the delayed reconnect creates the replacement, while the closed
    // session object is still in the table.
    func testAbruptDropAlsoGates() async throws {
        let (service, sockets) = try startedService()
        await bringUp(sockets)
        let firstEN = sockets.current[.en]!
        service.forward(chunk(1))

        firstEN.onEvent(.closed(expected: false))  // transport dropped
        await drain()

        service.forward(chunk(2))
        XCTAssertEqual(firstEN.sent, [chunk(1)],
                       "a closed session must not be fed while its reconnect waits out the cooldown")

        // The first drop's cooldown is 1s; wait it out.
        try await Task.sleep(nanoseconds: 1_400_000_000)
        await drain()
        let replacement = sockets.current[.en]!
        XCTAssertTrue(replacement !== firstEN, "the drop must eventually be replaced")

        service.forward(chunk(3))
        XCTAssertEqual(replacement.sent, [], "still nothing before setupComplete")

        replacement.onEvent(.setupComplete)
        await drain()
        XCTAssertEqual(replacement.sent, [chunk(2), chunk(3)],
                       "speech from the whole gap — cooldown and handshake — is delivered once")
    }

    // A session error clears the held audio: a retry lands seconds later,
    // and stale speech into a fresh turn is worse than a dropped tail.
    func testErrorDropsHeldAudioAndFeedsNothing() async throws {
        let (service, sockets) = try startedService()
        await bringUp(sockets)
        let en = sockets.current[.en]!

        en.onEvent(.closed(expected: true))        // open a replacement window
        await drain()
        let replacement = sockets.current[.en]!
        service.forward(chunk(1))                  // held for the replacement

        replacement.onEvent(.error("handshake refused"))
        await drain()
        service.forward(chunk(2))
        replacement.onEvent(.setupComplete)        // even if setup landed late
        await drain()

        XCTAssertEqual(replacement.sent, [],
                       "a dead session gets neither held nor live audio")
        XCTAssertEqual(sockets.current[.de]!.sent, [chunk(1), chunk(2)],
                       "the healthy side is unaffected")
    }

    // The replacement queue is a rolling window: newest chunks win, and the
    // bound is what keeps a slow reconnect from flushing stale history.
    func testReplacementQueueRollsOldestOut() async throws {
        let (service, sockets) = try startedService()
        await bringUp(sockets)
        sockets.current[.en]!.onEvent(.closed(expected: true))
        await drain()
        let replacement = sockets.current[.en]!

        for n in 0..<60 { service.forward(chunk(n)) }
        replacement.onEvent(.setupComplete)
        await drain()

        XCTAssertEqual(replacement.sent.count, 50, "bounded at ~3.2s of 64ms chunks")
        XCTAssertEqual(replacement.sent.first, chunk(10), "the OLDEST rolled out")
        XCTAssertEqual(replacement.sent.last, chunk(59), "the newest survive")
    }
}
