import XCTest
@testable import HeikoTranslate

/// L1 coverage for the service-level turn gate. The service owns timers and
/// AVFoundation; this real model owns the decision each of those timers must
/// ask before it finalizes anything.
final class TurnCoordinatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 4_000_000)
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // L1.73 — a quiet transcript is not permission to interrupt a speaker.
    func testL1_73_speakerEndIsAHardFinalizationGate() {
        var coordinator = TurnCoordinator()
        let id = coordinator.noteInput(at: t(0))
        coordinator.noteOutput(at: t(0.1))

        XCTAssertEqual(
            coordinator.finalization(for: id, at: t(2), inputQuietFor: 0.45, outputQuietFor: 0.9),
            .speakerStillActive,
            "a timer must not finalize while SpeechEndPolicy still vetoes the endpoint"
        )

        XCTAssertTrue(coordinator.confirmSpeakerStopped(for: id))
        XCTAssertEqual(
            coordinator.finalization(for: id, at: t(2), inputQuietFor: 0.45, outputQuietFor: 0.9),
            .granted
        )
    }

    // L1.73b — a resumed transcript revokes a previous endpoint confirmation.
    func testL1_73b_resumedInputReopensTheTurn() {
        var coordinator = TurnCoordinator()
        let id = coordinator.noteInput(at: t(0))
        XCTAssertTrue(coordinator.confirmSpeakerStopped(for: id))

        coordinator.noteInput(at: t(1))

        XCTAssertEqual(
            coordinator.finalization(for: id, at: t(3), inputQuietFor: 0.45, outputQuietFor: 0.9),
            .speakerStillActive
        )
    }

    // L1.73c — timer callbacks are scoped to their original turn.
    func testL1_73c_oldTurnTimerCannotFinalizeTheNextTurn() {
        var coordinator = TurnCoordinator()
        let old = coordinator.noteInput(at: t(0))
        coordinator.reset()

        let current = coordinator.noteInput(at: t(1))
        XCTAssertNotEqual(old, current)
        XCTAssertTrue(coordinator.confirmSpeakerStopped(for: current))

        XCTAssertEqual(
            coordinator.finalization(for: old, at: t(3), inputQuietFor: 0.45, outputQuietFor: 0.9),
            .staleTurn
        )
    }

    // L1.73d — GitHub #83: a loud mic un-seals the turn without advancing the
    // transcript clock, so the reopened turn can still finalize on the input
    // idleness it had already accumulated.
    func testL1_73d_reopeningSpeechDoesNotAdvanceTheInputClock() {
        var coordinator = TurnCoordinator()
        let id = coordinator.noteInput(at: t(0))
        XCTAssertTrue(coordinator.confirmSpeakerStopped(for: id))

        XCTAssertTrue(coordinator.reopenSpeech(for: id))
        XCTAssertEqual(
            coordinator.finalization(for: id, at: t(1), inputQuietFor: 0.45, outputQuietFor: 0.9),
            .speakerStillActive,
            "the mic said the person is still talking"
        )
        XCTAssertEqual(coordinator.lastInputAt, t(0),
                       "loud mic audio is not a transcript and must not move lastInputAt")

        XCTAssertTrue(coordinator.confirmSpeakerStopped(for: id))
        XCTAssertEqual(
            coordinator.finalization(for: id, at: t(1), inputQuietFor: 0.45, outputQuietFor: 0.9),
            .granted
        )
    }

    // L1.73e — a late #83 mic buffer cannot un-stop whatever turn is current.
    func testL1_73e_reopeningIsScopedToItsOwnTurn() {
        var coordinator = TurnCoordinator()
        let old = coordinator.noteInput(at: t(0))
        coordinator.reset()
        let current = coordinator.noteInput(at: t(1))
        XCTAssertTrue(coordinator.confirmSpeakerStopped(for: current))

        XCTAssertFalse(coordinator.reopenSpeech(for: old))
        XCTAssertTrue(coordinator.speakerHasStopped,
                      "a stale mic callback must not reopen the live turn")
    }
}
