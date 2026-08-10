import XCTest
@testable import HeikoTranslate

/// L1 tests for `FinalizePolicy` — whether a finalize that produced no bubble
/// waits for a late translation or gives up on the turn.
///
/// This rule was implemented twice: once in the service, and not at all in the
/// L3 replay harness, which committed-or-wiped on the spot. The release gate
/// therefore reported swallowed turns the shipping app would have recovered —
/// measured 2026-08-04, 58% of `de_after_es` failures had that shape. Both now
/// compile this type. Test IDs match TESTING.md §L1.
final class FinalizePolicyTests: XCTestCase {

    /// L1.33 — a committed turn resets the wait count, so the next turn starts
    /// with a full budget.
    func testL1_33_commitResetsTheBudget() {
        var p = FinalizePolicy()
        XCTAssertEqual(p.decide(committed: false, rejectReason: "codes-veto: settled en, home session never translated"),
                       .waitForTranslation)
        XCTAssertEqual(p.deferrals, 1)

        XCTAssertEqual(p.decide(committed: true, rejectReason: nil), .committed)
        XCTAssertEqual(p.deferrals, 0, "a commit clears the budget for the next turn")
    }

    /// L1.33b — the two recoverable rejections wait; everything else gives up
    /// immediately. An empty original is not going to fill itself in.
    ///
    /// The reasons are obtained by driving a REAL `TurnLogic` into each
    /// rejection, not by typing its strings in here. `isRecoverable` matches
    /// substrings of a human-readable diagnostic, so a literal copy would pass
    /// forever while a reword in `TurnLogic` silently turned the deferral off
    /// — which is precisely the failure #21 is about, one layer down. If a
    /// reason is renamed, this test fails at the rename. GitHub #21.
    func testL1_33b_onlyRecoverableRejectionsWait() {
        for (label, reason) in Self.realRejectionReasons() {
            var p = FinalizePolicy()
            let outcome = p.decide(committed: false, rejectReason: reason)
            let expected: FinalizePolicy.Outcome =
                (label == .codesVeto || label == .noTranslation) ? .waitForTranslation : .giveUp
            XCTAssertEqual(outcome, expected, "\(label): \(reason)")
        }

        var noReason = FinalizePolicy()
        XCTAssertEqual(noReason.decide(committed: false, rejectReason: nil), .giveUp,
                       "no reason at all is not something to wait on")
    }

    enum Rejection: String, CaseIterable {
        case codesVeto, noTranslation, alreadyCommitted, foreignEmptyOriginal, homeEmptyOriginal
    }

    /// Every rejection `TurnLogic.commit` can produce, with the reason string
    /// it actually produced. Built by driving the real type, so this list
    /// cannot drift from the strings the policy has to recognise.
    static func realRejectionReasons() -> [(Rejection, String)] {
        func reason(_ build: (inout TurnLogic) -> Void) -> String {
            var l = TurnLogic()
            build(&l)
            return l.lastRejectReason ?? "<none>"
        }
        let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)
        func settleForeign(_ l: inout TurnLogic) {
            l.noteInputLanguage("en", from: .de, at: t0)
            l.noteInputLanguage("en", from: .de, at: t0.addingTimeInterval(0.5))
            l.noteInputLanguage("en", from: .de, at: t0.addingTimeInterval(TurnLogic.settleWindow + 0.1))
        }
        return [
            (.codesVeto, reason { l in
                settleForeign(&l)
                _ = l.commit(inputs: [.en: "Fourteen euros"], outputs: [.en: "Fourteen euros"])
            }),
            (.noTranslation, reason { l in
                _ = l.commit(inputs: [:], outputs: [:])
            }),
            (.alreadyCommitted, reason { l in
                _ = l.commit(inputs: [.en: "Mir geht es gut."], outputs: [.en: "I'm doing well."])
                _ = l.commit(inputs: [.en: "Mir geht es gut."], outputs: [.en: "I'm doing well."])
            }),
            (.foreignEmptyOriginal, reason { l in
                _ = l.commit(inputs: [:], outputs: [.de: "Hallo Heiko"])
            }),
            (.homeEmptyOriginal, reason { l in
                _ = l.commit(inputs: [:], outputs: [.en: "I'm doing well."])
            }),
        ]
    }

    /// L1.33f — every rejection the real `TurnLogic` can produce is classified
    /// by the policy, and the two that wait are the two that mean "the
    /// translation may still be in flight". Guards the other direction from
    /// L1.33b: a NEW rejection reason added to `TurnLogic` shows up here as an
    /// unclassified case rather than silently defaulting to "give up".
    func testL1_33f_everyRealRejectionIsAccountedFor() {
        let produced = Self.realRejectionReasons()
        XCTAssertEqual(Set(produced.map(\.0)), Set(Rejection.allCases),
                       "each rejection kind must be reachable, or this list is stale")
        for (label, reason) in produced {
            XCTAssertFalse(reason.isEmpty)
            XCTAssertNotEqual(reason, "<none>", "\(label) did not actually reject")
            XCTAssertEqual(FinalizePolicy.isRecoverable(reason),
                           label == .codesVeto || label == .noTranslation,
                           "\(label) is classified by what it means, not by its spelling")
        }
    }

    /// L1.33c — the wait is bounded. Three deferrals of 2s is about six extra
    /// seconds; past that the translation is not coming and holding the turn
    /// open only delays the next one.
    func testL1_33c_waitingIsBounded() {
        var p = FinalizePolicy()
        let reason = "no session produced any translation"
        for attempt in 1...FinalizePolicy.maxDeferrals {
            XCTAssertEqual(p.decide(committed: false, rejectReason: reason), .waitForTranslation,
                           "attempt \(attempt) should still wait")
            XCTAssertEqual(p.deferrals, attempt)
        }
        XCTAssertEqual(p.decide(committed: false, rejectReason: reason), .giveUp,
                       "the budget is exhausted")
        XCTAssertEqual(p.deferrals, 0, "and it resets so the next turn is not starved")
    }

    /// L1.33d — a teardown (mute, stop) abandons the turn without consulting a
    /// rejection, and must not leave the budget half-spent for the next run.
    func testL1_33d_resetClearsTheBudget() {
        var p = FinalizePolicy()
        _ = p.decide(committed: false, rejectReason: "no session produced any translation")
        XCTAssertEqual(p.deferrals, 1)
        p.reset()
        XCTAssertEqual(p.deferrals, 0)
    }

    /// L1.33e — `isRecoverable` matches on substrings because the real reasons
    /// carry interpolated detail ("codes-veto: settled **en**, …"). Pin that,
    /// since an exact-match implementation would silently never wait.
    func testL1_33e_reasonMatchingToleratesInterpolatedDetail() {
        XCTAssertTrue(FinalizePolicy.isRecoverable("codes-veto: settled es, home session never translated"))
        XCTAssertTrue(FinalizePolicy.isRecoverable("codes-veto: settled fr, home session never translated"))
        XCTAssertFalse(FinalizePolicy.isRecoverable("home branch: empty translation"))
    }
}
