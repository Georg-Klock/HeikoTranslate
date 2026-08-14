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
/// The two flip cases assert the CORRECT outcome under `XCTExpectFailure`:
/// #32 is NOT fixed, so L1 stays green, and a fix reports an unexpected pass.
///
/// **A fix was attempted and reverted on 2026-08-14.** Lowering
/// `echoShareThreshold` to 0.3 turned L1.86/87 green and dropped a real turn
/// on device within the hour — L1.91 is that turn, and it is now the guard
/// that the next attempt has to satisfy first. L1.90's zero-overlap sentence
/// was not strict enough to catch it; L1.91 is, because its overlap comes
/// from proper nouns that legitimately survive translation.
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
        XCTExpectFailure("#32 unfixed: see echoShareThreshold — 0.3 fixed this and broke L1.91") {
            XCTAssertFalse(
                isRealTranslation(homeOut: "Wir werden euch rocken ist mein Lieblingslied.",
                                  partnerOut: "is my favorite song."),
                "the de session translating only the English title is not a foreign turn")
        }
    }

    /// L1.87 — the flip at 15:18:07. Same half translation, but the partner
    /// output is complete this time (`outLen[home=46 partner=37]`, ratio
    /// 1.24). Included because it rules out the partner's truncation (#115)
    /// as the cause: the flip happens with a full partner output too.
    func testL1_87_theFlipIsNotCausedByTheTruncatedPartnerOutput() {
        XCTExpectFailure("#32 unfixed") {
            XCTAssertFalse(
                isRealTranslation(homeOut: "Wir werden euch rocken ist mein Lieblingslied.",
                                  partnerOut: "We will rock you is my favorite song.",
                                  input: "We will rock you ist mein Lieblingslied."),
                "a complete partner output does not make the half translation foreign either")
        }
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

    /// L1.91 — the turn a threshold change dropped, measured on device
    /// 2026-08-14 at build 2.4.53.
    ///
    /// "A boy named Sue is my favorite song by Johnny Cash." spoken in
    /// English. The `de` session translates it properly — "Ein Junge namens
    /// Sue ist mein Lieblingslied von Johnny Cash." (60 chars, matching the
    /// turn's logged `outLen[home=60]`) — and the proper nouns Sue, Johnny
    /// and Cash survive, as proper nouns do. Echo share: **exactly 0.300**.
    ///
    /// At `echoShareThreshold` 0.3 that read as an echo, so the home session
    /// was judged never to have translated, direction never resolved, and the
    /// codes-veto dropped the turn four times over. No bubble at all — worse
    /// than the wrong-side bubble the change was made to fix.
    ///
    /// This is the case L1.90 was meant to represent and could not, because
    /// its sentence shares no tokens at all. Any future fix for #32 must keep
    /// THIS one passing.
    func testL1_91_aTranslationCarryingProperNounsIsStillATranslation() {
        let english = "A boy named Sue is my favorite song by Johnny Cash."
        XCTAssertTrue(
            isRealTranslation(homeOut: "Ein Junge namens Sue ist mein Lieblingslied von Johnny Cash.",
                              partnerOut: "A boy named Sue is my favorite song by Johnny Cash.",
                              input: english),
            "names surviving translation are not an echo — dropping this turn loses the bubble entirely")
    }

    /// L1.92 — **the proof that no threshold on `echoShare` can fix #32.**
    ///
    /// Two utterances that score *identically* and require *opposite*
    /// answers. Measured 2026-08-14 against the real `echoShare`:
    ///
    ///   "Apple and Google are both in California."
    ///     → "Apple und Google sind beide in Kalifornien."   share = 0.429
    ///     genuinely FOREIGN — must read as a real translation
    ///
    ///   "We will rock you. ist mein Lieblingslied."
    ///     → "Wir werden euch rocken ist mein Lieblingslied." share = 0.429
    ///     genuinely HOME — must NOT read as a real translation
    ///
    /// Not "the gap is narrow". The same number, opposite truths. Any cut-off
    /// classifies both the same way and is therefore wrong about one of them,
    /// whatever value it takes. That is why the 0.6 → 0.3 attempt broke
    /// L1.91 the moment it fixed L1.86.
    ///
    /// What separates them is WHICH tokens overlap: the foreign pair shares
    /// proper nouns that survive translation (Apple, Google), the home pair
    /// shares German function words the model left alone (ist, mein). A fix
    /// for #32 has to read that distinction. This test does not assert a
    /// direction — it asserts the metric cannot tell them apart, and it
    /// should FAIL the day a discriminator makes them distinguishable, which
    /// is exactly when it should be revisited.
    func testL1_92_echoShareCannotSeparateTheTwoPopulations() {
        let foreignIn  = "Apple and Google are both in California."
        let foreignOut = "Apple und Google sind beide in Kalifornien."
        let homeIn     = "We will rock you. ist mein Lieblingslied."
        let homeOut    = "Wir werden euch rocken ist mein Lieblingslied."

        let foreignShare = TurnLogic.echoShare(of: foreignOut,
                                               inputs: [.de: foreignIn, .en: foreignIn])
        let homeShare = TurnLogic.echoShare(of: homeOut,
                                            inputs: [.de: homeIn, .en: homeIn])

        XCTAssertEqual(foreignShare, homeShare, accuracy: 0.001,
                       "these two score identically — 0.429 — and need OPPOSITE answers, "
                       + "so no threshold on this metric can be right about both")
    }
}
