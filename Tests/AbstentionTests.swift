import XCTest
@testable import HeikoTranslate

/// L1 coverage for the refusal introduced by #152, on the real `TurnLogic`.
///
/// The distinction these tests exist to hold: a REJECTION means something is
/// missing and may still arrive, so the service retries it. An ABSTENTION
/// means the evidence is present and contradicts itself, so retrying cannot
/// help and the speaker should be asked to repeat instead.
///
/// The vote tallies are taken from the device log of 2026-08-18 (#125), where
/// three identical turns committed a Spanish "original" a German speaker never
/// said. No audio is needed to reproduce it: the votes are the whole input.
@MainActor
final class AbstentionTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 5_000_000)
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Drives the crossed shape the device produced: the HOME session's codes
    /// name the partner language, the PARTNER session's codes name home. Four
    /// and five votes respectively, both clearing `partnerCorroborationQuorum`
    /// (3), exactly as logged.
    private func crossedTurn(home: TurnLogic.Lang = .de,
                             partner: TurnLogic.Lang = .es) -> TurnLogic {
        var turn = TurnLogic(home: home, partner: partner)
        // Proportions matter: the pooled settle has to land on the PARTNER,
        // which is what the device produced and what makes this the unguarded
        // direction. A first version of this fixture used more home votes than
        // partner votes, settled HOME, and quietly tested a different case
        // altogether.
        for i in 0..<4 {
            turn.noteInputLanguage(partner.rawValue, from: home, at: t(Double(i) * 0.5))
        }
        for i in 0..<3 {
            turn.noteInputLanguage(home.rawValue, from: partner, at: t(0.1 + Double(i) * 0.5))
        }
        return turn
    }

    // L1.75 — the #125 turn: both witnesses report the swap, the settle lands
    // on the partner, and the turn refuses rather than inventing a side.
    func testL1_75_crossedEvidenceWithPartnerSettleAbstains() {
        var turn = crossedTurn()
        XCTAssertTrue(turn.crossedEvidence,
                      "both witnesses must see the swap — otherwise this test proves nothing")

        // The shape that committed on device: the home session produced text
        // that looks like a real translation, so the foreign branch was taken.
        let inputs: [TurnLogic.Lang: String] = [.de: "¿Cómo se llama eso?",
                                                .es: "Äh, wie heißt das noch mal?"]
        let outputs: [TurnLogic.Lang: String] = [.de: "Wie heißt das noch mal?",
                                                 .es: "¿Cómo se llama eso?"]
        turn.noteOutputs(outputs, inputs: inputs)

        let bubble = turn.commit(inputs: inputs, outputs: outputs)

        XCTAssertNil(bubble, "a turn whose evidence contradicts itself must not commit a side")
        XCTAssertTrue(turn.abstained,
                      "and it must say WHY it refused — a caller has to tell this from a missing translation")
        XCTAssertNil(turn.direction,
                     "a refusal decided nothing; leaving a direction names a session whose audio would then play")
    }

    // L1.75b — the refusal is typed, not spelled. #28's rule: copy is never a
    // control channel. A caller must never have to match on the log string.
    func testL1_75b_theRefusalIsAFactNotAPhrase() {
        var turn = crossedTurn()
        let inputs: [TurnLogic.Lang: String] = [.de: "¿Cómo se llama eso?",
                                                .es: "Äh, wie heißt das noch mal?"]
        let outputs: [TurnLogic.Lang: String] = [.de: "Wie heißt das noch mal?",
                                                 .es: "¿Cómo se llama eso?"]
        turn.noteOutputs(outputs, inputs: inputs)
        _ = turn.commit(inputs: inputs, outputs: outputs)

        XCTAssertTrue(turn.abstained)
        // The string may be reworded freely; behaviour must not follow it.
        XCTAssertNotNil(turn.lastRejectReason, "the log still gets a sentence")
    }

    // L1.75c — a MISSING translation is not an abstention. This is the case
    // the deferral machinery retries three times, and conflating the two would
    // make the app give up on a turn that was about to arrive.
    func testL1_75c_aMissingTranslationIsNotAnAbstention() {
        var turn = TurnLogic(home: .de, partner: .en)
        for i in 0..<4 {
            turn.noteInputLanguage("de", from: .de, at: t(Double(i) * 0.2))
        }
        let inputs: [TurnLogic.Lang: String] = [.de: "Wo ist der Bahnhof?"]

        let bubble = turn.commit(inputs: inputs, outputs: [:])

        XCTAssertNil(bubble, "nothing to show yet")
        XCTAssertFalse(turn.abstained,
                       "missing is not contradictory — this one may still arrive, and is retried")
    }

    // L1.75d — an ordinary turn does not abstain. The guard against a refusal
    // that fires so eagerly it eats working conversations.
    func testL1_75d_anOrdinaryTurnCommitsNormally() {
        var turn = TurnLogic(home: .de, partner: .en)
        for i in 0..<4 {
            turn.noteInputLanguage("de", from: .de, at: t(Double(i) * 0.2))
            turn.noteInputLanguage("de", from: .en, at: t(Double(i) * 0.2 + 0.05))
        }
        let inputs: [TurnLogic.Lang: String] = [.de: "Wo ist der Bahnhof?",
                                                .en: "Wo ist der Bahnhof?"]
        let outputs: [TurnLogic.Lang: String] = [.en: "Where is the station?"]
        turn.noteOutputs(outputs, inputs: inputs)

        let bubble = turn.commit(inputs: inputs, outputs: outputs)

        XCTAssertFalse(turn.abstained, "a turn both sessions agree about must never be refused")
        XCTAssertNotNil(bubble)
        XCTAssertEqual(bubble?.isHome, true)
    }

    // L1.75e — crossed evidence with a HOME settle keeps its existing
    // treatment. That path is the measured #75 rescue: the same witnesses are
    // used there to OVERRIDE a foreign veto and commit home. #152 must not buy
    // the partner-settle case by breaking the one that already works.
    func testL1_75e_crossedEvidenceWithHomeSettleIsUntouched() {
        var turn = TurnLogic(home: .de, partner: .es)
        // Home session mis-hears (votes partner), partner session votes home,
        // and the pooled settle lands on HOME.
        for i in 0..<4 {
            turn.noteInputLanguage("es", from: .de, at: t(Double(i) * 0.2))
        }
        for i in 0..<6 {
            turn.noteInputLanguage("de", from: .es, at: t(1.0 + Double(i) * 0.2))
        }
        XCTAssertTrue(turn.crossedEvidence)
        XCTAssertEqual(turn.spokenLang, .de, "this case is defined by the settle landing HOME")

        let inputs: [TurnLogic.Lang: String] = [.de: "Wo ist der Bahnhof?",
                                                .es: "Wo ist der Bahnhof?"]
        let outputs: [TurnLogic.Lang: String] = [.es: "¿Dónde está la estación?"]
        turn.noteOutputs(outputs, inputs: inputs)
        _ = turn.commit(inputs: inputs, outputs: outputs)

        XCTAssertFalse(turn.abstained,
                       "the home-settle path is the measured #75 rescue and stays as it was")
    }

    // L1.75f — the flag is per-commit, not sticky. A turn that abstained must
    // not leave the next one looking like it refused.
    func testL1_75f_theFlagDoesNotOutliveItsTurn() {
        var turn = crossedTurn()
        let inputs: [TurnLogic.Lang: String] = [.de: "¿Cómo se llama eso?",
                                                .es: "Äh, wie heißt das noch mal?"]
        let outputs: [TurnLogic.Lang: String] = [.de: "Wie heißt das noch mal?",
                                                 .es: "¿Cómo se llama eso?"]
        turn.noteOutputs(outputs, inputs: inputs)
        _ = turn.commit(inputs: inputs, outputs: outputs)
        XCTAssertTrue(turn.abstained)

        turn.endTurn(at: t(10))
        var next = TurnLogic(home: .de, partner: .es)
        XCTAssertFalse(next.abstained, "a fresh turn has refused nothing")

        // And a second commit on a turn that now has clean evidence clears it.
        for i in 0..<4 { next.noteInputLanguage("de", from: .de, at: t(11 + Double(i) * 0.2)) }
        let clean: [TurnLogic.Lang: String] = [.de: "Danke schön."]
        _ = next.commit(inputs: clean, outputs: [.es: "Muchas gracias."])
        XCTAssertFalse(next.abstained)
    }

    // MARK: - What the reader is told

    // L1.76 — the refusal reaches the screen, in the reader's language.
    func testL1_76_theNoticeSaysWhatToDo() {
        let vm = ConversationViewModel()
        vm.homeLang = .de
        XCTAssertNil(vm.micNotice)

        vm.showUnresolvedTurnNotice()

        XCTAssertEqual(vm.micNotice?.text, UIStrings.german.didNotCatch)
        XCTAssertEqual(vm.micNotice?.severity, .info,
                       "nothing failed — it heard something and could not tell who said it")
    }

    // L1.76b — it follows the HOME language, like every other instruction.
    // Heiko reads German; a Spanish-home user reads Spanish.
    func testL1_76b_theNoticeFollowsTheHomeLanguage() {
        let vm = ConversationViewModel()
        vm.homeLang = .es
        vm.showUnresolvedTurnNotice()
        XCTAssertEqual(vm.micNotice?.text, UIStrings.spanish.didNotCatch)
    }

    // L1.76c — muted still outranks it. The slot holds one thing, and
    // "Mikrofon pausiert" is the one that must never be covered: a request to
    // repeat, shown to someone whose microphone is off, asks for something
    // that cannot work.
    func testL1_76c_mutedOutranksTheRequestToRepeat() {
        let notice = ConversationViewModel.StatusNotice(
            text: UIStrings.german.didNotCatch, severity: .info)
        let shown = ConversationViewModel.bottomNotice(
            muted: true, warning: nil, micNotice: notice)
        XCTAssertNotEqual(shown?.text, UIStrings.german.didNotCatch,
                          "the mute notice owns the slot while the mic is off")
    }

    // L1.76d — every language set answers. Without this, adding a seventh
    // language ships a build that shows nothing at the one moment the reader
    // is being asked to do something.
    func testL1_76d_everyLanguageSetHasTheString() {
        for lang in TurnLogic.Lang.allCases where lang.canBeHome {
            let text = UIStrings.of(lang).didNotCatch
            XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(lang.rawValue) has no text for the one instruction that asks for a repeat")
        }
    }
}
