import XCTest
@testable import HeikoTranslate

/// A correctly-heard, correctly-translated German turn was thrown away —
/// no bubble at all, the worst failure this app has.
///
/// Device, 2026-08-14, build 2.4.57. Spoken: *"Kein Eis heute für mich,
/// vielen Dank. Äh haben Sie Toilette?"* Both sessions transcribed it
/// identically and correctly; the partner session produced a correct English
/// translation. It was rejected four times with
/// `codes-veto: settled en, home session never translated`, because the
/// codes had settled `en` on the opening three votes:
///
///     why: settled=en direction=nil votes=en×3
///          sessions=de[de×9/en×3] en[de×9/en×3]
///
/// Nine home `de` votes could not overturn three `en` ones. The reason was
/// not the overturn threshold — it was that the counter kept being erased.
/// #83's guard (a partner-session report of HOME must not overturn a partner
/// settle) cleared `contradiction` instead of merely declining to count it,
/// and the two sessions' votes interleave, so every home vote was wiped by
/// the partner vote that followed it.
final class ContradictionErasureTests: XCTestCase {

    /// Settle on the partner language, the way the device turn did.
    private func settledOnPartner() -> (TurnLogic, Date) {
        var l = TurnLogic(home: .de, partner: .en)
        let t0 = Date()
        _ = l.noteInputLanguage("en", from: .en, at: t0)
        _ = l.noteInputLanguage("en", from: .de, at: t0)
        _ = l.noteInputLanguage("en", from: .en, at: t0.addingTimeInterval(TurnLogic.settleWindow + 0.1))
        return (l, t0.addingTimeInterval(TurnLogic.settleWindow + 0.2))
    }

    /// L1.100 — the device case. Home votes interleaved with partner votes
    /// still overturn a wrong settle.
    ///
    /// Fail-first: with the erasure restored this stays `en`, which is the
    /// swallowed turn.
    func testL1_100_interleavedPartnerVotesDoNotEraseTheHomeContradiction() {
        var (l, t) = settledOnPartner()
        XCTAssertEqual(l.spokenLang, .en, "precondition: settled on the partner language")

        for _ in 0..<6 {
            _ = l.noteInputLanguage("de", from: .de, at: t); t = t.addingTimeInterval(0.1)
            _ = l.noteInputLanguage("de", from: .en, at: t); t = t.addingTimeInterval(0.1)
        }

        XCTAssertEqual(l.spokenLang, .de,
                       "the home session said 'de' six times — a partner session agreeing "
                       + "must not be what prevents the correction")
    }

    /// L1.101 — the same votes without interleaving. This passed before the
    /// fix too, and is here to show the difference is the interleaving and
    /// nothing else.
    func testL1_101_homeVotesAloneStillOverturn() {
        var (l, t) = settledOnPartner()
        for _ in 0..<6 {
            _ = l.noteInputLanguage("de", from: .de, at: t); t = t.addingTimeInterval(0.1)
        }
        XCTAssertEqual(l.spokenLang, .de)
    }

    /// L1.102 — **#83's rule, which the fix must not weaken.** A
    /// partner-only stream of home reports must never overturn a partner
    /// settle, however many arrive: that is the partner reading its own
    /// translated text back as home speech, and it is not independent
    /// evidence.
    func testL1_102_partnerOnlyHomeReportsStillNeverOverturn() {
        var (l, t) = settledOnPartner()
        for _ in 0..<12 {
            _ = l.noteInputLanguage("de", from: .en, at: t); t = t.addingTimeInterval(0.1)
        }
        XCTAssertEqual(l.spokenLang, .en,
                       "#83: the partner echoing home text is not a witness to home speech")
    }

    /// L1.103 — the threshold is unchanged. Two home votes are still not
    /// enough; the fix restores accumulation, it does not lower the bar.
    func testL1_103_theOverturnThresholdIsUnchanged() {
        var (l, t) = settledOnPartner()
        for _ in 0..<(TurnLogic.overturnVotes - 1) {
            _ = l.noteInputLanguage("de", from: .de, at: t); t = t.addingTimeInterval(0.1)
            _ = l.noteInputLanguage("de", from: .en, at: t); t = t.addingTimeInterval(0.1)
        }
        XCTAssertEqual(l.spokenLang, .en,
                       "fewer than overturnVotes home reports must still not overturn")
    }
}
