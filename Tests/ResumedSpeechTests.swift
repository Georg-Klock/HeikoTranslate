import XCTest
@testable import HeikoTranslate

/// GitHub #83, from the 2026-08-12 device day: speech RESUMING between
/// "speaker stopped" and the commit had its first half committed and its
/// second half silently dropped as post-commit stragglers, while the
/// half-sentence translation played over the still-talking speaker. R1 —
/// nothing said is ever lost — makes this the worst failure class a
/// translator has.
@MainActor
final class ResumedSpeechTests: XCTestCase {

    // MARK: - The pure rule.

    func testLoudMicDuringStoppedWindowResumesTheTurn() {
        XCTAssertTrue(SpeechEndPolicy.speechResumesTurn(
            speakerHasStopped: true, isPlayingOutput: false))
    }

    func testLoudspeakerPlaybackNeverResumes() {
        // While our own translation plays, loudness at the mic proves
        // nothing — an echo-driven un-stop would hold turns open forever.
        XCTAssertFalse(SpeechEndPolicy.speechResumesTurn(
            speakerHasStopped: true, isPlayingOutput: true))
    }

    func testALiveTurnHasNothingToResume() {
        XCTAssertFalse(SpeechEndPolicy.speechResumesTurn(
            speakerHasStopped: false, isPlayingOutput: false))
        XCTAssertFalse(SpeechEndPolicy.speechResumesTurn(
            speakerHasStopped: false, isPlayingOutput: true))
    }

    // MARK: - The wiring, through the real service path.

    func testLoudSampleUnstopsAStoppedTurn() {
        let service = GeminiLiveTranslationService()
        service.forceSpeakerStoppedForTesting()
        XCTAssertTrue(service.speakerHasStoppedForTesting)
        service.noteLoudMicSampleForTesting()
        XCTAssertFalse(service.speakerHasStoppedForTesting,
                       "the device evidence: the person was still talking")
    }

    func testLoudSampleOnALiveTurnChangesNothing() {
        let service = GeminiLiveTranslationService()
        service.noteLoudMicSampleForTesting()
        XCTAssertFalse(service.speakerHasStoppedForTesting)
    }
}
