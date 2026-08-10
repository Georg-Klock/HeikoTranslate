import XCTest
@testable import HeikoTranslate

/// L1 logic tests (TESTING.md) — pure decision-making, no audio, no network.
///
/// These exercise the REAL `TurnLogic` type the app runs, never a mirror
/// copy. Since the language-pair settings (2026-07-28) the machine is
/// pair-based: HOME (right side, large type, default German) and PARTNER
/// (left side, default English). Direction comes from which session
/// translated; codes only veto. Test IDs match TESTING.md §L1.
final class TurnLogicTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Feeds one code repeatedly across the settle window, the way live
    /// sessions repeating the code every ~1s do, so the plurality settles.
    ///
    /// Votes are attributed to the HOME session unless a test says otherwise
    /// — measured (the 50 kept replay logs), the home session is where the
    /// mappable votes predominantly come from, and home-only attribution
    /// leaves `partnerHeardHome` false, which is the shipped-veto behaviour
    /// every pre-#83 test was written against. Tests about the yield feed
    /// the partner session's votes explicitly.
    private func settle(_ logic: inout TurnLogic, _ code: String, at date: Date? = nil,
                        from session: TurnLogic.Lang = .de) {
        let base = date ?? t(100)
        logic.noteInputLanguage(code, from: session, at: base)
        logic.noteInputLanguage(code, from: session, at: base.addingTimeInterval(0.5))
        logic.noteInputLanguage(code, from: session, at: base.addingTimeInterval(TurnLogic.settleWindow + 0.1))
    }

    /// Feeds the measured crossed mis-hearing pattern (#83, run 6): the home
    /// session votes the PARTNER language while the partner session votes
    /// HOME, imbalanced so the global plurality settles on the partner
    /// language — es×4 against de×3, the shape that armed the veto in every
    /// one of the 8 measured round-trip turns.
    private func settleCrossed(_ logic: inout TurnLogic, at date: Date? = nil) {
        let base = date ?? t(100)
        let partnerCode = logic.partner.rawValue
        let homeCode = logic.home.rawValue
        logic.noteInputLanguage(partnerCode, from: logic.home, at: base)
        logic.noteInputLanguage(homeCode, from: logic.partner, at: base.addingTimeInterval(0.1))
        logic.noteInputLanguage(partnerCode, from: logic.home, at: base.addingTimeInterval(0.5))
        logic.noteInputLanguage(homeCode, from: logic.partner, at: base.addingTimeInterval(0.6))
        logic.noteInputLanguage(partnerCode, from: logic.home, at: base.addingTimeInterval(1.0))
        logic.noteInputLanguage(homeCode, from: logic.partner, at: base.addingTimeInterval(1.1))
        logic.noteInputLanguage(partnerCode, from: logic.home,
                                at: base.addingTimeInterval(TurnLogic.settleWindow + 0.1))
    }

    // L1.1 — partner language spoken → home session translates, LEFT (R2)
    func testL1_1_partnerSpokenLandsLeft() {
        var l = TurnLogic()   // de↔en default
        let bubble = l.commit(inputs: [.de: "Hello, Heiko."],
                              outputs: [.de: "Hallo, Heiko.", .en: "Hello, Heiko."])
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "Hallo, Heiko.")
        XCTAssertEqual(l.translator, .de)
    }

    // L1.2 — home language spoken → partner session translates, RIGHT (R2)
    func testL1_2_homeSpokenLandsRight() {
        var l = TurnLogic()
        let bubble = l.commit(inputs: [.en: "Mir geht es gut."],
                              outputs: [.en: "I'm doing well."])
        XCTAssertEqual(bubble?.isHome, true)
        XCTAssertEqual(bubble?.translation, "I'm doing well.")
        XCTAssertEqual(l.translator, .en)
    }

    // L1.3 — every verified pair works both ways (the point of settings)
    func testL1_3_allPairsBothDirections() {
        for partner in TurnLogic.Lang.allCases where partner != .de {
            var foreign = TurnLogic(home: .de, partner: partner)
            let left = foreign.commit(inputs: [.de: "spoken partner text"],
                                      outputs: [.de: "deutsche Übersetzung", partner: "echo"])
            XCTAssertEqual(left?.isHome, false, "\(partner) → de failed")
            XCTAssertEqual(left?.translation, "deutsche Übersetzung")

            var home = TurnLogic(home: .de, partner: partner)
            let right = home.commit(inputs: [partner: "Mir geht es gut."],
                                    outputs: [partner: "partner translation"])
            XCTAssertEqual(right?.isHome, true, "de → \(partner) failed")
            XCTAssertEqual(right?.translation, "partner translation")
        }
        // …and a non-German home works too (English↔Spanish, once forbidden).
        var enEs = TurnLogic(home: .en, partner: .es)
        let bubble = enEs.commit(inputs: [.en: "¿Dónde está la estación?"],
                                 outputs: [.en: "Where is the station?", .es: "echo"])
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "Where is the station?")
    }

    // L1.4 — a THIRD language (neither side) is translated by the home
    // session like any foreign speech: LEFT, home-language translation.
    // The home reader is always served.
    func testL1_4_thirdLanguageLandsLeftWithHomeTranslation() {
        var l = TurnLogic()   // de↔en; French walks up
        let bubble = l.commit(inputs: [.de: "Où est la gare?"],
                              outputs: [.de: "Wo ist der Bahnhof?", .en: "Where is the station?"])
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "Wo ist der Bahnhof?")
    }

    // L1.7 — THE DUPLICATE BUG: two finalize paths → exactly ONE bubble (R1)
    func testL1_7_doubleCommitEmitsOneBubble() {
        var l = TurnLogic()
        let inputs: [TurnLogic.Lang: String] = [.en: "Mir geht es gut"]
        let outputs: [TurnLogic.Lang: String] = [.en: "I'm doing well"]
        XCTAssertNotNil(l.commit(inputs: inputs, outputs: outputs))
        XCTAssertNil(l.commit(inputs: inputs, outputs: outputs))
    }

    // L1.8 — nothing translated → NO bubble, and the R1 latch stays open so
    // the turn can still commit when the translation arrives (R3)
    func testL1_8_noTranslationNoBubbleNoLatch() {
        var l = TurnLogic()
        XCTAssertNil(l.commit(inputs: [.en: "Hallo"], outputs: [:]))
        XCTAssertNil(l.commit(inputs: [.en: "Hallo"], outputs: [.en: "  \n"]))
        XCTAssertNotNil(l.commit(inputs: [.en: "Hallo"], outputs: [.en: "Hello"]))
    }

    // L1.8c — nothing said → NO bubble
    func testL1_8c_emptyOriginalNoBubble() {
        var l = TurnLogic()
        XCTAssertNil(l.commit(inputs: [.de: "   "], outputs: [.de: "Hallo", .en: "echo"]))
    }

    // L1.9 — endTurn clears all per-turn state
    func testL1_9_endTurnClearsState() {
        var l = TurnLogic()
        settle(&l, "es-MX")
        _ = l.commit(inputs: [.de: "Hola"], outputs: [.de: "Hallo", .en: "echo"])
        l.endTurn()
        XCTAssertNil(l.spokenLang)
        XCTAssertNil(l.translator)
        XCTAssertNil(l.direction)
        XCTAssertFalse(l.hasCommitted)
    }

    // L1.12 — unrecognized language codes are noise (live: "ja" for English)
    func testL1_12_unknownCodesIgnored() {
        var l = TurnLogic()
        settle(&l, "ja-JP")
        XCTAssertNil(l.spokenLang)
        settle(&l, "de-DE")
        XCTAssertEqual(l.spokenLang, .de)
    }

    // L1.13 — THE CODES-VETO: codes settled on the partner language but the
    // home session never translated ⇒ there is nothing legal to show; the
    // utterance is dropped rather than committed to a guessed side.
    func testL1_13_codesVetoBlocksGuessedSide() {
        var l = TurnLogic()
        settle(&l, "en-US")
        XCTAssertNil(l.commit(inputs: [.en: "Do you want sauce?"],
                              outputs: [.en: "echo of English"]))
        XCTAssertTrue(l.lastRejectReason?.contains("codes-veto") ?? false)
    }

    // L1.14 — commit output is trimmed
    func testL1_14_commitTrims() {
        var l = TurnLogic()
        let bubble = l.commit(inputs: [.de: "  Hello \n"],
                              outputs: [.de: " Hallo ", .en: "echo"])
        XCTAssertEqual(bubble?.original, "Hello")
        XCTAssertEqual(bubble?.translation, "Hallo")
    }

    // L1.15 — stragglers: codes re-announcing the previous turn's language
    // ≤2.5s after it ended are ignored; a different language counts (R4).
    func testL1_15_stragglerGraceFiltersOnlyPreviousLanguage() {
        var l = TurnLogic()
        settle(&l, "en-US", at: t(0))
        _ = l.commit(inputs: [.de: "Hello"], outputs: [.de: "Hallo", .en: "echo"])
        l.endTurn(at: t(6))
        XCTAssertNil(l.noteInputLanguage("en-US", from: .de, at: t(8.1)))   // straggler
        XCTAssertNil(l.spokenLang)
        l.noteInputLanguage("de-DE", from: .de, at: t(6.5))
        l.noteInputLanguage("de-DE", from: .de, at: t(7.0))
        l.noteInputLanguage("de-DE", from: .de, at: t(8.2))
        XCTAssertEqual(l.spokenLang, .de)
    }

    // L1.15b — a virgin endTurn starts no grace window
    func testL1_15b_virginEndTurnNoGrace() {
        var l = TurnLogic()
        l.endTurn(at: t(0))
        settle(&l, "en-US", at: t(0.1))
        XCTAssertEqual(l.spokenLang, .en)
    }

    // L1.16 — THE KATAKANA BUG: the committed original prefers the
    // translator session's transcript over first-responder garbage, even
    // when the garbage is longest.
    func testL1_16_originalPrefersTranslatorTranscript() {
        var l = TurnLogic()
        let inputs: [TurnLogic.Lang: String] = [
            .en: "ハロー、ハイコ。お元気ですか。今日はどうですか。元気ですか?",
            .de: "Hello, Heiko. How are you?",
        ]
        let bubble = l.commit(inputs: inputs,
                              outputs: [.de: "Hallo, Heiko. Wie geht's?", .en: "echo echo"])
        XCTAssertEqual(bubble?.original, "Hello, Heiko. How are you?")
    }

    // L1.17 — THE SETTLING RULE: a unanimously wrong opening burst loses to
    // the corrected plurality.
    func testL1_17_unanimousOpeningBurstLosesToPlurality() {
        var l = TurnLogic()
        XCTAssertNil(l.noteInputLanguage("es-ES", from: .de, at: t(0)))
        XCTAssertNil(l.noteInputLanguage("es-ES", from: .de, at: t(0)))
        XCTAssertNil(l.noteInputLanguage("es-ES", from: .de, at: t(0.1)))
        XCTAssertNil(l.noteInputLanguage("de-DE", from: .de, at: t(1.1)))
        XCTAssertNil(l.noteInputLanguage("de-DE", from: .de, at: t(1.2)))
        XCTAssertNil(l.noteInputLanguage("de-DE", from: .de, at: t(1.3)))
        XCTAssertEqual(l.noteInputLanguage("de-DE", from: .de, at: t(2.1)), .de)
        XCTAssertEqual(l.spokenLang, .de)
    }

    // L1.19 — a stray old vote must not pre-expire the settle window
    func testL1_19_staleVotesExpire() {
        var l = TurnLogic()
        XCTAssertNil(l.noteInputLanguage("de-DE", from: .de, at: t(0)))
        XCTAssertNil(l.noteInputLanguage("en-US", from: .de, at: t(60)))
        XCTAssertNil(l.spokenLang)
        l.noteInputLanguage("en-US", from: .de, at: t(60.5))
        l.noteInputLanguage("en-US", from: .de, at: t(61.6))
        XCTAssertEqual(l.spokenLang, .en)
    }

    // L1.20 — session behavior beats lying codes: codes said HOME but the
    // home session substantially translated ⇒ the speech was foreign.
    func testL1_20_homeTranslationBeatsLyingCodes() {
        var l = TurnLogic(home: .de, partner: .es)
        settle(&l, "de-DE")   // codes lie: "German"
        let bubble = l.commit(
            inputs: [.de: "Do you want caramel sauce?"],
            outputs: [.de: "Möchten Sie Karamellsauce?", .es: "¿Quieres salsa de caramelo?"]
        )
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "Möchten Sie Karamellsauce?")
    }

    // L1.22 — a home-session false start ("Ich", 3 chars vs 95) is not a
    // translation; the turn commits as home speech.
    func testL1_22_homeFalseStartIsNotATranslation() {
        var l = TurnLogic(home: .de, partner: .es)
        l.noteOutputs([.de: "Ich", .es: "Me siento muy bien. ¿Y cómo está usted hoy?"], inputs: [:], at: t(0))
        XCTAssertNotEqual(l.translator, .de)
        let bubble = l.commit(
            inputs: [.es: "Mir geht es sehr gut."],
            outputs: [.de: "Ich", .es: "Me siento muy bien. ¿Y cómo está usted hoy?"]
        )
        XCTAssertEqual(bubble?.isHome, true)
        XCTAssertEqual(bubble?.translation, "Me siento muy bien. ¿Y cómo está usted hoy?")
    }

    // L1.22b — a short but genuine home translation still counts
    func testL1_22b_shortRealHomeTranslationCounts() {
        var l = TurnLogic()
        let bubble = l.commit(
            inputs: [.de: "¿Dónde está la estación de tren, por favor?"],
            outputs: [.de: "wo der Bahnhof ist, bitte.", .en: "where the train station is, please."]
        )
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "wo der Bahnhof ist, bitte.")
    }

    // L1.23 — THE FLOP: partner output alone proves nothing (English echoes
    // English); only sustained home silence (1.2s) concludes home speech.
    func testL1_23_partnerOutputAloneDoesNotDecide() {
        var l = TurnLogic()
        l.noteOutputs([.en: "Do you want caramel sauce?"], inputs: [:], at: t(0))
        XCTAssertNil(l.direction, "partner output alone must not conclude home speech")
        l.noteOutputs([.en: "Do you want caramel sauce?",
                       .de: "Möchten Sie Karamellsauce?"], inputs: [:], at: t(0.6))
        XCTAssertEqual(l.direction, .foreignSpoken)
        XCTAssertEqual(l.translator, .de)
    }

    func testL1_23b_sustainedHomeSilenceMeansHomeSpoken() {
        var l = TurnLogic()
        l.noteOutputs([.en: "I'm doing well"], inputs: [:], at: t(0))
        XCTAssertNil(l.direction)
        l.noteOutputs([.en: "I'm doing well, thank you"], inputs: [:], at: t(1.4))
        XCTAssertEqual(l.direction, .homeSpoken)
        XCTAssertEqual(l.translator, .en)
    }

    // L1.24 — noteOutputs applies the codes-veto: codes settled on a
    // non-home language mean the partner output is an ECHO of foreign
    // speech (measured 2026-07-29: English input → en session echoed the
    // English, de session silent). Home silence must not resolve homeSpoken,
    // or the echo audio plays as if it were a translation.
    func testL1_24_codesVetoBlocksHomeSilenceResolution() {
        var l = TurnLogic()
        settle(&l, "en", at: t(0))
        // Real transcripts, not [:] — the veto now YIELDS to a partner output
        // that demonstrably translated (#75), so this test must show the
        // echo case still held: the en output IS the input, token for token.
        let heard: [TurnLogic.Lang: String] = [.de: "How much is such an item?"]
        l.noteOutputs([.en: "How much is such an item?"], inputs: heard, at: t(2))
        l.noteOutputs([.en: "How much is such an item?"], inputs: heard, at: t(4))
        XCTAssertNil(l.direction, "settled foreign codes must veto homeSpoken")
        XCTAssertNil(l.translator)
        XCTAssertNil(l.commit(inputs: [.de: "How much is such an item?"],
                              outputs: [.en: "How much is such an item?"]))
    }

    // L1.25 — the device-log cascade of 2026-07-29 15:03: stragglers settle
    // "en" before the speech begins, then the REAL German speech promptly
    // sends unanimous de codes. Three consecutive contradictions overturn
    // the poisoned (but still-current) settle, so the veto lifts and the
    // turn commits. A truly dead context expires separately (L1.61).
    func testL1_25_consecutiveContradictionsOverturnPoisonedSettle() {
        var l = TurnLogic()
        settle(&l, "en", at: t(0))
        XCTAssertEqual(l.spokenLang, .en)
        l.noteInputLanguage("de", from: .de, at: t(2))
        l.noteInputLanguage("de", from: .de, at: t(3))
        XCTAssertEqual(l.spokenLang, .en, "two contradictions must not overturn")
        l.noteInputLanguage("de", from: .de, at: t(3.9))
        XCTAssertEqual(l.spokenLang, .de, "third consecutive contradiction re-settles")
        l.noteOutputs([.en: "I have the feeling I'm not understood."], inputs: [:], at: t(4))
        l.noteOutputs([.en: "I have the feeling I'm not understood."], inputs: [:], at: t(5.5))
        XCTAssertEqual(l.direction, .homeSpoken)
        XCTAssertNotNil(l.commit(inputs: [.de: "Ich habe das Gefühl."],
                                 outputs: [.en: "I have the feeling I'm not understood."]))
    }

    // L1.25b — the NORMAL lying-code noise during speech (en,de,en,de from
    // the two sessions, ~1/s each) alternates, so it never reaches three
    // consecutive votes and the settle holds.
    func testL1_25b_alternatingLiesDoNotOverturn() {
        var l = TurnLogic()
        settle(&l, "en", at: t(0))
        for i in 0..<6 {
            l.noteInputLanguage("de", from: .de, at: t(2 + Double(i)))
            l.noteInputLanguage("en", from: .de, at: t(2.5 + Double(i)))
        }
        XCTAssertEqual(l.spokenLang, .en, "alternating contradictions must not overturn")
    }

    // L1.26 — the spoken-number turn (device log 2026-07-29 15:27): "14
    // Euro" is 7 chars, under the 8-char false-start floor, but the codes
    // settled en — foreign speech confirmed, so the tiny translation is
    // real and the turn commits LEFT.
    func testL1_26_settledForeignCodesWaiveTheAbsoluteFloor() {
        var l = TurnLogic()
        settle(&l, "en", at: t(0))
        l.noteOutputs([.de: "14 Euro"], inputs: [:], at: t(3))
        XCTAssertEqual(l.direction, .foreignSpoken)
        XCTAssertEqual(l.translator, .de)
        let bubble = l.commit(inputs: [.en: "Fourteen euros"], outputs: [.de: "14 Euro"])
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "14 Euro")
    }

    // L1.26b — without settled foreign codes the floor holds: a tiny home
    // output alone must not decide the turn (the false-start guard).
    func testL1_26b_floorHoldsWhileCodesAreUnsettled() {
        var l = TurnLogic()
        l.noteOutputs([.de: "Ich"], inputs: [:], at: t(0))
        XCTAssertNil(l.direction, "3 chars with no code corroboration is a false start")
        var settledHome = TurnLogic()
        settle(&settledHome, "de", at: t(0))
        settledHome.noteOutputs([.de: "Ich"], inputs: [:], at: t(3))
        XCTAssertNil(settledHome.direction, "home codes never waive the floor")
    }

    // L1.31 — settled foreign codes rescue a SHORT home translation even when
    // the partner session echoed. Before GitHub #23 the ratio branch returned
    // early whenever an echo was present, so the corroboration bypass added in
    // L1.26 was unreachable in the common case — a short but genuine
    // translation next to a long echo was swallowed.
    func testL1_31_settledCodesRescueShortHomeOutputDespiteEcho() {
        var l = TurnLogic()
        settle(&l, "en", at: t(0))
        let echo = "Fourteen euros please, and a receipt."   // 37 chars
        l.noteOutputs([.de: "14 Euro bitte", .en: echo], inputs: [:], at: t(3))
        XCTAssertEqual(l.direction, .foreignSpoken,
                       "13/37 = 0.35 is below the 0.4 ratio floor, but the codes settled foreign")
        XCTAssertEqual(l.translator, .de)
        let bubble = l.commit(inputs: [.en: "Fourteen euros please"],
                              outputs: [.de: "14 Euro bitte", .en: echo])
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "14 Euro bitte")
    }

    // L1.31b — the rescue must NOT readmit a false start. Same shape as L1.22
    // (3-char home output beside a full echo) but with the codes settled
    // foreign: the absolute floor still rejects it.
    func testL1_31b_corroborationDoesNotRescueAFalseStart() {
        var l = TurnLogic()
        settle(&l, "en", at: t(0))
        l.noteOutputs([.de: "Ich", .en: "I am doing very well today, thank you."], inputs: [:], at: t(3))
        XCTAssertNotEqual(l.translator, .de,
                          "3 chars is a false start whatever the codes say")
    }

    // L1.41 — the case GitHub #23 was actually filed for: "14 Euro" is SEVEN
    // characters, and the fix that closed #23 kept the 8-char uncorroborated
    // floor in the echo branch, so the measured failure survived its own fix.
    // L1.31 passed only because its example ("14 Euro bitte") is 13.
    func testL1_41_theMeasuredSevenCharTranslationSurvivesAnEcho() {
        var l = TurnLogic()
        settle(&l, "en", at: t(0))
        let echo = "That'll be fourteen euros."          // 26 chars
        l.noteOutputs([.de: "14 Euro", .en: echo], inputs: [:], at: t(3))   // 7/26 = 0.27, under the ratio floor
        XCTAssertEqual(l.direction, .foreignSpoken,
                       "corroborated codes rescue it; only the ratio failed")
        let bubble = l.commit(inputs: [.en: "That'll be fourteen euros"],
                              outputs: [.de: "14 Euro", .en: echo])
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "14 Euro")
    }

    // L1.41b — the corroborated floor is confined to the ECHO branch, and that
    // asymmetry is deliberate. With nothing to weigh the home output against,
    // the codes are the only evidence there is, so any non-empty output is
    // accepted — as it always has been. A floor there would swallow the
    // shortest real answers in the language, which is the failure the whole
    // area exists to prevent.
    //
    // Guards against "tidying" the two branches into one rule.
    func testL1_41b_theCorroboratedFloorAppliesOnlyBesideAnEcho() {
        // Below the 5-char floor, no echo: accepted. These are answers, not
        // false starts, and rejecting them is a silently swallowed turn.
        for answer in ["Ja", "Nein", "Vier"] {
            var l = TurnLogic()
            settle(&l, "en", at: t(0))
            l.noteOutputs([.de: answer], inputs: [:], at: t(3))
            XCTAssertEqual(l.direction, .foreignSpoken,
                           "\"\(answer)\" (\(answer.count)) is a real answer with no echo to judge it by")
        }

        // The same lengths BESIDE an echo: the floor applies, because now
        // there is something to tell a false start from a translation.
        var withEcho = TurnLogic()
        settle(&withEcho, "en", at: t(0))
        withEcho.noteOutputs([.de: "Ich", .en: "I am doing very well today, thank you."], inputs: [:], at: t(3))
        XCTAssertNil(withEcho.direction, "3 chars beside a full echo is a false start")

        // And the boundary itself, so the constant cannot drift unnoticed:
        // 5 clears, 4 does not, both beside the same echo.
        let echo = "That'll be fourteen euros."
        var atFloor = TurnLogic()
        settle(&atFloor, "en", at: t(0))
        atFloor.noteOutputs([.de: "12345", .en: echo], inputs: [:], at: t(3))
        XCTAssertEqual(atFloor.direction, .foreignSpoken, "5 chars is at the floor and clears it")

        var belowFloor = TurnLogic()
        settle(&belowFloor, "en", at: t(0))
        belowFloor.noteOutputs([.de: "1234", .en: echo], inputs: [:], at: t(3))
        XCTAssertNil(belowFloor.direction, "4 chars is under it")
    }

    // MARK: - GitHub #26 — state-machine edge cases

    // L1.34 — a tied plurality must not be broken by enum declaration order.
    // `for lang in Lang.allCases { if count > best }` settles a 2-2 vote on
    // whichever language happens to enumerate first (de, en, es, …), and that
    // arbitrary settle then arms the commit veto. A tie means "the codes do not
    // agree yet", which is exactly the state `spokenLang == nil` exists to
    // represent, so nothing settles until the tie breaks.
    func testL1_34_aTiedVoteDoesNotSettle() {
        var l = TurnLogic()
        l.noteInputLanguage("en", from: .de, at: t(0))
        l.noteInputLanguage("es", from: .de, at: t(0.2))
        l.noteInputLanguage("en", from: .de, at: t(0.4))
        l.noteInputLanguage("es", from: .de, at: t(TurnLogic.settleWindow + 0.2))   // 2-2, window elapsed

        XCTAssertNil(l.spokenLang,
                     "a 2-2 tie must not settle on whichever language enumerates first")

        // And it settles the moment the tie actually breaks.
        l.noteInputLanguage("es", from: .de, at: t(TurnLogic.settleWindow + 0.4))
        XCTAssertEqual(l.spokenLang, .es)
    }

    // L1.35 — a turn that produced only partner output still ends a turn.
    // `endTurn`'s "did this turn contain anything" guard checks spokenLang,
    // direction, hasCommitted and votes — but not `firstPartnerOutputAt`, which
    // it nevertheless clears. So an echo-only turn (partner session echoes
    // foreign speech, no codes, no commit) never stamps `lastTurnEnd`, the next
    // turn's straggler grace is never armed, and that echo's late codes are
    // admitted as fresh votes for the following turn.
    func testL1_35_anEchoOnlyTurnStillArmsTheStragglerGrace() {
        var l = TurnLogic()
        l.noteOutputs([.en: "I am doing very well, thank you."], inputs: [:], at: t(0))
        l.endTurn(at: t(1))

        XCTAssertEqual(l.lastTurnEnd, t(1),
                       "a turn with partner output in it is not an empty turn")
    }

    // L1.36 — a commit that returns nil must not leave a direction behind.
    // `direction` is assigned before the empty-original/empty-translation
    // guards, so a rejected commit still reports a side for a turn that
    // produced no bubble — and `translator` follows `direction`, which is what
    // the service uses to decide whose held audio to play.
    func testL1_36_aRejectedCommitLeavesNoDirection() {
        var l = TurnLogic()
        // Home output is decisive (11 chars, no partner output), so the foreign
        // branch is taken — then rejected, because no transcript ever arrived.
        let bubble = l.commit(inputs: [:], outputs: [.de: "Hallo Heiko"])

        XCTAssertNil(bubble)
        XCTAssertEqual(l.lastRejectReason, "foreign branch: empty original")
        XCTAssertNil(l.direction, "no bubble means no side was decided")
        XCTAssertNil(l.translator, "and nothing to play")
    }

    // L1.36b — the same, reached the way the service actually reaches it:
    // output streams in first, so `noteOutputs` has ALREADY set a provisional
    // direction before `commit` runs. The first version of this fix saved that
    // value and put it back on rejection, which restored the ghost instead of
    // removing it — and L1.36 could not see the difference, because a fresh
    // turn has nothing to restore. Caught in review of #26.
    func testL1_36b_aRejectedCommitClearsADirectionSetByStreaming() {
        var l = TurnLogic()
        l.noteOutputs([.de: "Hallo Heiko"], inputs: [:], at: t(0))
        XCTAssertEqual(l.direction, .foreignSpoken, "streaming set it, as it should")
        XCTAssertEqual(l.translator, .de)

        let bubble = l.commit(inputs: [:], outputs: [.de: "Hallo Heiko"])

        XCTAssertNil(bubble)
        XCTAssertNil(l.direction, "the rejection must clear it, not put it back")
        XCTAssertNil(l.translator, "so the service has no session to hand held audio to")
    }

    // L1.36c — the home branch, same shape: partner output established the
    // side before the commit rejected for a missing transcript.
    func testL1_36c_theHomeBranchAlsoClearsOnRejection() {
        var l = TurnLogic()
        l.noteOutputs([.en: "I'm doing well."], inputs: [:], at: t(0))
        l.noteOutputs([.en: "I'm doing well."], inputs: [:], at: t(TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertEqual(l.direction, .homeSpoken)

        let bubble = l.commit(inputs: [:], outputs: [.en: "I'm doing well."])

        XCTAssertNil(bubble)
        XCTAssertEqual(l.lastRejectReason, "home branch: empty original")
        XCTAssertNil(l.direction)
        XCTAssertNil(l.translator)
    }

    // L1.37 — output arriving after the commit must not move the bubble.
    // R1: a turn commits once. `noteOutputs` had no `hasCommitted` guard, so a
    // late home-session transcript could flip `direction` from homeSpoken to
    // foreignSpoken *after* the bubble was emitted — changing `translator`
    // while the service is flushing held audio for the old one.
    func testL1_37_lateOutputCannotFlipACommittedTurn() {
        var l = TurnLogic()
        let bubble = l.commit(inputs: [.en: "Mir geht es gut."],
                              outputs: [.en: "I'm doing well."])
        XCTAssertEqual(bubble?.isHome, true)
        XCTAssertEqual(l.direction, .homeSpoken)
        XCTAssertEqual(l.translator, .en)

        // A late, substantial home-session transcript for the same turn.
        l.noteOutputs([.de: "Mir geht es wirklich gut.", .en: "I'm doing well."], inputs: [:], at: t(3))

        XCTAssertEqual(l.direction, .homeSpoken, "the committed side is final")
        XCTAssertEqual(l.translator, .en, "so the audio still goes to the session that translated")
    }

    // L1.38 — INTENDED, not a defect: `staleCodeGrace` (2.5s) is longer than
    // `settleWindow` (1.5s), so a tally can settle entirely inside the grace
    // window that follows a turn. That is the documented meaning of the grace —
    // it filters stragglers *of the previous turn's language only*; a code for a
    // different language is a fast reply and counts immediately. Pinned here
    // because the asymmetry looks like a bug until you know that, and because
    // the service's mic-energy gate (`speechHeardThisTurn`) is a second line of
    // defence that must not be mistaken for this one.
    func testL1_38_aDifferentLanguageSettlesInsideTheStragglerGrace() {
        var l = TurnLogic()
        settle(&l, "en", at: t(0))
        XCTAssertEqual(l.spokenLang, .en)
        l.endTurn(at: t(2))                       // grace runs to t(4.5)

        // The previous turn's language, still inside the grace: ignored.
        XCTAssertNil(l.noteInputLanguage("en", from: .de, at: t(2.5)))
        XCTAssertNil(l.spokenLang)

        // A different language, same window: counts, and settles.
        l.noteInputLanguage("es", from: .de, at: t(2.6))
        l.noteInputLanguage("es", from: .de, at: t(3.0))
        l.noteInputLanguage("es", from: .de, at: t(4.2))     // still inside the 2.5s grace
        XCTAssertEqual(l.spokenLang, .es,
                       "a reply in another language is not a straggler")
    }

    // L1.24b — codes settled on the HOME language do not veto; the confirm
    // window may elapse with no new event in between (time-based, re-checked
    // by the service's recheck clock).
    func testL1_24b_homeCodesAllowLateHomeResolution() {
        var l = TurnLogic()
        settle(&l, "de", at: t(0))
        l.noteOutputs([.en: "Hi, I'm Heiko, how are you?"], inputs: [:], at: t(2))
        XCTAssertNil(l.direction, "confirm window hasn't elapsed yet")
        // No new server event — the recheck clock just asks again later.
        l.noteOutputs([.en: "Hi, I'm Heiko, how are you?"], inputs: [:], at: t(3.5))
        XCTAssertEqual(l.direction, .homeSpoken)
        XCTAssertEqual(l.translator, .en)
    }

    // MARK: - Round-trip echoes (#75, #45)

    // The measured failing replay of 2026-08-07 (baseline run 6), verbatim.
    // German spoken after Spanish; the de session mis-heard the opening as
    // Spanish ("Me va muy bien,"), translated that misreading back into
    // German, then repeated the rest word for word — a full-length output
    // (ratio 1.1, every size floor passed) built from the input's own words
    // (echo-share 0.85). Meanwhile its language codes voted "es" all turn
    // and settled the guess on the PARTNER language, so before #75 this
    // turn either committed LEFT (the ratio path) or was swallowed by the
    // codes-veto once the ratio path was closed. It must commit RIGHT via
    // the es session, whose Spanish output shares nothing with the German
    // heard (echo-share 0.16) and is therefore a real translation.
    private static let run6Inputs: [TurnLogic.Lang: String] = [
        .de: " Me va muy bien, vielen Dank für die Nachfrage. Und wie geht es Ihnen heute bei diesem schönen Wetter?",
        .es: " Um, mir geht es sehr gut. Vielen Dank für die Nachfrage. Und wie geht es Ihnen heute bei diesem schönen Wetter?",
    ]
    private static let run6Outputs: [TurnLogic.Lang: String] = [
        .de: "Ich komme sehr gut zurecht, vielen Dank für die Nachfrage. Und wie geht es Ihnen heute bei diesem schönen Wetter?",
        .es: "Este, me siento muy bien. Muchas gracias por preguntar. ¿Y cómo está usted hoy con este clima tan bonito?",
    ]

    // L1.47 — the round-trip echo lands RIGHT despite codes settled on the
    // partner: the crossed votes (home session voting es, partner session
    // voting de — run 6's measured pattern, 8/8 in the kept logs) both
    // disqualify the home output as an echo and make the veto yield.
    func testL1_47_roundTripEchoWithPartnerSettledCodesLandsRight() {
        var l = TurnLogic(home: .de, partner: .es)
        settleCrossed(&l, at: t(0))
        XCTAssertEqual(l.spokenLang, .es, "the mis-hearing session's votes must win the settle")
        let bubble = l.commit(inputs: Self.run6Inputs, outputs: Self.run6Outputs)
        XCTAssertEqual(bubble?.isHome, true,
                       "a full-length round-trip echo must not count as a home translation")
        XCTAssertEqual(bubble?.translation,
                       "Este, me siento muy bien. Muchas gracias por preguntar. ¿Y cómo está usted hoy con este clima tan bonito?")
        XCTAssertEqual(l.translator, .es)
    }

    // L1.47b — same turn shape with the codes settled on HOME (the pattern
    // the referee-session experiment logged: every session voting de,
    // correctly). Here the old ratio path was the whole failure. The partner
    // session's de votes are also what corroborates the echo now — "every
    // session voting de" includes the witness.
    func testL1_47b_roundTripEchoWithHomeSettledCodesLandsRight() {
        var l = TurnLogic(home: .de, partner: .es)
        settle(&l, "de", at: t(0), from: .de)
        settle(&l, "de", at: t(0.2), from: .es)
        let bubble = l.commit(inputs: Self.run6Inputs, outputs: Self.run6Outputs)
        XCTAssertEqual(bubble?.isHome, true)
        XCTAssertEqual(l.translator, .es)
    }

    // L1.47c — #45's danger table: a SHORT identical output is a cognate,
    // number, or name surviving translation, not an echo. Below the token
    // floor the echo rule must stay out of it, and the turn stays LEFT.
    func testL1_47c_shortIdenticalOutputIsStillATranslation() {
        var l = TurnLogic()   // de↔en
        let bubble = l.commit(
            inputs: [.de: "Navigator", .en: "Navigator"],
            outputs: [.de: "Navigator", .en: "Navigator"])
        XCTAssertEqual(bubble?.isHome, false,
                       "one token of overlap is a proper noun, not a round trip")
        XCTAssertEqual(l.translator, .de)
    }

    // L1.47d — a third language walking up produces long outputs in BOTH
    // sessions, but they are real translations: almost no token survives
    // from the French heard. The echo rule must not touch them (L1.4's
    // semantics at full length).
    func testL1_47d_thirdLanguageLongTranslationsStayLeft() {
        var l = TurnLogic(home: .de, partner: .es)
        let bubble = l.commit(
            inputs: [.de: " Pourriez-vous me dire où se trouve la gare, s'il vous plaît?",
                     .es: " Pourriez-vous me dire où se trouve la gare, s'il vous plaît?"],
            outputs: [.de: "Könnten Sie mir bitte sagen, wo der Bahnhof ist?",
                      .es: "¿Podría decirme dónde está la estación, por favor?"])
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "Könnten Sie mir bitte sagen, wo der Bahnhof ist?")
        XCTAssertEqual(l.translator, .de)
    }

    // L1.47e — the veto yields ONLY to the partner language. Codes settled
    // on a language that is NEITHER side mean no session translated into
    // the home reader's language, so there is still nothing legal to show
    // — the turn is rejected, exactly as before #75.
    func testL1_47e_neitherSideSettleStillVetoes() {
        var l = TurnLogic(home: .de, partner: .es)
        settle(&l, "fr", at: t(0))
        let bubble = l.commit(
            inputs: [.es: " Um, mir geht es sehr gut. Vielen Dank für die Nachfrage."],
            outputs: [.es: "Este, me siento muy bien. Muchas gracias por preguntar."])
        XCTAssertNil(bubble, "a neither-side settle has no translation to trust")
        XCTAssertEqual(l.lastRejectReason,
                       "codes-veto: settled fr, home session never translated")
    }

    // L1.47f — the yield needs POSITIVE evidence that home speech was
    // spoken. Real Spanish has both sessions voting es — the partner
    // corroborates its own settle (30/30 in the kept logs), so the veto
    // holds and the echo is dropped. And a settle with no partner-session
    // votes at all is testimony from one witness: veto.
    func testL1_47f_vetoYieldNeedsAProvenTranslation() {
        var echoed = TurnLogic(home: .de, partner: .es)
        settle(&echoed, "es", at: t(0), from: .de)
        settle(&echoed, "es", at: t(0.2), from: .es)   // real Spanish: es-session agrees
        XCTAssertNil(echoed.commit(
            inputs: [.de: " ¿Dónde está la estación de tren?",
                     .es: " ¿Dónde está la estación de tren?"],
            outputs: [.es: "¿Dónde está la estación de tren?"]),
            "a partner echo of foreign speech must stay vetoed")

        var unheard = TurnLogic(home: .de, partner: .es)
        settle(&unheard, "es", at: t(0))   // home-session votes only
        XCTAssertNil(unheard.commit(
            inputs: [:],
            outputs: [.es: "Este, me siento muy bien. Muchas gracias por preguntar."]),
            "a settle the partner session never testified about is no evidence of home speech")
    }

    // L1.47h — the crossed misreading (after-run 1, 2026-08-07, verbatim):
    // BOTH sessions misread half the German, complementarily. The de
    // session's transcript converged on near-Spanish — nearly the same
    // Spanish the es session legitimately translated into — and its German
    // output lives in the ES transcript, not its own. The union echo test
    // still sees the home output for the round trip it is, and the crossed
    // votes carry the yield, so the turn commits RIGHT. The first cut of
    // #75 (token overlap both ways) swallowed this turn; the pre-#75 code
    // committed it LEFT. Both were wrong.
    func testL1_47h_crossedMisreadingStillLandsRight() {
        var l = TurnLogic(home: .de, partner: .es)
        settleCrossed(&l, at: t(0))
        let bubble = l.commit(
            inputs: [.de: " Me va muy bien. Muchas gracias por la pregunta. ¿Y cómo está usted hoy en este bonito tiempo?",
                     .es: " Me geht es sehr gut. Vielen Dank für die Nachfrage. Und wie geht es Ihnen heute bei diesem schönen Wetter?"],
            outputs: [.de: " Ich mir geht es sehr gut. Vielen Dank für die Frage. Und wie geht es Ihnen heute an diesem schönen Wetter?",
                      .es: "Me va muy bien. Muchas gracias por preguntar. ¿Y cómo está usted hoy con este clima tan bonito?"])
        XCTAssertEqual(bubble?.isHome, true,
                       "the home output is an echo of the union; the partner's own votes prove home speech")
        XCTAssertEqual(l.translator, .es)
    }

    // L1.47g — the live path (noteOutputs) reaches the same verdict as
    // commit: with the crossed votes settled on the partner, home-session
    // output that is only an echo does not block the home-silence
    // confirmation.
    func testL1_47g_noteOutputsResolvesHomeSpokenThroughTheYield() {
        var l = TurnLogic(home: .de, partner: .es)
        settleCrossed(&l, at: t(0))
        l.noteOutputs(Self.run6Outputs, inputs: Self.run6Inputs, at: t(2))
        XCTAssertNil(l.direction, "confirm window hasn't elapsed yet")
        l.noteOutputs(Self.run6Outputs, inputs: Self.run6Inputs,
                      at: t(2 + TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertEqual(l.direction, .homeSpoken)
        XCTAssertEqual(l.translator, .es)
    }

    // MARK: - #83: the shipped #77 blockers, each pinned by the review's own
    // reproduction before the fix existed. Verified failing against the
    // shipped code (main @ 1debd7c) before the rules changed — see the PR.

    /// The transcripts here are keyed to the session that HEARD the speech —
    /// #83's reproduction note: keyed the other way, all five cases pass on
    /// the shipped code too and the defect looks absent.
    private static let restatementRows: [(heard: String, echoed: String)] = [
        ("How much are these items?", "How much is this item?"),
        ("How much is such an item?", "How much is this item?"),
        ("Can you help me with my bags?", "Could you help me with the bag?"),
        ("I would like to book two rooms", "I'd like to book a room"),
        ("Where are the train stations?", "Where is the train station?"),
    ]

    // L1.48 — #83's table: an English paraphrase-echo of English speech is
    // NOT a translation, whatever plurals and apostrophes do to the token
    // overlap. All five rows drop; before this fix, rows 1, 3 and 4
    // committed the partner's speech into a RIGHT/home bubble because
    // "these items"/"this item" happened to tokenize differently.
    func testL1_48_nearRestatementsNeverCommitHome() {
        for (heard, echoed) in Self.restatementRows {
            var l = TurnLogic()   // de↔en
            settle(&l, "en", at: t(0))   // de session votes en; en session says "ja" (unmappable)
            let bubble = l.commit(inputs: [.en: heard], outputs: [.en: echoed])
            XCTAssertNil(bubble,
                         "\"\(heard)\" → \"\(echoed)\" is a restatement of foreign speech, not home speech")
            XCTAssertTrue(l.lastRejectReason?.contains("codes-veto") ?? false)
        }
    }

    // L1.49 — the #77 review's entity list, settled codes: a genuine home
    // translation that preserves names scores 0.80 token overlap, and the
    // shipped echo rule dropped it via the veto. Names surviving translation
    // are what a CORRECT translation of this sentence looks like; with no
    // evidence that home speech was spoken, the echo rule stays out of it.
    func testL1_49_entityPreservingTranslationLandsLeftWithSettledCodes() {
        var l = TurnLogic()   // de↔en
        settle(&l, "en", at: t(0))
        let bubble = l.commit(
            inputs: [.de: "Apple, Google, Netflix and Amazon.",
                     .en: "Apple, Google, Netflix and Amazon."],
            outputs: [.de: "Apple, Google, Netflix und Amazon.",
                      .en: "Apple, Google, Netflix and Amazon."])
        XCTAssertEqual(bubble?.isHome, false, "an entity list is translated, not echoed")
        XCTAssertEqual(bubble?.translation, "Apple, Google, Netflix und Amazon.")
        XCTAssertEqual(l.translator, .de)
    }

    // L1.49b — the same turn with the codes NOT yet settled: the round-2
    // review's independently-reproduced worse case. The shipped code
    // disqualified the home translation, then resolved home-spoken off the
    // partner echo — original AND "translation" both the English source, on
    // the RIGHT, before language voting had settled. Prices, addresses and
    // numeric lists arrive exactly in that window.
    func testL1_49b_entityPreservingTranslationLandsLeftBeforeCodesSettle() {
        var l = TurnLogic()   // de↔en, no codes at all
        let inputs: [TurnLogic.Lang: String] = [
            .de: "Apple, Google, Netflix and Amazon.",
            .en: "Apple, Google, Netflix and Amazon.",
        ]
        let outputs: [TurnLogic.Lang: String] = [
            .de: "Apple, Google, Netflix und Amazon.",
            .en: "Apple, Google, Netflix and Amazon.",
        ]
        l.noteOutputs(outputs, inputs: inputs, at: t(0))
        XCTAssertEqual(l.direction, .foreignSpoken,
                       "the home translation is real; nothing says home speech was spoken")
        let bubble = l.commit(inputs: inputs, outputs: outputs)
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "Apple, Google, Netflix und Amazon.")
        XCTAssertEqual(l.translator, .de)
    }

    // L1.50 — the #77 review's incremental reproduction (run 6's real event
    // order): the home session's echo prefix arrives BEFORE the votes that
    // expose it, so streaming provisionally reads it as a translation. The
    // shipped code latched that first impression for the rest of the turn —
    // commit corrected the bubble, but the service had already flushed (and
    // wiped) held audio for the wrong session. A provisional direction must
    // re-derive when the evidence changes; only a COMMITTED one is final.
    func testL1_50_provisionalForeignReDerivesWhenEchoEvidenceArrives() {
        var l = TurnLogic(home: .de, partner: .es)
        // 10.9s: first output chunks, echo not yet recognizable, no votes.
        l.noteOutputs([.de: "Ich", .es: "Este,"],
                      inputs: [.de: " Me", .es: " Um,"], at: t(0.3))
        // 11.9s: the de session is echoing at full length; still no votes.
        // The ratio path provisionally reads it as a translation — accepted.
        l.noteOutputs([.de: "Ich komme sehr gut zurecht, vielen Dank für die Nachfrage.",
                       .es: "Este, me siento muy bien. Muchas"],
                      inputs: [.de: " Me va muy bien, vielen Dank",
                               .es: " Um, mir geht es sehr gut. Vielen Dank"], at: t(1.3))
        XCTAssertEqual(l.direction, .foreignSpoken, "provisional — evidence so far supports it")
        // 12.6s onward: the crossed votes land.
        settleCrossed(&l, at: t(2))
        // The next streamed output re-derives: the echo is now corroborated.
        l.noteOutputs(Self.run6Outputs, inputs: Self.run6Inputs, at: t(4))
        XCTAssertNil(l.direction,
                     "the provisional foreign direction must clear when the echo evidence arrives")
        XCTAssertNil(l.translator, "stale translator here is what played the echo aloud")
        // …and the home-silence confirmation then resolves the true side.
        l.noteOutputs(Self.run6Outputs, inputs: Self.run6Inputs,
                      at: t(4 + TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertEqual(l.direction, .homeSpoken)
        XCTAssertEqual(l.translator, .es)
        let bubble = l.commit(inputs: Self.run6Inputs, outputs: Self.run6Outputs)
        XCTAssertEqual(bubble?.isHome, true)
    }

    // L1.51 — the echo floor is two-sided, as documented since #75 but
    // enforced only on the output side until the round-2 review caught it:
    // four output tokens judged against ONE heard token is a ratio built on
    // nothing. A stammered repetition of a name is not an echo of a turn.
    func testL1_51_echoJudgmentNeedsFourTokensHeardToo() {
        var l = TurnLogic(home: .de, partner: .es)
        settleCrossed(&l, at: t(0))   // corroboration present — isolates the floor
        let bubble = l.commit(
            inputs: [.es: "Navigator"],
            outputs: [.de: "Navigator, Navigator. Navigator! Navigator",
                      .es: "Navegador, sí"])
        XCTAssertEqual(bubble?.isHome, false,
                       "one heard token cannot convict a four-token output of echoing")
    }

    // MARK: - The #84 review's reproduced sequences. Each was demonstrated
    // against this PR's first cut before the rule below existed; "an
    // observed count of zero is not a safety guard."

    // L1.54 — ONE stray partner vote for home must not lift the veto. The
    // review reproduced: fresh foreign en settle + a single partner de vote
    // committed an English echo as a RIGHT/home bubble. Corroboration needs
    // a quorum, because a lone stray is exactly what lying codes emit.
    func testL1_54_oneStrayPartnerVoteDoesNotLiftTheVeto() {
        var l = TurnLogic()   // de↔en
        settle(&l, "en", at: t(0))                      // real English settle
        l.noteInputLanguage("de", from: .en, at: t(2))  // one stray
        XCTAssertNil(l.commit(inputs: [.en: "Do you want sauce?"],
                              outputs: [.en: "Do you want sauce?"]),
                     "one stray home vote is noise, not testimony")
        XCTAssertTrue(l.lastRejectReason?.contains("codes-veto") ?? false)
    }

    // L1.54b — a quorum of stray HOME votes amid a run of unmapped codes
    // must not lift the veto either: the unmapped codes ("ja"/"pt", the
    // measured self-target lie) are competing testimony from the same
    // session and weigh against the plurality.
    func testL1_54b_unmappedCodesWeighAgainstThePlurality() {
        var l = TurnLogic()   // de↔en
        settle(&l, "en", at: t(0))
        for i in 0..<6 { l.noteInputLanguage("ja", from: .en, at: t(2 + Double(i))) }
        l.noteInputLanguage("de", from: .en, at: t(8.2))
        l.noteInputLanguage("de", from: .en, at: t(8.4))   // quorum met, but ja×6 outweighs
        XCTAssertNil(l.commit(inputs: [.en: "Do you want sauce?"],
                              outputs: [.en: "Do you want sauce?"]),
                     "two home votes against six unmapped ones is not a plurality")
    }

    // L1.55 — per-session evidence expires WITH the global vote context.
    // The review reproduced: partner-home votes from a dead context (gap >
    // voteExpiry) survived the global reset and lifted a fresh foreign
    // settle's veto, committing the echoed foreign sentence RIGHT.
    func testL1_55_sessionVotesExpireWithTheGlobalTally() {
        var l = TurnLogic()   // de↔en
        l.noteInputLanguage("de", from: .en, at: t(0))     // old context:
        l.noteInputLanguage("de", from: .en, at: t(1.0))   // partner reads home
        // > voteExpiry of silence — the context is dead.
        settle(&l, "en", at: t(0 + TurnLogic.voteExpiry + 2))
        XCTAssertNil(l.commit(inputs: [.en: "Do you want sauce?"],
                              outputs: [.en: "Do you want sauce?"]),
                     "testimony from an expired context is no corroboration")
    }

    // L1.56 — a provisional homeSpoken clears when a LATE foreign settle
    // arms the veto. The review's sequence: partner output resolves
    // homeSpoken before any code arrives; the foreign codes then settle;
    // the stale homeSpoken kept `translator` pointing at the partner, and
    // the service flushed — and deleted — held audio for it even though
    // commit went on to reject the turn. Both provisional directions are
    // provisional; only a COMMITTED one is final (R1/#26).
    func testL1_56_lateForeignSettleClearsProvisionalHomeSpoken() {
        var l = TurnLogic()   // de↔en
        let outputs: [TurnLogic.Lang: String] = [.en: "Do you want caramel sauce?"]
        l.noteOutputs(outputs, inputs: [:], at: t(0))
        l.noteOutputs(outputs, inputs: [:], at: t(TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertEqual(l.direction, .homeSpoken, "provisional — no codes yet")
        settle(&l, "en", at: t(2))   // the veto arrives late
        l.noteOutputs(outputs, inputs: [.en: "Do you want caramel sauce?"], at: t(4))
        XCTAssertNil(l.direction,
                     "a homeSpoken the veto now bars must clear, or its translator flushes the echo")
        XCTAssertNil(l.translator)
        XCTAssertNil(l.commit(inputs: [.en: "Do you want caramel sauce?"], outputs: outputs))
    }

    // L1.57 — the run-6 event order, interleaved as the SERVICE sees it:
    // outputs and codes strictly by timestamp, `noteOutputs` re-run after
    // each code event exactly as the service now does. The direction must
    // travel provisional-foreign → cleared → homeSpoken, and the translator
    // at every audio-decision point is asserted — this is the deterministic
    // production-order test the review asked for in place of unattached
    // live-replay claims.
    func testL1_57_run6InterleavedOrderEndsRightViaPartner() {
        var l = TurnLogic(home: .de, partner: .es)
        // 10.6-11.9s: both sessions' first transcripts and outputs; the de
        // echo's opening passes the ratio path — provisionally foreign.
        var inputs: [TurnLogic.Lang: String] = [.de: " Me", .es: " Um,"]
        var outputs: [TurnLogic.Lang: String] = [.de: "Ich", .es: "Este,"]
        l.noteOutputs(outputs, inputs: inputs, at: t(0.3))
        l.noteInputLanguage("es", from: .de, at: t(0.4))
        l.noteOutputs(outputs, inputs: inputs, at: t(0.4))   // the service re-derives after codes
        l.noteInputLanguage("en", from: .es, at: t(0.5))
        l.noteOutputs(outputs, inputs: inputs, at: t(0.5))
        inputs = [.de: " Me va muy bien, vielen Dank",
                  .es: " Um, mir geht es sehr gut. Vielen Dank"]
        outputs = [.de: "Ich komme sehr gut zurecht, vielen Dank für die Nachfrage.",
                   .es: "Este, me siento muy bien. Muchas"]
        l.noteOutputs(outputs, inputs: inputs, at: t(1.3))
        XCTAssertEqual(l.direction, .foreignSpoken, "the echo's opening reads as a translation so far")
        // 11.6-12.7s: the crossed votes land, one at a time, outputs
        // re-derived after each — the full crossed evidence arrives before
        // the silence confirmation.
        l.noteInputLanguage("es", from: .de, at: t(1.6))
        l.noteOutputs(outputs, inputs: inputs, at: t(1.6))
        l.noteInputLanguage("de", from: .es, at: t(1.7))
        l.noteOutputs(outputs, inputs: inputs, at: t(1.7))
        l.noteInputLanguage("es", from: .de, at: t(2.6))
        l.noteOutputs(outputs, inputs: inputs, at: t(2.6))
        l.noteInputLanguage("de", from: .es, at: t(2.7))
        inputs = Self.run6Inputs
        outputs = Self.run6Outputs
        l.noteOutputs(outputs, inputs: inputs, at: t(2.7))
        XCTAssertEqual(l.direction, .foreignSpoken,
                       "two partner-home reports are still below the evidence floor")
        XCTAssertNil(l.committedTranslator,
                     "provisional direction never authorizes audio release")
        // 12.7s+: home stays quiet while the partner translates on.
        l.noteInputLanguage("es", from: .de, at: t(3.6))
        l.noteOutputs(outputs, inputs: inputs, at: t(3.6))
        l.noteInputLanguage("de", from: .es, at: t(3.7))
        l.noteOutputs(outputs, inputs: inputs, at: t(3.7))
        XCTAssertNil(l.direction,
                     "the confirm clock starts only once the third partner report exposes the echo")
        l.noteOutputs(outputs, inputs: inputs,
                      at: t(3.7 + TurnLogic.homeSilenceConfirmDelay))
        XCTAssertEqual(l.direction, .homeSpoken)
        XCTAssertEqual(l.translator, .es, "the audio decision at speaker-stop picks the real translation")
        let bubble = l.commit(inputs: inputs, outputs: outputs)
        XCTAssertEqual(bubble?.isHome, true)
        XCTAssertEqual(l.translator, .es)
    }

    // L1.58 — two mapped home codes from the partner session are still
    // session-local noise, not enough to override a settled foreign veto.
    func testL1_58_twoMappedPartnerStraysDoNotLiftTheForeignVeto() {
        var l = TurnLogic()   // de↔en
        settle(&l, "en", at: t(0))
        l.noteInputLanguage("de", from: .en, at: t(2))
        l.noteInputLanguage("de", from: .en, at: t(2.1))
        XCTAssertFalse(l.partnerHeardHome, "two mapped strays do not meet the evidence floor")

        let echoed = "Where is the train station please"
        let inputs: [TurnLogic.Lang: String] = [.en: echoed]
        let outputs: [TurnLogic.Lang: String] = [.de: echoed, .en: echoed]
        l.noteOutputs(outputs, inputs: inputs, at: t(3))
        l.noteOutputs(outputs, inputs: inputs,
                      at: t(3 + TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertNotEqual(l.direction, .homeSpoken)
        XCTAssertNotEqual(l.commit(inputs: inputs, outputs: outputs)?.isHome, true)
    }

    // L1.59 — even a quorum of partner-home reports that arrives only AFTER
    // a real foreign verdict must not rewrite that verdict. The #75 signal
    // is crossed evidence that helped form the settle, not a late override.
    func testL1_59_postSettlePartnerQuorumDoesNotLiftTheForeignVeto() {
        var l = TurnLogic()   // de↔en
        settle(&l, "en", at: t(0))
        for i in 0..<3 { l.noteInputLanguage("de", from: .en, at: t(2 + Double(i) / 10)) }
        XCTAssertTrue(l.partnerHeardHome, "isolates timing rather than the quorum")
        XCTAssertEqual(l.spokenLang, .en,
                       "late partner-session reports cannot overturn the foreign settle")

        let echoed = "Where is the train station please"
        let inputs: [TurnLogic.Lang: String] = [.en: echoed]
        let outputs: [TurnLogic.Lang: String] = [.de: echoed, .en: echoed]
        l.noteOutputs(outputs, inputs: inputs,
                      at: t(3 + TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertNotEqual(l.direction, .homeSpoken)
        XCTAssertNotEqual(l.commit(inputs: inputs, outputs: outputs)?.isHome, true)
    }

    // L1.60 — real #75 crossed evidence remains valid when its quorum is
    // completed after the global partner-language settle: it is enough that
    // the partner had already testified HOME before that settle formed.
    func testL1_60_crossedEvidenceCanCompleteAfterPartnerSettle() {
        var l = TurnLogic(home: .de, partner: .es)
        l.noteInputLanguage("es", from: .de, at: t(0))
        l.noteInputLanguage("de", from: .es, at: t(0.1)) // before the settle
        l.noteInputLanguage("es", from: .de, at: t(0.5))
        l.noteInputLanguage("es", from: .de, at: t(1.0))
        l.noteInputLanguage("es", from: .de, at: t(1.6)) // settles es
        l.noteInputLanguage("de", from: .es, at: t(1.7))
        l.noteInputLanguage("de", from: .es, at: t(1.8))
        XCTAssertTrue(l.partnerHeardHome)

        let german = "Mir geht es sehr gut vielen Dank fuer die Nachfrage"
        let inputs: [TurnLogic.Lang: String] = [.de: german, .es: german]
        let outputs: [TurnLogic.Lang: String] = [.de: german,
                                                  .es: "Me siento muy bien muchas gracias"]
        l.noteOutputs(outputs, inputs: inputs, at: t(2))
        l.noteOutputs(outputs, inputs: inputs,
                      at: t(2 + TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertEqual(l.direction, .homeSpoken)
        XCTAssertEqual(l.commit(inputs: inputs, outputs: outputs)?.isHome, true)
    }

    // L1.61 — a SETTLED stale context expires as a whole. The earlier L1.55
    // only covered an unsettled tally, leaving old partner evidence alive
    // across a later overturn.
    func testL1_61_settledVoteContextExpiresAsAWhole() {
        var l = TurnLogic()   // de↔en
        settle(&l, "de", at: t(0), from: .en) // partner's old HOME evidence
        XCTAssertEqual(l.spokenLang, .de)
        settle(&l, "en", at: t(TurnLogic.voteExpiry + 2), from: .de)
        XCTAssertEqual(l.spokenLang, .en)

        let echoed = "I would like two rooms for tonight"
        let inputs: [TurnLogic.Lang: String] = [.en: echoed]
        let outputs: [TurnLogic.Lang: String] = [.de: echoed, .en: echoed]
        XCTAssertNotEqual(l.commit(inputs: inputs, outputs: outputs)?.isHome, true,
                          "old partner evidence cannot survive into a fresh foreign turn")
    }

    // L1.62 — playback has a separate pure gate. A provisional translator
    // may be useful for the live line, but it cannot authorize irreversible
    // PCM before a successful commit.
    func testL1_62_onlyCommittedTranslatorMayReleaseAudio() {
        var provisional = TurnLogic()
        let echoed = "Do you want caramel sauce today"
        let outputs: [TurnLogic.Lang: String] = [.en: echoed]
        provisional.noteOutputs(outputs, inputs: [:], at: t(0))
        provisional.noteOutputs(outputs, inputs: [:],
                                at: t(TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertEqual(provisional.translator, .en)
        XCTAssertNil(provisional.committedTranslator)
        settle(&provisional, "en", at: t(2))
        provisional.noteOutputs(outputs, inputs: [.en: echoed], at: t(4))
        XCTAssertNil(provisional.committedTranslator)
        XCTAssertNil(provisional.commit(inputs: [.en: echoed], outputs: outputs))

        var committed = TurnLogic()
        XCTAssertNotNil(committed.commit(inputs: [.en: "Good morning Heiko"],
                                         outputs: [.de: "Guten Morgen Heiko"]))
        XCTAssertEqual(committed.committedTranslator, .de)
    }

    // MARK: - A corroborated home settle outranks the home session's output

    /// The exact code events from device build 2.3.48, 2026-08-10 — one
    /// German turn, replayed by timestamp. Times are seconds from the first
    /// code; `de` is home and `en` the partner. The home session reads the
    /// German as English nine times (its own mis-hearing) while the partner
    /// session reads it correctly as German nine times.
    private static let deviceCrossedCodes: [(t: TimeInterval, code: String, from: TurnLogic.Lang)] = [
        (0.000, "de", .en), (0.067, "de", .de),
        (0.983, "en", .de), (1.009, "de", .en),
        (2.036, "de", .en), (2.038, "en", .de),
        (2.984, "en", .de), (3.044, "de", .en),
        (3.999, "en", .de), (4.015, "de", .en),
        (5.112, "de", .en), (5.122, "en", .de),
        (6.105, "en", .de), (6.131, "de", .en),
        (6.960, "en", .de), (6.960, "de", .en),
        (7.947, "en", .de), (7.984, "de", .en),
        (9.964, "en", .de),
    ]

    private func replayDeviceCrossedCodes(_ logic: inout TurnLogic, from base: Date) {
        for e in Self.deviceCrossedCodes {
            logic.noteInputLanguage(e.code, from: e.from, at: base.addingTimeInterval(e.t))
        }
    }

    /// Home speech. The home session's "translation" is its own mis-hearing
    /// read back at full length; the partner session's is the real one.
    private static let crossedHomeInputs: [TurnLogic.Lang: String] = [
        .de: "Big Mac and extra spicy to take away please",
        .en: "Einen Big Mac und extra scharf zum Mitnehmen bitte"
    ]

    /// L1.64 — the measured 2.3.48 turn. The codes settle on HOME two seconds
    /// in and never move, and the partner session's own votes agree. Yet
    /// `noteOutputs` consulted `homeIsRealTranslation` first, and its size
    /// ratio kept calling the home session's echo a real translation as the
    /// text streamed: the direction flipped six times in four seconds while
    /// the speaker was still talking. Two witnesses agreeing on home must not
    /// be overruled by the output of the one session known to be mis-hearing.
    func testL1_64_corroboratedHomeSettleDoesNotOscillate() {
        var l = TurnLogic(home: .de, partner: .en)
        replayDeviceCrossedCodes(&l, from: t(0))
        XCTAssertEqual(l.spokenLang, .de, "the measured codes settle on home")
        XCTAssertTrue(l.partnerHeardHome, "and the partner session independently agrees")

        // Stream BOTH outputs word by word, as the sessions actually deliver
        // them. The early steps are the dangerous ones: a home output of
        // three tokens or fewer cannot be a round-trip echo (`echoMinTokens`
        // is 4), so the echo guard is inert and the size ratio decides — and
        // a short echo prefix beside a short real translation clears the 0.4
        // floor easily. That is the window the device fell through.
        var flips = 0
        var previous: TurnLogic.Direction?
        let homeWords = Self.crossedHomeInputs[.de]!.split(separator: " ")
        let partnerWords = Self.crossedHomeInputs[.en]!.split(separator: " ")
        for step in 1...max(homeWords.count, partnerWords.count) {
            l.noteOutputs([.de: homeWords.prefix(step).joined(separator: " "),
                           .en: partnerWords.prefix(step).joined(separator: " ")],
                          inputs: Self.crossedHomeInputs,
                          at: t(10 + Double(step) * 0.3))
            if l.direction != previous { flips += 1; previous = l.direction }
            XCTAssertNotEqual(l.direction, .foreignSpoken,
                              "step \(step): read foreign against a corroborated home settle")
        }
        XCTAssertEqual(l.direction, .homeSpoken)
        XCTAssertEqual(l.translator, .en)
        XCTAssertLessThanOrEqual(flips, 1, "the side must settle once, not oscillate")
    }

    /// L1.64b — commit reaches the same verdict on that state. The two share
    /// `homeIsRealTranslation` precisely so the live line and the bubble
    /// cannot disagree about the side (L1.47g), so the gate has to apply to
    /// both or it reintroduces the disagreement it exists to prevent.
    func testL1_64b_commitAgreesWithTheLivePath() {
        var l = TurnLogic(home: .de, partner: .en)
        replayDeviceCrossedCodes(&l, from: t(0))
        let bubble = l.commit(inputs: Self.crossedHomeInputs,
                              outputs: [.de: Self.crossedHomeInputs[.de]!,
                                        .en: Self.crossedHomeInputs[.en]!])
        XCTAssertNotNil(bubble, "reason: \(l.lastRejectReason ?? "none")")
        XCTAssertEqual(bubble?.isHome, true, "German speech belongs on the RIGHT")
        XCTAssertEqual(l.translator, .en)
    }

    /// L1.64c — the discriminator, and the reason this is not "a home settle
    /// wins". L1.20 is a measured turn where the codes lie about home and the
    /// home session's substantial translation is right to beat them. There
    /// the partner session never votes, so there is no corroboration and the
    /// old path must still run. Same shape, asserted directly.
    func testL1_64cAnUncorroboratedHomeSettleStillLosesToARealTranslation() {
        var l = TurnLogic(home: .de, partner: .es)
        settle(&l, "de-DE", from: .de)          // only the home session votes
        XCTAssertEqual(l.spokenLang, .de)
        XCTAssertFalse(l.partnerHeardHome, "no partner votes — nothing corroborates")

        let bubble = l.commit(inputs: [.de: "Do you want caramel sauce?"],
                              outputs: [.de: "Möchten Sie Karamellsauce?",
                                        .es: "¿Quieres salsa de caramelo?"])
        XCTAssertEqual(bubble?.isHome, false, "L1.20 must be untouched")
    }

    /// L1.64e — the pooled settle is NOT an independent witness. `spokenLang`
    /// is settled from the pooled tally, and that tally already contains the
    /// partner session's votes, so a partner session that emits a quorum of
    /// stray home codes and nothing else satisfies BOTH halves by itself: it
    /// carries the pooled tally to home and clears `partnerHeardHome` with the
    /// same three votes. Nothing about that is corroboration.
    ///
    /// This is an ordinary foreign turn — English spoken, the home session
    /// producing a real German translation, the partner session echoing the
    /// English — and it must still commit LEFT via the home session (L1.20's
    /// rule). Caught in review of #47.
    func testL1_64e_partnerNoiseAloneIsNotCorroboration() {
        var l = TurnLogic(home: .de, partner: .en)
        settle(&l, "de", at: t(0), from: .en)      // three stray partner votes, nothing else
        XCTAssertEqual(l.spokenLang, .de, "the stray votes carry the pooled tally by themselves")
        XCTAssertTrue(l.partnerHeardHome, "…and clear the quorum with the very same votes")
        XCTAssertFalse(l.homeHeardPartner, "the home session never reported the partner language")

        let bubble = l.commit(inputs: [.en: "Where is the station, please?"],
                              outputs: [.de: "Wo ist der Bahnhof, bitte?",
                                        .en: "Where is the station, please?"])
        XCTAssertEqual(bubble?.isHome, false,
                       "a real home translation still means foreign speech (L1.20)")
        XCTAssertEqual(l.translator, .de)
    }

    /// L1.64d — a foreign settle is not affected either. Corroboration only
    /// speaks where the pooled codes already said HOME; everywhere else the
    /// existing veto and its narrow crossed-evidence yield still govern.
    func testL1_64d_aForeignSettleIsUnaffected() {
        var l = TurnLogic(home: .de, partner: .en)
        settle(&l, "en", at: t(0), from: .de)
        XCTAssertEqual(l.spokenLang, .en)
        l.noteOutputs([.de: "Wo ist der Bahnhof, bitte?"],
                      inputs: [.en: "Where is the station, please?"], at: t(10))
        XCTAssertEqual(l.direction, .foreignSpoken)
    }
}

/// Filler-word stripping — unchanged semantics, still German/English/Spanish
/// only. Languages without a studied list are left byte-identical.
final class FillerWordTests: XCTestCase {

    func testStripsEnglishHesitationAndRecapitalises() {
        XCTAssertEqual(FillerWords.strip("Um, so sorry, we're out of pickles.", isGerman: false),
                       "So sorry, we're out of pickles.")
    }

    func testStripsGermanHesitation() {
        XCTAssertEqual(FillerWords.strip("Ähm, ich hätte gerne einen Kaffee.", isGerman: true),
                       "Ich hätte gerne einen Kaffee.")
        XCTAssertEqual(FillerWords.strip("Ich hätte gerne äh acht Menüs davon", isGerman: true),
                       "Ich hätte gerne acht Menüs davon")
    }

    func testSentenceAfterRemovedFillerIsRecapitalised() {
        XCTAssertEqual(FillerWords.strip("Oh, das ist wunderbar. Ähm, das hätte ich gerne.", isGerman: true),
                       "Oh, das ist wunderbar. Das hätte ich gerne.")
    }

    func testTrailingFillerKeepsPunctuation() {
        XCTAssertEqual(FillerWords.strip("Das hätte ich gerne ähm.", isGerman: true),
                       "Das hätte ich gerne.")
        XCTAssertEqual(FillerWords.strip("I'd like that, um.", isGerman: false),
                       "I'd like that.")
    }

    func testPureFillerBecomesEmpty() {
        XCTAssertEqual(FillerWords.strip("Um, uh, umm", isGerman: false), "")
        XCTAssertEqual(FillerWords.strip("Ähm.", isGerman: true), "")
    }

    // The seven false positives from the 2026-07-28 adversarial review stay
    // impossible: real words survive.
    func testRealWordsSurvive() {
        XCTAssertEqual(FillerWords.strip("Die Schraube ist 6 mm lang.", isGerman: true),
                       "Die Schraube ist 6 mm lang.")
        XCTAssertEqual(FillerWords.strip("Mhm.", isGerman: true), "Mhm.")
        XCTAssertEqual(FillerWords.strip("Hm, ja.", isGerman: true), "Hm, ja.")
        XCTAssertEqual(FillerWords.strip("Cuesta 500 pesos, ¿eh?", isGerman: false),
                       "Cuesta 500 pesos, ¿eh?")
        XCTAssertEqual(FillerWords.strip("Er ist schon da.", isGerman: true), "Er ist schon da.")
        XCTAssertEqual(FillerWords.strip("Take me to the ER.", isGerman: false),
                       "Take me to the ER.")
        XCTAssertEqual(FillerWords.strip("We should err on the side of caution.", isGerman: false),
                       "We should err on the side of caution.")
    }

    // Clean text comes back byte-identical (no re-capitalisation drift).
    func testCleanTextByteIdentical() {
        for (text, isGerman) in [("Ich komme am 3. oder 4. Mai.", true),
                                 ("Das ist gut. iPhone ist teuer.", true),
                                 ("Meet me at 5 p.m. tomorrow", false)] {
            XCTAssertEqual(FillerWords.strip(text, isGerman: isGerman), text)
        }
    }

    // Unstudied languages are never touched, even when they contain tokens
    // that happen to look like English fillers.
    func testUnstudiedLanguagesUntouched() {
        XCTAssertEqual(FillerWords.strip("Um, je voudrais un café.", for: .fr),
                       "Um, je voudrais un café.")
        XCTAssertEqual(FillerWords.strip("음, 커피 주세요.", for: .ko), "음, 커피 주세요.")
        XCTAssertEqual(FillerWords.strip("嗯，我要一杯咖啡。", for: .zh), "嗯，我要一杯咖啡。")
    }

    // The pair-based commit cleans both lines with each line's own rules.
    func testCommitCleansBothLines() {
        var l = TurnLogic()
        let bubble = l.commit(
            inputs: [.de: "Um, so sorry, we're out of pickles."],
            outputs: [.de: "Ähm, tut mir leid, wir haben keine Gurken.", .en: "echo"]
        )
        XCTAssertEqual(bubble?.original, "So sorry, we're out of pickles.")
        XCTAssertEqual(bubble?.translation, "Tut mir leid, wir haben keine Gurken.")
    }

    func testCommitDropsPureFillerTurn() {
        var l = TurnLogic()
        XCTAssertNil(l.commit(inputs: [.de: "Um, uh"], outputs: [.de: "Ähm, äh", .en: "Uh"]))
    }
}
