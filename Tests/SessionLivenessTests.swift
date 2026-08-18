import XCTest
@testable import HeikoTranslate

/// The mute-session watchdog, from the device failure that motivated it.
///
/// Measured 2026-08-17 (build 2.4.65): the `de` session handshook, reported
/// `setupComplete`, and then produced nothing at all for four minutes while
/// `fr` transcribed every utterance. 20 of 21 turns were rejected — correctly,
/// since there really was no home translation — and nothing noticed, because
/// the startup watchdog only checks that sessions become *ready* and the
/// server-silence check watches the newest event from ANY session.
///
/// The risk this trades against is the opposite one: a watchdog that fires
/// wrongly tears down a working session mid-conversation. So the cases below
/// spend as much effort on when it must NOT fire.
final class SessionLivenessTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func mute(ready: Set<TurnLogic.Lang> = [.de, .fr],
                      content: [TurnLogic.Lang: Date] = [:],
                      readyAt: [TurnLogic.Lang: Date] = [:],
                      reconnects: [TurnLogic.Lang: Int] = [:],
                      now: TimeInterval) -> Set<TurnLogic.Lang> {
        SessionLiveness.muteSessions(ready: ready, lastContentAt: content,
                                     readyAt: readyAt, reconnects: reconnects, now: t(now))
    }

    // L1.107 — the measured failure: one session ready and permanently silent while the
    // other transcribes.
    func testL1_107_aSessionThatNeverSpokeWhileItsPartnerDidIsMute() {
        let found = mute(content: [.fr: t(58)],
                         readyAt: [.de: t(0), .fr: t(0)],
                         now: 60)
        XCTAssertEqual(found, [.de], "de never produced anything while fr kept transcribing")
    }

    // L1.107a — a quiet room is not a broken session. Nothing has been said,
    // so nothing may be torn down.
    func testL1_107a_silenceFromEveryoneIsNotEvidence() {
        XCTAssertTrue(mute(readyAt: [.de: t(0), .fr: t(0)], now: 60).isEmpty,
                      "no session is producing — there is no live partner to compare against")
    }

    // L1.107b — the discriminator is the PARTNER's liveness. A session quiet
    // for a long time while its partner is also quiet stays alone, however
    // long the silence runs.
    func testL1_107b_staleEvidenceDoesNotCondemn() {
        // fr last spoke 30s ago: outside the evidence window, so it proves
        // nothing about now.
        XCTAssertTrue(mute(content: [.fr: t(30)],
                           readyAt: [.de: t(0), .fr: t(0)],
                           now: 60).isEmpty)
    }

    // L1.107c — the quiet side of a normal turn must survive. Only OUTPUT is
    // legitimately one-sided; both sessions transcribe the same microphone, so
    // a session producing recently is healthy however little it said.
    func testL1_107c_aRecentlyProducingSessionIsNeverMute() {
        XCTAssertTrue(mute(content: [.de: t(57), .fr: t(59)],
                           readyAt: [.de: t(0), .fr: t(0)],
                           now: 60).isEmpty)
    }

    // L1.107d — under the limit, nothing fires. A pause between utterances
    // must not cost a reconnect.
    func testL1_107d_belowTheLimitNothingFires() {
        XCTAssertTrue(mute(content: [.de: t(50), .fr: t(59)],
                           readyAt: [.de: t(0), .fr: t(0)],
                           now: 60).isEmpty,
                      "10s of quiet is a pause, not a fault")
    }

    // L1.107e — capped. A session that comes back mute twice is saying
    // something a third reconnect will not fix, and a silent reconnect loop is
    // worse than a visible failure.
    func testL1_107e_reconnectsAreCapped() {
        func args(_ spent: Int) -> Set<TurnLogic.Lang> {
            mute(content: [.fr: t(58)],
                 readyAt: [.de: t(0), .fr: t(0)],
                 reconnects: [.de: spent], now: 60)
        }
        XCTAssertEqual(args(0), [.de])
        XCTAssertEqual(args(SessionLiveness.maxReconnects - 1), [.de], "the last attempt still fires")
        XCTAssertTrue(args(SessionLiveness.maxReconnects).isEmpty, "and then it stops")
    }

    // L1.107f — a lone session cannot be judged: there is no partner whose
    // liveness could condemn it. Guards the single-session configurations and
    // the window between one session dropping and its replacement arriving.
    func testL1_107f_asingleSessionIsNeverMute() {
        XCTAssertTrue(mute(ready: [.de], content: [.de: t(0)], readyAt: [.de: t(0)], now: 60).isEmpty)
    }

    // L1.107g — a session with no timestamps at all is not yet judgeable.
    // Reaching `ready` and being recorded are separate events, and the gap
    // must not read as muteness.
    func testL1_107g_aSessionWithNoClockIsLeftAlone() {
        XCTAssertTrue(mute(content: [.fr: t(59)], readyAt: [.fr: t(0)], now: 60).isEmpty,
                      "de has neither content nor a ready stamp — nothing to measure")
    }

    // L1.107h — it judges from the LAST content, not from readiness, once a
    // session has spoken. A session alive for an hour and silent for the last
    // 20s is mute; the ready stamp must not keep excusing it.
    func testL1_107h_silenceIsMeasuredFromTheLastContent() {
        XCTAssertEqual(mute(content: [.de: t(3540), .fr: t(3599)],
                            readyAt: [.de: t(0), .fr: t(0)],
                            now: 3600),
                       [.de])
    }
}
