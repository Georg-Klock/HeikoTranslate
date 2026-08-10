import XCTest
@testable import HeikoTranslate

/// L1 coverage for the #78 release gate. Times are relative to each event's
/// last loud mic buffer and preserve the measured timing relationships without
/// retaining the underlying private session record.
final class SpeechEndPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 3_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // L1.52 — a transcript-idle timer fired 148ms after a loud mic buffer,
    // while the speaker was still mid-sentence. With the mic's evidence in
    // the decision, the release defers.
    func testL1_52_loudMicDefersTheRelease() {
        XCTAssertFalse(SpeechEndPolicy.mayRelease(now: t(0.148),
                                                  lastLoudMicAt: t(0),
                                                  deferredSince: nil),
                       "a loud mic 148ms ago is a speaker mid-sentence, not a finished turn")
    }

    // L1.52b — the same event once the speech genuinely ends: the mic has
    // been quiet past the window, and the deferred release proceeds.
    func testL1_52b_quietMicReleasesADeferredStop() {
        XCTAssertTrue(SpeechEndPolicy.mayRelease(now: t(SpeechEndPolicy.micQuietWindow + 0.01),
                                                 lastLoudMicAt: t(0),
                                                 deferredSince: t(0.1)))
    }

    // L1.52c — quiet releases had at least one second without a loud mic
    // buffer. The gate must add zero latency to those; release stays on the
    // original timer schedule.
    func testL1_52c_theQuietEventsReleaseOnSchedule() {
        for gap in [2.85, 1.0, 1.0] {
            XCTAssertTrue(SpeechEndPolicy.mayRelease(now: t(gap),
                                                     lastLoudMicAt: t(0),
                                                     deferredSince: nil),
                          "mic quiet for \(gap)s must release on the timer's schedule")
        }
    }

    // L1.52d — no loud mic buffer this session (silence.wav's world, or a
    // dead route): the gate holds nothing.
    func testL1_52d_noMicEvidenceNeverDefers() {
        XCTAssertTrue(SpeechEndPolicy.mayRelease(now: t(10),
                                                 lastLoudMicAt: nil,
                                                 deferredSince: nil))
    }

    // L1.53 — the babble bound: a restaurant-loud room defers the release
    // only to `maxMicExtension`, then degrades to the OLD behaviour. The
    // mic floor was calibrated speech-vs-silence, not speech-vs-babble
    // (no babble log exists yet), and this cap is what makes that
    // uncalibrated case safe: worse latency never becomes a held-open turn.
    func testL1_53_babbleCapsTheDeferral() {
        XCTAssertFalse(SpeechEndPolicy.mayRelease(now: t(2.49),
                                                  lastLoudMicAt: t(2.4),
                                                  deferredSince: t(0)),
                       "under the cap, a loud mic still defers")
        XCTAssertTrue(SpeechEndPolicy.mayRelease(now: t(SpeechEndPolicy.maxMicExtension),
                                                 lastLoudMicAt: t(2.4),
                                                 deferredSince: t(0)),
                      "at the cap, the release proceeds regardless of the mic")
    }

    // L1.53b — a breath pause with speech resuming into the deferral (the
    // de_pause composite's exact shape): stays deferred until the speaker
    // actually finishes.
    func testL1_53b_resumedSpeechKeepsDeferring() {
        XCTAssertFalse(SpeechEndPolicy.mayRelease(now: t(1.0),
                                                  lastLoudMicAt: t(0.9),
                                                  deferredSince: t(0)))
    }
}
