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

/// GitHub #159: the third-language override (#125, L1.104) took a partner
/// session's home votes plus "its output is not an echo" as proof that home
/// speech was spoken. A genuine translation of FOREIGN speech is not an echo
/// either, so one lying partner code stream turned Spanish into a home-side
/// bubble. The override now also needs the partner session's own transcript to
/// read as home-language text — evidence about the words, not the codes.
final class ThirdLanguageOverrideEvidenceTests: XCTestCase {

    private func t(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 700_000_000 + seconds)
    }

    /// The issue's shape: the pool settles `ko` on de↔en (the home session
    /// votes Korean), the partner session's codes vote German with a strict
    /// quorum, and the partner session translates whatever was said.
    private func thirdLanguageTurn() -> TurnLogic {
        var turn = TurnLogic(home: .de, partner: .en)
        _ = turn.noteInputLanguage("ko", from: .de, at: t(0))
        _ = turn.noteInputLanguage("de", from: .en, at: t(0.1))
        _ = turn.noteInputLanguage("ko", from: .de, at: t(1.6))
        for i in 0..<3 {
            _ = turn.noteInputLanguage("de", from: .en, at: t(1.7 + Double(i) * 0.2))
            _ = turn.noteInputLanguage("ko", from: .de, at: t(1.8 + Double(i) * 0.2))
        }
        return turn
    }

    /// L1.126 — the #159 failing case: Spanish speech, the partner session
    /// translating it correctly into English, its codes wrongly saying German.
    ///
    /// Fail-first: before the text witness this committed on the home side,
    /// Spanish as the "German" original with English beneath it.
    func testL1_126_foreignSpeechIsNotMadeHomeByLyingPartnerCodes() {
        var turn = thirdLanguageTurn()
        let spoken = "Necesitamos una mesa tranquila cerca de la ventana, por favor."
        let inputs: [TurnLogic.Lang: String] = [.de: spoken, .en: spoken]
        let outputs: [TurnLogic.Lang: String] = [.de: "", .en: "We need a quiet table near the window, please."]

        XCTAssertEqual(turn.spokenLang, .ko, "precondition: a neither-side settle")
        XCTAssertTrue(turn.thirdLanguageSettleWithPartnerHome, "precondition: the partner's codes say home")
        XCTAssertFalse(turn.thirdLanguageSettleOverruled(outputs: outputs, inputs: inputs),
                       "codes alone are not evidence the words were German")
        let bubble = turn.commit(inputs: inputs, outputs: outputs)
        XCTAssertNotEqual(bubble?.isHome, true, "Spanish must not land on the German side")
        XCTAssertTrue(turn.lastRejectReason?.contains("codes-veto") == true,
                      "the neither-side veto stands — got \(turn.lastRejectReason ?? "nil")")
        XCTAssertNil(turn.direction)
    }

    /// L1.126b — the live path, with a language on neither side whose partner
    /// output is a real translation: Korean speech translated into English.
    /// (English speech cannot reproduce this — into the English session it is
    /// always an echo of its own transcript, which the echo check already
    /// refuses.) The live line must not resolve home either.
    ///
    /// Fail-first: under the old rule the direction resolved `homeSpoken`.
    func testL1_126b_theLiveLineDoesNotResolveHomeOnForeignSpeech() {
        var turn = thirdLanguageTurn()
        let spoken = "창가 쪽에 조용한 자리 부탁드려요."
        let inputs: [TurnLogic.Lang: String] = [.de: spoken, .en: spoken]
        let outputs: [TurnLogic.Lang: String] = [.de: "", .en: "A quiet table by the window, please."]
        turn.noteOutputs(outputs, inputs: inputs, at: t(10))
        turn.noteOutputs(outputs, inputs: inputs, at: t(10 + TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertNotEqual(turn.direction, .homeSpoken)
        XCTAssertNotEqual(turn.commit(inputs: inputs, outputs: outputs)?.isHome, true)
    }

    /// L1.126c — the text witness itself: German with two function words reads
    /// as home; Spanish, English and Korean do not; one shared word is not
    /// enough; and a home without a measured list keeps the veto untouched.
    func testL1_126c_theTextWitness() {
        XCTAssertTrue(TurnLogic.readsAsHome("Wir hätten gerne die Zwiebelringe mit Ranch.", home: .de))
        XCTAssertFalse(TurnLogic.readsAsHome("Necesitamos una mesa tranquila cerca de la ventana.", home: .de))
        XCTAssertFalse(TurnLogic.readsAsHome("Could we get a quiet table by the window?", home: .de))
        XCTAssertFalse(TurnLogic.readsAsHome("창가 쪽 조용한 자리 있나요?", home: .de))
        XCTAssertFalse(TurnLogic.readsAsHome("Das Schnitzel, bitte.", home: .de), "one function word is not a witness")
        XCTAssertFalse(TurnLogic.readsAsHome("We would like the onion rings with ranch.", home: .en),
                       "no measured list for this home — inert, the veto keeps deciding")
    }
}

/// The words decide when the codes cannot (#177). Measured on device
/// 2026-09-17 on de↔en: three consecutive foreign turns refused, the correct
/// home translation produced and discarded each time, because the two sessions
/// named each other's languages and the crossed shape reads as the #75/#125
/// mis-hearing on the codes alone.
final class CrossedCodesForeignSpeechTests: XCTestCase {

    private func t(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
    }

    /// The crossed shape with the pooled settle placed where the device put
    /// it. Both sessions keep naming the other side's language for the whole
    /// turn, interleaved, so neither run of contradictions reaches
    /// `overturnVotes` — the device log's `de[en×8] en[de×9]`.
    private func crossedTurn(settle: TurnLogic.Lang) -> TurnLogic {
        var turn = TurnLogic(home: .de, partner: .en)
        let early: TurnLogic.Lang = settle == .en ? .de : .en
        let late: TurnLogic.Lang = settle == .en ? .en : .de
        let earlyCode = settle.rawValue
        let lateCode = (settle == .en ? TurnLogic.Lang.de : .en).rawValue
        _ = turn.noteInputLanguage(earlyCode, from: early, at: t(0))
        _ = turn.noteInputLanguage(earlyCode, from: early, at: t(0.2))
        _ = turn.noteInputLanguage(lateCode, from: late, at: t(0.4))
        _ = turn.noteInputLanguage(earlyCode, from: early, at: t(1.6))
        for i in 0..<4 {
            _ = turn.noteInputLanguage("en", from: .de, at: t(2.0 + Double(i) * 0.4))
            _ = turn.noteInputLanguage("de", from: .en, at: t(2.2 + Double(i) * 0.4))
        }
        return turn
    }

    private let spoken = "I'm doing great. Welcome — what can I get for you?"
    private let translated = "Mir geht es gut, und was kann ich dir bringen?"

    private var foreignTurnText: (inputs: [TurnLogic.Lang: String], outputs: [TurnLogic.Lang: String]) {
        ([.de: spoken, .en: spoken], [.de: translated, .en: spoken])
    }

    /// L1.127 — the settle on the partner language. The #125 abstention reads
    /// the crossed codes as two contradictory accounts of one utterance; the
    /// transcripts are not in contradiction at all, and they are foreign.
    ///
    /// Fail-first: `abstained: sessions transcribed each other's languages`.
    func testL1_127_crossedCodesOnForeignSpeechCommitForeign() {
        var turn = crossedTurn(settle: .en)
        let (inputs, outputs) = foreignTurnText
        XCTAssertEqual(turn.spokenLang, .en, "precondition: the pool settled on the partner language")
        XCTAssertTrue(turn.crossedEvidence, "precondition: each session named the other side")
        XCTAssertTrue(turn.foreignSpeechWitness(outputs: outputs, inputs: inputs),
                      "the home translation reads as German and neither transcript does")

        let bubble = turn.commit(inputs: inputs, outputs: outputs)
        XCTAssertEqual(bubble?.isHome, false,
                       "foreign speech with a real home translation commits LEFT — got \(turn.lastRejectReason ?? "a bubble")")
        XCTAssertEqual(bubble?.translation, translated)
        XCTAssertFalse(turn.abstained)
        XCTAssertEqual(turn.direction, .foreignSpoken)
    }

    /// L1.127b — the same turn with the settle on home, where the crossed
    /// shape blocks the foreign branch and the partner session's echo of its
    /// own transcript then rejects the turn as #137.
    ///
    /// Fail-first: `no session produced any translation: the partner session
    /// echoed foreign speech (#137)`, with the German translation in hand.
    func testL1_127b_aHomeSettleWithCrossedCodesDoesNotBuryTheTranslation() {
        var turn = crossedTurn(settle: .de)
        let (inputs, outputs) = foreignTurnText
        XCTAssertEqual(turn.spokenLang, .de, "precondition: the pool settled on home")
        XCTAssertTrue(turn.crossedEvidence, "precondition: each session named the other side")
        XCTAssertTrue(turn.partnerEchoedForeignSpeech(outputs: outputs, inputs: inputs),
                      "precondition: the partner session echoed what it heard")

        let bubble = turn.commit(inputs: inputs, outputs: outputs)
        XCTAssertEqual(bubble?.isHome, false,
                       "the home session's translation decides — got \(turn.lastRejectReason ?? "a bubble")")
        XCTAssertEqual(bubble?.translation, translated)
    }

    /// L1.127c — L1.47g: the live line and the committed bubble may not
    /// disagree about the side, so the same witness moves both.
    func testL1_127c_theLiveLineFollowsTheWitness() {
        var turn = crossedTurn(settle: .de)
        let (inputs, outputs) = foreignTurnText
        turn.noteOutputs(outputs, inputs: inputs, at: t(10))
        XCTAssertEqual(turn.direction, .foreignSpoken)
        turn.noteOutputs(outputs, inputs: inputs, at: t(10 + TurnLogic.homeSilenceConfirmDelay + 0.1))
        XCTAssertEqual(turn.direction, .foreignSpoken, "and it does not flip once the confirm delay passes")
        XCTAssertEqual(turn.commit(inputs: inputs, outputs: outputs)?.isHome, false)
    }

    /// L1.127d — home speech in the same crossed shape is untouched: the
    /// transcripts ARE home text, so the witness is silent and the measured
    /// #75 rescue still lands the turn on the home side.
    func testL1_127d_misheardHomeSpeechStillCommitsHome() {
        var turn = crossedTurn(settle: .en)
        let german = "Ich habe noch eine Frage zu der Rechnung, und zwar wegen der Anzahlung."
        let inputs: [TurnLogic.Lang: String] = [.de: german, .en: german]
        let outputs: [TurnLogic.Lang: String] = [.de: german, .en: "I have another question about the bill."]
        XCTAssertFalse(turn.foreignSpeechWitness(outputs: outputs, inputs: inputs),
                       "home text in the transcripts is not foreign speech")
        XCTAssertEqual(turn.commit(inputs: inputs, outputs: outputs)?.isHome, true,
                       "the #75 rescue is unchanged — got \(turn.lastRejectReason ?? "no bubble")")
    }

    /// L1.127e — the known limit, pinned rather than claimed away (#179).
    ///
    /// When BOTH sessions mis-hear home speech into foreign words, every text
    /// test above reads the turn as foreign: the transcripts are not home text,
    /// the home session's German is not an echo of them, and the partner
    /// session's "translation" of its own mis-hearing scores as one. Nothing in
    /// the turn distinguishes it from the measured #177 shape, so it commits
    /// LEFT where it used to commit RIGHT.
    ///
    /// What is NOT at stake is the words on screen: both lines are built from
    /// the mis-transcription either way, so the turn was already wrong before
    /// the side changed. An independent witness (#135/#169) is what could
    /// separate these; this case exists so the limit is visible and fails
    /// loudly if anyone believes otherwise.
    func testL1_127e_bothSessionsMishearingHomeSpeechIsNotSeparable() {
        var turn = crossedTurn(settle: .de)
        let misheard = "He have another question about the deposit, right?"
        let inputs: [TurnLogic.Lang: String] = [.de: misheard, .en: misheard]
        let outputs: [TurnLogic.Lang: String] = [
            .de: "Ich habe noch eine Frage zur Anzahlung.",
            .en: "I have another question about the down payment."
        ]
        XCTAssertTrue(turn.foreignSpeechWitness(outputs: outputs, inputs: inputs),
                      "the text evidence is identical to a genuine foreign turn")
        XCTAssertEqual(turn.commit(inputs: inputs, outputs: outputs)?.isHome, false,
                       "so it commits LEFT — the limit, not a claim that this is foreign speech")
    }

    /// L1.127f — the witness is evaluated on every streamed chunk, so it may
    /// not answer off text too short to judge: a German prefix clears the
    /// two-function-word bar before it reaches the echo test's floor. The live
    /// line stays undecided until there is enough of the turn to read, and
    /// only then resolves foreign (L1.64's oscillation).
    func testL1_127f_thePartialTurnDoesNotResolveEarly() {
        var turn = crossedTurn(settle: .de)
        let partial: [TurnLogic.Lang: String] = [.de: "Ich bin nicht", .en: "I'm"]
        XCTAssertFalse(turn.foreignSpeechWitness(outputs: partial, inputs: [.de: "I'm", .en: "I'm"]),
                       "three words are not a reading of the turn")
        turn.noteOutputs(partial, inputs: [.de: "I'm", .en: "I'm"], at: t(9))
        XCTAssertNil(turn.direction)

        let (inputs, outputs) = foreignTurnText
        turn.noteOutputs(outputs, inputs: inputs, at: t(10))
        XCTAssertEqual(turn.direction, .foreignSpoken, "and resolves once the whole turn is there")
    }
}
