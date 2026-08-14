import XCTest
@testable import HeikoTranslate

/// GitHub #32, from device build 2.4.52 on 2026-08-14: a German sentence
/// opening with an English song title lands on the FOREIGN side, showing
/// German-into-German nonsense in the bubble's large line.
///
/// Eight turns were captured with the #32 decision diagnostic. Three flipped.
/// The discriminator is NOT the settle and NOT the size ratio — five turns
/// settled on `en` and only three flipped, and every turn cleared the 0.40
/// ratio floor. It is what the HOME session produced:
///
/// - **flips**: the `de` session TRANSLATED the English title and echoed the
///   German — "Wir werden euch rocken ist mein Lieblingslied." A half
///   translation. `isRoundTripEcho` does not fire (too much changed), so
///   `homeIsRealTranslation` reads it as a genuine translation of foreign
///   speech.
/// - **holds**: the `de` session echoed the whole utterance. The echo guard
///   fires, and the turn stays home.
///
/// These cases drive `homeIsRealTranslation` directly — it is pure, and it is
/// the branch the evidence implicates. Every string below is reconstructed
/// from the log, and each one's length matches the `outLen[...]` that turn
/// recorded, so these are the real values rather than plausible ones.
///
/// FIXED 2026-08-14 by re-calibrating `echoShareThreshold` from 0.6 to 0.3
/// — see the constant's own comment for the three measured populations. The
/// two flip cases were written under `XCTExpectFailure` and the markers came
/// off when they started passing, which is how the fix announced itself.
/// L1.88–90 are the guards the fix had to keep: a full echo, a second title,
/// and — the one that matters — a genuinely foreign turn that must still
/// read as a real translation (#83).
final class SongTitleDirectionTests: XCTestCase {

    private let spokenInput = "We will rock you. ist mein Lieblingslied."

    private func isRealTranslation(homeOut: String, partnerOut: String,
                                   input: String? = nil,
                                   spokenLang: TurnLogic.Lang? = .en) -> Bool {
        let heard = input ?? spokenInput
        return TurnLogic.homeIsRealTranslation(
            [.de: homeOut, .en: partnerOut],
            inputs: [.de: heard, .en: heard],
            home: .de, partner: .en,
            spokenLang: spokenLang,
            partnerHomeEvidence: true)   // partnerHeardHome=true on all 8 turns
    }

    /// L1.86 — the flip at 15:16:32 and 15:16:59. Home output is a HALF
    /// translation: the English title rendered into German, the German tail
    /// echoed. `outLen[home=46 partner=20]`, ratio 2.30.
    ///
    /// The speaker is German throughout; the title is a name, not a change of
    /// language. So this must not count as evidence of foreign speech.
    func testL1_86_aHalfTranslatedTitleIsNotEvidenceOfForeignSpeech() {
        XCTAssertFalse(
            isRealTranslation(homeOut: "Wir werden euch rocken ist mein Lieblingslied.",
                              partnerOut: "is my favorite song."),
            "the de session translating only the English title is not a foreign turn")
    }

    /// L1.87 — the flip at 15:18:07. Same half translation, but the partner
    /// output is complete this time (`outLen[home=46 partner=37]`, ratio
    /// 1.24). Included because it rules out the partner's truncation (#115)
    /// as the cause: the flip happens with a full partner output too.
    func testL1_87_theFlipIsNotCausedByTheTruncatedPartnerOutput() {
        XCTAssertFalse(
            isRealTranslation(homeOut: "Wir werden euch rocken ist mein Lieblingslied.",
                              partnerOut: "We will rock you is my favorite song.",
                              input: "We will rock you ist mein Lieblingslied."),
            "a complete partner output does not make the half translation foreign either")
    }

    /// L1.88 — the hold at 15:17:12. Identical sentence, but the home session
    /// ECHOED instead of half-translating (`outLen[home=40 partner=37]`).
    /// The echo guard fires and the turn stays home. This is the control:
    /// same words, same settle (`en`), opposite home output, opposite result.
    func testL1_88_aFullEchoIsCorrectlyNotATranslation() {
        XCTAssertFalse(
            isRealTranslation(homeOut: "We will rock you ist mein Lieblingslied.",
                              partnerOut: "We will rock you is my favorite song.",
                              input: "We will rock you ist mein Lieblingslied."),
            "a home output that IS the input must never read as a translation")
    }

    /// L1.89 — the hold at 15:17:55, a different title.
    /// `outLen[home=38 partner=35]`. Pins that the echo path is not specific
    /// to one song.
    func testL1_89_theEchoPathHoldsForOtherTitles() {
        XCTAssertFalse(
            isRealTranslation(homeOut: "Happy birthday ist mein Lieblingslied.",
                              partnerOut: "Happy Birthday is my favorite song.",
                              input: "Happy Birthday ist mein Lieblingslied."),
            "same shape, different title — still an echo")
    }

    /// L1.90 — the guard that must survive any fix. A genuinely foreign turn:
    /// English spoken, the home session produces real German. Loosening the
    /// echo detector to catch the half translation must not make THIS read as
    /// an echo, or #32's fix becomes #83's regression — a foreign speaker's
    /// words landing in Heiko's own bubble.
    func testL1_90_agenuineForeignTurnStillReadsAsATranslation() {
        XCTAssertTrue(
            isRealTranslation(homeOut: "Wo ist der Bahnhof, bitte?",
                              partnerOut: "Where is the train station, please?",
                              input: "Where is the train station, please?"),
            "a real translation of real foreign speech must keep counting as one")
    }
}
