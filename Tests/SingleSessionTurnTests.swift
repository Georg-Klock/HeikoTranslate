import XCTest
@testable import HeikoTranslate

/// GitHub #135, interpreter mode: ONE session picks the direction, so the
/// arbitration that infers it from two must not run.
///
/// Measured on device 2026-08-17 (build 2.4.67) with the arbitration still
/// live: 3 of 8 turns rejected, twice with `codes-veto: settled fr, home
/// session never translated`. That veto is predicated on two sessions existing
/// and one staying silent; with a single session the question cannot have a
/// true answer, and it killed turns whose translation was sitting in `outputs`
/// the whole time. One French utterance was refused three times before
/// committing on the fourth attempt.
///
/// L1.106c is the guard that matters: a rule may never reject a turn by
/// naming a session the run does not have.
final class SingleSessionTurnTests: XCTestCase {

    private func singleSessionTurn(home: TurnLogic.Lang = .de,
                                   partner: TurnLogic.Lang = .fr) -> TurnLogic {
        var turn = TurnLogic(home: home, partner: partner)
        turn.singleSession = true
        return turn
    }

    // L1.106 — output in the PARTNER language means the HOME language was
    // heard: Heiko spoke, the bubble is his.
    func testL1_106_partnerLanguageOutputMeansHomeWasSpoken() {
        var turn = singleSessionTurn()
        let bubble = turn.commit(inputs: [.de: "Mir geht es gut, danke."],
                                 outputs: [.fr: "Je vais bien, merci."])
        XCTAssertEqual(bubble?.isHome, true)
        XCTAssertEqual(bubble?.translation, "Je vais bien, merci.")
        XCTAssertEqual(turn.translator, .fr, "the side that spoke the translation")
    }

    // L1.106a — and the mirror.
    func testL1_106a_homeLanguageOutputMeansThePartnerWasSpoken() {
        var turn = singleSessionTurn()
        let bubble = turn.commit(inputs: [.de: "Je vais bien, merci."],
                                 outputs: [.de: "Mir geht es gut, danke."])
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "Mir geht es gut, danke.")
    }

    // L1.106b — SPEC §5.1 still holds: no translation, no bubble.
    func testL1_106b_noOutputIsStillRefused() {
        var turn = singleSessionTurn()
        XCTAssertNil(turn.commit(inputs: [.de: "Mir geht es gut."], outputs: [:]))
        XCTAssertEqual(turn.lastRejectReason, "no session produced any translation")
    }

    /// L1.106c — THE regression guard for the device failure. Codes settled on
    /// a language that is not home, and on the shipping path that arms the
    /// veto ("home session never translated"). With one session there is no
    /// home session to have stayed silent, the translation is right there, and
    /// the turn must commit.
    func testL1_106c_theCodesVetoCannotFireWithOneSession() {
        var turn = singleSessionTurn()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for offset in 0..<6 {
            turn.noteInputLanguage("fr", from: .de, at: base.addingTimeInterval(Double(offset) * 0.3))
        }
        XCTAssertEqual(turn.spokenLang, .fr, "precondition: the codes settled on a non-home language")

        let bubble = turn.commit(inputs: [.de: "Bon, alors on danse ?"],
                                 outputs: [.de: "Also, tanzen wir?"])
        XCTAssertNotNil(bubble, "the translation exists; no veto may name a session that does not exist")
        XCTAssertEqual(bubble?.isHome, false, "French was spoken, so the bubble is the partner's")
        XCTAssertNil(turn.lastRejectReason)
    }

    /// L1.106d — the live direction follows the same rule, so the line on
    /// screen and the committed bubble cannot disagree (the L1.47g doctrine),
    /// and no home-silence confirm delay applies: that delay exists to prove a
    /// second session stayed quiet.
    func testL1_106d_liveDirectionMatchesTheCommittedSide() {
        var turn = singleSessionTurn()
        turn.noteOutputs([.fr: "Je vais bien"], inputs: [.de: "Mir geht es gut"])
        XCTAssertEqual(turn.direction, .homeSpoken)
        XCTAssertEqual(turn.translator, .fr)

        let bubble = turn.commit(inputs: [.de: "Mir geht es gut, danke."],
                                 outputs: [.fr: "Je vais bien, merci."])
        XCTAssertEqual(bubble?.isHome, true, "commit agrees with the line already shown")
    }

    /// L1.106e — the shipping path is untouched. The same shape that commits
    /// in single-session mode must STILL be vetoed with two sessions, or this
    /// experiment has quietly changed the app.
    func testL1_106e_twoSessionArbitrationIsUnchanged() {
        var turn = TurnLogic(home: .de, partner: .fr)   // singleSession stays false
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for offset in 0..<6 {
            turn.noteInputLanguage("fr", from: .de, at: base.addingTimeInterval(Double(offset) * 0.3))
        }
        XCTAssertEqual(turn.spokenLang, .fr)

        let bubble = turn.commit(inputs: [.de: "Bon, alors on danse ?"], outputs: [:])
        XCTAssertNil(bubble, "the veto must still bite when there really are two sessions")
        XCTAssertEqual(turn.lastRejectReason,
                       "codes-veto: settled fr, home session never translated")
    }
}
