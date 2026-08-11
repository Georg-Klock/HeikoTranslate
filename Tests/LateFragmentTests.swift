import XCTest
@testable import HeikoTranslate

/// GitHub #39: after a valid turn committed, late transcript fragments —
/// the previous turn still echoing out of the server, 5s after its bubble —
/// rebuilt the per-turn state and the idle timers finalized them into a
/// second, partial bubble: same side, strict prefixes of the committed turn.
///
/// The fix extends the straggler rule the language-code gate has had since
/// 2026-07-29 to the transcripts themselves: a fragment arriving while the
/// mic has heard NO speech this turn cannot be new speech. Deliberately not
/// a post-commit cooldown (the issue forbids one): a genuine instant reply
/// arrives with mic energy, which sets the flag, and passes — the second
/// test pins exactly that.
///
/// Drives the REAL service — `start()`, the event route with its registry
/// token check, the real idle/finalize timers — with sessions faked at the
/// `LiveTranslationSocket` seam. Real timers mean real waiting: this file
/// trades ~10s of wall clock for the production code path, per the issue's
/// done-when.
@MainActor
final class LateFragmentTests: XCTestCase {

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

    private final class Bubbles {
        var all: [(original: String, translation: String, wasHome: Bool)] = []
    }

    private func drain() async { for _ in 0..<25 { await Task.yield() } }

    /// Real timers need real time; the finalize chain is idle 1.6s + the
    /// output-quiet gate's possible re-arm.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 4_000_000_000)
        await drain()
    }

    private func startedService() throws -> (GeminiLiveTranslationService, Sockets, Bubbles) {
        let sockets = Sockets()
        let bubbles = Bubbles()
        let service = GeminiLiveTranslationService()
        service.skipAudioIOForTesting = true
        service.sessionFactoryForTesting = { lang, onEvent in
            let fake = FakeSocket(onEvent: onEvent)
            sockets.current[lang] = fake
            return fake
        }
        try service.start(
            home: .de, partner: .en,
            onPartialInput: { _ in },
            onUtterance: { original, translation, wasHome in
                bubbles.all.append((original, translation, wasHome))
            },
            onActivity: { _ in }, onError: { _ in })
        sockets.current[.de]?.onEvent(.setupComplete)
        sockets.current[.en]?.onEvent(.setupComplete)
        return (service, sockets, bubbles)
    }

    /// One legitimate foreign-language turn, the way the wire delivers it:
    /// codes from both sessions, the partner session echoing the heard
    /// English, the home session translating it.
    private func driveEnglishTurn(_ service: GeminiLiveTranslationService,
                                  _ sockets: Sockets,
                                  heard: String, translated: String) async {
        service.markSpeechHeardForTesting()
        for _ in 0..<2 {
            sockets.current[.en]?.onEvent(.inputLanguage("en"))
            sockets.current[.de]?.onEvent(.inputLanguage("en"))
            await drain()
        }
        sockets.current[.en]?.onEvent(.inputTranscript(heard))
        sockets.current[.de]?.onEvent(.inputTranscript(heard))
        await drain()
        sockets.current[.de]?.onEvent(.outputTranscript(translated))
        await drain()
    }

    // The filed repro, mechanism-for-mechanism: commit, then fragments that
    // are strict prefixes of the committed turn arrive seconds later, with
    // no mic speech in between. Exactly one bubble may exist.
    func testLateFragmentsAfterCommitCreateNoSecondBubble() async throws {
        let (service, sockets, bubbles) = try startedService()

        await driveEnglishTurn(service, sockets,
                               heard: "Where is the nearest station?",
                               translated: "Wo ist der nächste Bahnhof?")
        try await settle()
        XCTAssertEqual(bubbles.all.count, 1, "the legitimate turn commits — got \(bubbles.all)")
        XCTAssertFalse(bubbles.all[0].wasHome, "English spoken lands LEFT")

        // The stragglers: prefixes of both lines, exactly as logged in #39,
        // with the room silent (no mic energy since the reset).
        sockets.current[.en]?.onEvent(.inputTranscript("Where is the"))
        sockets.current[.de]?.onEvent(.outputTranscript("Wo ist der"))
        sockets.current[.en]?.onEvent(.inputLanguage("en"))
        await drain()
        try await settle()

        XCTAssertEqual(bubbles.all.count, 1,
                       "late fragments must not become a second, partial bubble — got \(bubbles.all)")
    }

    // The constraint the issue spells out: no blanket cooldown. A genuine
    // reply straight after the commit has mic energy, and still commits.
    func testAGenuineImmediateReplyStillCommits() async throws {
        let (service, sockets, bubbles) = try startedService()

        await driveEnglishTurn(service, sockets,
                               heard: "Where is the nearest station?",
                               translated: "Wo ist der nächste Bahnhof?")
        try await settle()
        XCTAssertEqual(bubbles.all.count, 1)

        // Immediately after: a real second utterance — mic energy first,
        // exactly as the tap would deliver it.
        await driveEnglishTurn(service, sockets,
                               heard: "And how long does the ride take?",
                               translated: "Und wie lange dauert die Fahrt?")
        try await settle()

        XCTAssertEqual(bubbles.all.count, 2,
                       "the gate is a straggler filter, not a cooldown — a real reply commits")
        XCTAssertEqual(bubbles.all[1].original, "And how long does the ride take?")
    }
}
