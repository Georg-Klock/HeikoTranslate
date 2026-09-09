import XCTest
@testable import HeikoTranslate

/// Four device failures with one shape between them: the turn went to the
/// wrong side, or to no side, while the evidence needed to route it was
/// present in the sessions' own votes and outputs and consulted by nothing.
/// Each case below is the logged vote sequence and output shape of one
/// measured turn (#150, #137, #125, #128), with the words replaced by
/// invented equivalents of the same structure. Every one drives the real
/// `TurnLogic`; every one failed before its rule landed.
final class RoutingWitnessTests: XCTestCase {

    private func t(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 700_000_000 + seconds)
    }

    /// One code from one session at one instant.
    private func vote(_ l: inout TurnLogic, _ code: String, from session: TurnLogic.Lang,
                      at seconds: TimeInterval) {
        _ = l.noteInputLanguage(code, from: session, at: t(seconds))
    }

    // MARK: #150 — settled home, committed foreign

    /// The logged turn, home Spanish for this test (the device pair had a
    /// non-German home too; home is a parameter). Pooled votes en×3 es×2
    /// settle on the partner inside the window; the home session's own run
    /// of home votes then overturns it, exactly as `sessions=en[es×9]
    /// es[en×4/es×5]` records, with the partner session's home reports
    /// declined from the count on the way (#83). The partner session
    /// translated correctly; the home session emitted a seven-token
    /// near-echo sharing four tokens with the input — 0.571 against the 0.6
    /// echo threshold, ratio 1.0 against the 0.4 floor.
    private func settledHomeTurn() -> (TurnLogic, [TurnLogic.Lang: String], [TurnLogic.Lang: String]) {
        var l = TurnLogic(home: .es, partner: .en)
        vote(&l, "en", from: .es, at: 0.0)
        vote(&l, "es", from: .en, at: 0.1)
        vote(&l, "en", from: .es, at: 0.2)
        vote(&l, "es", from: .en, at: 0.3)
        vote(&l, "en", from: .es, at: 1.6)     // pooled en×3 es×2 — settles en
        XCTAssertEqual(l.spokenLang, .en, "precondition: the pool settled on the partner")
        var now = 1.7
        for _ in 0..<3 {                       // the home session's own run overturns it
            vote(&l, "es", from: .es, at: now); now += 0.1
            vote(&l, "es", from: .en, at: now); now += 0.1
        }
        XCTAssertEqual(l.spokenLang, .es, "precondition: overturned to home by the home session")
        vote(&l, "es", from: .es, at: now); now += 0.1
        vote(&l, "en", from: .es, at: now); now += 0.1   // one stray, as logged: es[en×4/es×5]
        vote(&l, "es", from: .es, at: now); now += 0.1
        for _ in 0..<6 { vote(&l, "es", from: .en, at: now); now += 0.1 }
        XCTAssertTrue(l.decisionSummary.contains("es[en×4/es×5]"), "the logged tally — got: \(l.decisionSummary)")
        let heard = "Ah sí, estoy de acuerdo. Me gusta mucho esta ciudad."
        let inputs: [TurnLogic.Lang: String] = [.es: heard, .en: heard]
        let outputs: [TurnLogic.Lang: String] = [
            .en: "Oh yes, I agree. I like this city a lot.",
            .es: "De acuerdo, ah sí, nosotros estamos aquí.",
        ]
        XCTAssertEqual(TurnLogic.echoShare(of: outputs[.es]!, inputs: inputs), 4.0 / 7.0, accuracy: 0.001,
                       "precondition: the near-echo sits just under the threshold, as measured")
        XCTAssertTrue(l.decisionSummary.contains("partnerHeardHome=true"))
        return (l, inputs, outputs)
    }

    /// L1.102 — two witnesses for home outrank the home session's output.
    func testL1_102_concordantHomeCodesOutrankTheHomeSessionsNearEcho() {
        var (l, inputs, outputs) = settledHomeTurn()
        XCTAssertTrue(l.concordantHomeEvidence(outputs: outputs, inputs: inputs),
                      "both sessions and the settle say home, and the partner translated — got: \(l.decisionSummary)")

        let bubble = l.commit(inputs: inputs, outputs: outputs)
        XCTAssertEqual(bubble?.isHome, true, "home speech lands on the home side — got \(String(describing: bubble))")
        XCTAssertEqual(bubble?.translation, "Oh yes, I agree. I like this city a lot.",
                       "the partner session's translation is the one shown")
    }

    /// L1.102b — the live line agrees with the bubble: streaming output must
    /// not resolve foreign for the same turn.
    func testL1_102b_theLiveDirectionDoesNotFlipForeignOnTheNearEcho() {
        var (l, inputs, outputs) = settledHomeTurn()
        l.noteOutputs(outputs, inputs: inputs, at: t(10))
        XCTAssertNotEqual(l.direction, .foreignSpoken, "the live line must not cross to the foreign side")
        l.noteOutputs(outputs, inputs: inputs, at: t(10 + TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertEqual(l.direction, .homeSpoken)
    }

    /// L1.102c — L1.20 stands: with ONE witness for home (the pooled codes
    /// from the home session alone) the home session's substantial
    /// translation still decides the turn.
    func testL1_102c_aLoneHomeSettleStillYieldsToARealHomeTranslation() {
        var l = TurnLogic(home: .de, partner: .es)
        vote(&l, "de", from: .de, at: 0.0)
        vote(&l, "de", from: .de, at: 0.5)
        vote(&l, "de", from: .de, at: 1.6)
        XCTAssertEqual(l.spokenLang, .de)
        XCTAssertFalse(l.concordantHomeCodes, "no partner reading — one witness, not two")
        let bubble = l.commit(inputs: [.de: "Do you want caramel sauce?"],
                              outputs: [.de: "Möchten Sie Karamellsauce?", .es: "¿Quieres salsa de caramelo?"])
        XCTAssertEqual(bubble?.isHome, false)
    }

    /// L1.102d — concordant codes over an ECHOING partner do not override.
    /// Both sessions can hallucinate one wrong language together (#125
    /// measured it for a third language); if that ever lands on home while
    /// the speech is foreign, the partner session is echoing the foreign
    /// speech, and the home session's own translation keeps deciding.
    func testL1_102d_concordantCodesOverAnEchoingPartnerDoNotOverrideTheHomeTranslation() {
        var l = TurnLogic(home: .de, partner: .en)
        var now = 0.0
        for _ in 0..<4 {
            vote(&l, "de", from: .de, at: now); now += 0.3
            vote(&l, "de", from: .en, at: now); now += 0.3
        }
        let heard = "Could we get the bill and two more coffees, please?"
        let inputs: [TurnLogic.Lang: String] = [.de: heard, .en: heard]
        let outputs: [TurnLogic.Lang: String] = [
            .de: "Könnten wir die Rechnung und zwei weitere Kaffees bekommen, bitte?",
            .en: heard,
        ]
        XCTAssertTrue(l.concordantHomeCodes)
        XCTAssertFalse(l.concordantHomeEvidence(outputs: outputs, inputs: inputs),
                       "an echoing partner is not a witness for home")
        let bubble = l.commit(inputs: inputs, outputs: outputs)
        XCTAssertEqual(bubble?.isHome, false, "the home session's real translation still wins")
        XCTAssertEqual(bubble?.translation, outputs[.de])
    }

    // MARK: #137 — English on the home side, untranslated

    /// The logged shape: the home session votes the partner language, the
    /// partner session votes home, the opening votes settle home, the home
    /// session emits nothing, and the partner session's output is the
    /// English input word for word.
    private func echoedEnglishTurn() -> (TurnLogic, [TurnLogic.Lang: String], [TurnLogic.Lang: String]) {
        var l = TurnLogic(home: .de, partner: .en)
        vote(&l, "de", from: .en, at: 0.0)
        vote(&l, "de", from: .de, at: 0.1)
        vote(&l, "de", from: .en, at: 1.6)     // settles de on the opening votes
        var now = 1.7
        for _ in 0..<9 {
            vote(&l, "en", from: .de, at: now); now += 0.1   // the home session hears English
            vote(&l, "de", from: .en, at: now); now += 0.1   // the partner session reads it as German
        }
        XCTAssertEqual(l.spokenLang, .de, "precondition: the settle held, as logged")
        XCTAssertTrue(l.crossedEvidence, "precondition: the crossed shape, as logged")
        let heard = "Hi, welcome to the diner. No problem, I will be your server tonight."
        let inputs: [TurnLogic.Lang: String] = [.de: heard, .en: heard]
        let outputs: [TurnLogic.Lang: String] = [.de: "", .en: heard]
        return (l, inputs, outputs)
    }

    /// L1.103 — an output that repeats the input is not a translation, on
    /// the home side either. The turn waits for the missing home translation
    /// instead of committing the echo.
    func testL1_103_thePartnerSessionsEchoIsNotATranslation() {
        var (l, inputs, outputs) = echoedEnglishTurn()
        XCTAssertTrue(l.partnerEchoedForeignSpeech(outputs: outputs, inputs: inputs))

        let bubble = l.commit(inputs: inputs, outputs: outputs)
        XCTAssertNil(bubble, "English must not land on the home side with itself as the translation")
        XCTAssertNil(l.direction, "a rejection decides no side")
        XCTAssertFalse(l.abstained, "not a contradiction — a translation is missing, and may still arrive")
        XCTAssertTrue(FinalizePolicy.isRecoverable(l.lastRejectReason),
                      "the deferral machinery waits for the home translation — reason: \(l.lastRejectReason ?? "nil")")
    }

    /// L1.103b — and the live line never shows the echo as a home turn.
    func testL1_103b_theLiveDirectionNeverResolvesHomeOnAnEcho() {
        var (l, inputs, outputs) = echoedEnglishTurn()
        l.noteOutputs(outputs, inputs: inputs, at: t(10))
        l.noteOutputs(outputs, inputs: inputs, at: t(10 + TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertNil(l.direction, "home-session silence proves nothing while the partner is echoing")
    }

    /// L1.103c — the gate is the home session's own reading, not overlap. A
    /// home sentence made of names that survive translation overlaps its
    /// translation heavily and still commits, because the home session heard
    /// home.
    func testL1_103c_aNameHeavyHomeTurnStillCommitsWhenTheHomeSessionHeardHome() {
        var l = TurnLogic(home: .de, partner: .en)
        var now = 0.0
        for _ in 0..<4 {
            vote(&l, "de", from: .de, at: now); now += 0.3
            vote(&l, "de", from: .en, at: now); now += 0.3
        }
        let heard = "Apple, Google, Netflix und Amazon in Kalifornien."
        let inputs: [TurnLogic.Lang: String] = [.de: heard, .en: heard]
        let outputs: [TurnLogic.Lang: String] = [.de: "", .en: "Apple, Google, Netflix and Amazon in California."]
        XCTAssertGreaterThanOrEqual(TurnLogic.echoShare(of: outputs[.en]!, inputs: inputs), TurnLogic.echoShareThreshold,
                                    "precondition: overlap alone would call this an echo")
        XCTAssertFalse(l.partnerEchoedForeignSpeech(outputs: outputs, inputs: inputs))
        XCTAssertEqual(l.commit(inputs: inputs, outputs: outputs)?.isHome, true)
    }

    // MARK: #125 — a settle on a language in neither side of the pair

    /// L1.104 — the logged turn: the home session transcribes and votes
    /// Korean, the partner session transcribes the German correctly and votes
    /// home, the pool settles `ko`, both sessions produce full-length output.
    /// The pool is corrupt by its own verdict; the partner's reading routes
    /// the turn.
    func testL1_104_aThirdLanguageSettleYieldsToThePartnersOwnReading() {
        var l = TurnLogic(home: .de, partner: .en)
        vote(&l, "ko", from: .de, at: 0.0)
        vote(&l, "en", from: .en, at: 0.1)
        vote(&l, "ko", from: .de, at: 1.6)     // pooled ko×2 en×1 — settles ko
        XCTAssertEqual(l.spokenLang, .ko, "precondition: settled on a language in neither side")
        var now = 1.7
        for _ in 0..<10 {
            vote(&l, "de", from: .en, at: now); now += 0.1
            vote(&l, "ko", from: .de, at: now); now += 0.1
        }
        XCTAssertEqual(l.spokenLang, .ko, "the settle held, as logged")
        let inputs: [TurnLogic.Lang: String] = [
            .de: "누군가 소중한 사람을 떠나보낸 후에 우리는 양파링을 주문합니다",
            .en: "Nichtsdestotrotz hervorragend, wir würden gerne mit den Vorspeisen anfangen und die Zwiebelringe nehmen.",
        ]
        let outputs: [TurnLogic.Lang: String] = [
            .de: "Jemand hat einen geliebten Menschen verloren und beginnt dann zu sagen, wir hätten gerne die Zwiebelringe mit Ranch.",
            .en: "Nevertheless, excellent, we would like to start with the appetizers and take the onion rings.",
        ]
        XCTAssertTrue(l.thirdLanguageSettleOverruled(outputs: outputs, inputs: inputs), "got: \(l.decisionSummary)")

        let bubble = l.commit(inputs: inputs, outputs: outputs)
        XCTAssertEqual(bubble?.isHome, true, "German lands on the home side — got \(String(describing: bubble)); \(l.lastRejectReason ?? "")")
        XCTAssertEqual(bubble?.translation, outputs[.en])
    }

    /// L1.104b — with no partner reading for home the neither-side settle
    /// still vetoes: nothing on screen could be trusted.
    func testL1_104b_aThirdLanguageSettleWithoutAPartnerReadingStillVetoes() {
        var l = TurnLogic(home: .de, partner: .en)
        vote(&l, "ko", from: .de, at: 0.0)
        vote(&l, "ko", from: .en, at: 0.1)
        vote(&l, "ko", from: .de, at: 1.6)
        XCTAssertEqual(l.spokenLang, .ko)
        XCTAssertFalse(l.thirdLanguageSettleWithPartnerHome)
        let bubble = l.commit(inputs: [.de: "irgendwas", .en: "irgendwas"],
                              outputs: [.de: "", .en: "something or other, anyway"])
        XCTAssertNil(bubble)
        XCTAssertTrue(l.lastRejectReason?.contains("codes-veto") == true)
    }

    /// L1.104c — a partner-home quorum over a neither-side settle is not
    /// enough when the partner is echoing: codes plus content, or the veto
    /// stands.
    func testL1_104c_aThirdLanguageSettleWithAnEchoingPartnerStillVetoes() {
        var l = TurnLogic(home: .de, partner: .en)
        vote(&l, "ko", from: .de, at: 0.0)
        vote(&l, "ko", from: .en, at: 0.1)
        vote(&l, "ko", from: .de, at: 1.6)
        var now = 1.7
        for _ in 0..<3 { vote(&l, "de", from: .en, at: now); now += 0.1; vote(&l, "ko", from: .de, at: now); now += 0.1 }
        XCTAssertTrue(l.thirdLanguageSettleWithPartnerHome)
        let heard = "Could we get the bill and two more coffees, please?"
        let inputs: [TurnLogic.Lang: String] = [.de: "무언가 다른 것", .en: heard]
        let outputs: [TurnLogic.Lang: String] = [.de: "", .en: heard]
        XCTAssertFalse(l.thirdLanguageSettleOverruled(outputs: outputs, inputs: inputs))
        XCTAssertNil(l.commit(inputs: inputs, outputs: outputs))
        XCTAssertTrue(l.lastRejectReason?.contains("codes-veto") == true)
    }

    // MARK: #128 — the home function-word list

    /// L1.105 — the German list shares no word with the languages it ships
    /// against. `war` and `den` were both English nouns; `des` is the French
    /// plural article.
    func testL1_105_theHomeFunctionWordsCollideWithNoPartnerLanguage() {
        let list = TurnLogic.homeFunctionWords(for: .de)
        let english: Set<String> = ["war", "den", "was", "will", "hat", "man", "die", "in", "an", "am",
                                    "so", "also", "fast", "gift", "rat", "tag", "bad", "kind", "hut",
                                    "mist", "brief", "art", "arm", "lust", "boot", "fall", "hell",
                                    "stern", "toll", "wand", "bald", "ohm", "dank", "lag", "rang"]
        let spanish: Set<String> = ["el", "la", "los", "las", "un", "una", "de", "del", "en", "y", "o",
                                    "que", "es", "son", "no", "con", "por", "para", "mi", "mis", "tu",
                                    "su", "sus", "al", "se", "lo", "le", "como", "pero", "si", "muy",
                                    "más", "también", "ya", "hay", "está", "era", "fue", "ser", "sin"]
        XCTAssertTrue(list.isDisjoint(with: english), "English collisions: \(list.intersection(english))")
        XCTAssertTrue(list.isDisjoint(with: spanish), "Spanish collisions: \(list.intersection(spanish))")
        let french: Set<String> = ["le", "la", "les", "des", "un", "une", "du", "de", "et", "ou", "que",
                                   "qui", "est", "sont", "ne", "pas", "je", "tu", "il", "elle", "nous",
                                   "vous", "ils", "mon", "ma", "mes", "ton", "sa", "ses", "dans", "sur",
                                   "avec", "pour", "par", "mais", "si", "très", "aussi", "bien", "en", "au"]
        XCTAssertTrue(list.isDisjoint(with: french), "French collisions: \(list.intersection(french))")
        XCTAssertTrue(list.contains("und") && list.contains("ist"), "the measured corpus words stay")
    }

    /// L1.105b — an English sentence carrying both nouns, translated
    /// correctly, no longer reads as home speech.
    func testL1_105b_anEnglishSentenceWithWarAndDenDoesNotTripTheVeto() {
        let heard = "They went into the den and the war was over."
        let output = "Sie gingen in den Bau, und der Krieg war vorbei."
        XCTAssertFalse(TurnLogic.sharesHomeFunctionWords(output, inputs: [.de: heard, .en: heard], home: .de),
                       "two English nouns must not count as two German function words")
    }
}
