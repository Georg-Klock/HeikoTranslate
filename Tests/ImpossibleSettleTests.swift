import XCTest
@testable import HeikoTranslate

/// GitHub #125: the codes settle on a language that is in NEITHER side of the
/// pair, and the turn is dropped.
///
/// Measured on device 2026-08-17 (build 2.4.63, logs `20260817-132840`), on
/// the DEFAULT de↔en pair, with Korean:
///
/// ```
/// commit REJECTED: codes-veto: settled ko, home session never translated
///   why: settled=ko votes=en×1,ko×2 sessions=de[ko×12] en[de×11/en×1]
///        outLen[home=153 partner=149] ratio=1.0
/// ```
///
/// Ordinary German — the independent on-device recogniser running alongside
/// heard it cleanly. The home session voted Korean twelve times; the PARTNER
/// session read it as German eleven times and was right. Both sessions
/// produced full-length output. The turn was still lost, because the pooled
/// tally settled somewhere impossible and the codes-veto has no yield for
/// that shape.
///
/// The rule under test: **a settle naming a language that is neither side is
/// known-corrupt, so the per-session votes are better evidence than the pool
/// that contains them.** The narrowest form of that — it fires only on
/// positive testimony from the partner session, by the same quorum and strict
/// plurality `partnerHeardHome` already uses for #83/#84.
///
/// Why the partner's reading is independent here, where it is not when the
/// settle names the partner language (L1.64e's lesson): the impossible settle
/// was formed by the HOME session's votes for a third language. The partner's
/// home-reading did not help produce it and cannot be the same noise counted
/// twice.
final class ImpossibleSettleTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// The measured device shape: an early, thin settle on a third language
    /// from the home session, then a long interleaved run in which the home
    /// session keeps reading Korean and the partner session keeps reading
    /// German.
    ///
    /// Interleaved deliberately — that is what the device did, and it is why
    /// the eleven contradicting votes never overturned the settle: an
    /// agreeing vote clears `contradiction`, so alternating codes never reach
    /// `overturnVotes` (3) in a row.
    private func measuredKoreanShape(partnerHomeVotes: Int) -> TurnLogic {
        var l = TurnLogic(home: .de, partner: .en)
        let base = t(0)
        l.noteInputLanguage("ko", from: .de, at: base)
        l.noteInputLanguage("ko", from: .de, at: base.addingTimeInterval(0.5))
        l.noteInputLanguage("en", from: .en, at: base.addingTimeInterval(0.9))
        l.noteInputLanguage("ko", from: .de, at: base.addingTimeInterval(TurnLogic.settleWindow + 0.1))
        for i in 0..<partnerHomeVotes {
            let at = base.addingTimeInterval(1.8 + Double(i) * 0.2)
            l.noteInputLanguage("de", from: .en, at: at)
            l.noteInputLanguage("ko", from: .de, at: at.addingTimeInterval(0.1))
        }
        return l
    }

    /// The German that was actually spoken, and what each session made of it:
    /// the home session echoes it, the partner session translates it.
    private let heard = " Na, uns geht es hervorragend. Wir würden gerne mit den Vorspeisen anfangen und dann etwas trinken."
    private let homeEcho = "Na, uns geht es hervorragend. Wir würden gerne mit den Vorspeisen anfangen und dann etwas trinken."
    private let partnerTranslation = "Well, we're doing excellently. We'd like to start with the appetizers and then have something to drink."

    // L1.100 — the measured turn. The settle is impossible, the partner
    // session's own votes say home by a wide plurality, and both sessions
    // produced full-length output. This must commit RIGHT/home rather than
    // being dropped.
    func testL1_100_impossibleSettleYieldsToPartnerHomeEvidence() {
        var l = measuredKoreanShape(partnerHomeVotes: 11)
        XCTAssertEqual(l.spokenLang, .ko, "precondition: the pool settled somewhere impossible")
        XCTAssertTrue(l.partnerHeardHome, "precondition: the partner session read HOME")

        let bubble = l.commit(inputs: [.de: heard, .en: heard],
                              outputs: [.de: homeEcho, .en: partnerTranslation])
        XCTAssertNotNil(bubble, "the partner session translated it — there IS something legal to show")
        XCTAssertEqual(bubble?.isHome, true, "German was spoken; the bubble belongs on the home side")
        XCTAssertEqual(l.translator, .en, "the translation comes from the partner session")
    }

    // L1.100b — the yield needs positive testimony. A neither-side settle
    // with NO partner reading of home must not get it: one witness reporting
    // a third language says nothing about which side spoke.
    //
    // Named for what it pins rather than for a veto, because there is no veto
    // here — see the second half, which documents what this turn does today.
    func testL1_100b_impossibleSettleWithoutPartnerEvidenceDoesNotYield() {
        var l = measuredKoreanShape(partnerHomeVotes: 0)
        XCTAssertEqual(l.spokenLang, .ko)
        XCTAssertFalse(l.partnerHeardHome)

        let bubble = l.commit(inputs: [.de: heard, .en: heard],
                              outputs: [.de: homeEcho, .en: partnerTranslation])
        XCTAssertNotEqual(bubble?.isHome, true, "the yield must not fire without partner testimony")

        // What this turn DOES do today is a separate, pre-existing defect,
        // pinned here rather than left for someone to rediscover: with no
        // partner-home evidence, `isRoundTripEcho` is never consulted (it is
        // gated behind `partnerHomeEvidence`), so the home session's verbatim
        // German echo passes the ratio path and commits on the FOREIGN side
        // as its own translation — German in, German out. That is #137's
        // shape mirrored, and it is not what this rule is for.
        XCTAssertEqual(bubble?.isHome, false, "documenting the pre-existing wrong-side echo commit")
        XCTAssertEqual(bubble?.original, bubble?.translation,
                       "and the 'translation' is the input verbatim — a separate bug")
    }

    // L1.100c — a quorum, not a stray. Two partner votes for home are the
    // session-local noise every log carries; the yield needs the same bar
    // `partnerHeardHome` sets everywhere else (L1.54's lesson).
    func testL1_100c_belowQuorumStillVetoes() {
        var l = measuredKoreanShape(partnerHomeVotes: 2)
        XCTAssertEqual(l.spokenLang, .ko)
        XCTAssertFalse(l.partnerHeardHome, "two votes is under the quorum of 3")

        XCTAssertNotEqual(l.commit(inputs: [.de: heard, .en: heard],
                                   outputs: [.de: homeEcho, .en: partnerTranslation])?.isHome,
                          true,
                          "a lone stray is not testimony — the yield must not fire")
    }

    // L1.100d — the yield decides the SIDE, it does not invent a translation.
    // With the partner session silent there is nothing to put in the bubble,
    // and the turn must still be refused (SPEC §5.1).
    func testL1_100d_yieldStillNeedsATranslation() {
        var l = measuredKoreanShape(partnerHomeVotes: 11)
        XCTAssertTrue(l.partnerHeardHome)

        let bubble = l.commit(inputs: [.de: heard, .en: heard],
                              outputs: [.de: homeEcho])
        XCTAssertNil(bubble, "a bubble with no translation is broken, whatever the votes say")
        XCTAssertEqual(l.lastRejectReason, "no session produced any translation")
    }

    // L1.100e — the rule is scoped to IMPOSSIBLE settles. A settle on the
    // partner language keeps the existing, much stricter yield (the full
    // crossed shape plus a corroborated echo), because there the settle is
    // formed from a pool containing the partner's own votes and is not an
    // independent witness. Regression guard for L1.64e.
    func testL1_100e_partnerSettleKeepsTheStricterRule() {
        var l = TurnLogic(home: .de, partner: .en)
        let base = t(0)
        // An ordinary foreign turn where the partner session alone emits a
        // quorum of stray home codes — L1.64e's exact shape.
        l.noteInputLanguage("en", from: .de, at: base)
        l.noteInputLanguage("en", from: .de, at: base.addingTimeInterval(0.5))
        l.noteInputLanguage("en", from: .de, at: base.addingTimeInterval(TurnLogic.settleWindow + 0.1))
        for i in 0..<4 {
            l.noteInputLanguage("de", from: .en, at: base.addingTimeInterval(1.8 + Double(i) * 0.2))
            l.noteInputLanguage("en", from: .de, at: base.addingTimeInterval(1.85 + Double(i) * 0.2))
        }
        XCTAssertEqual(l.spokenLang, .en, "settled on the PARTNER language, not an impossible one")

        let bubble = l.commit(
            inputs: [.de: " Where is the train station, please?", .en: " Where is the train station, please?"],
            outputs: [.de: "Wo ist der Bahnhof, bitte?", .en: ""])
        XCTAssertEqual(bubble?.isHome, false,
                       "a partner settle must NOT get the impossible-settle yield — LEFT via home")
    }
}
