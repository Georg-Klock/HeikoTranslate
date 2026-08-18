import XCTest
@testable import HeikoTranslate

/// The v1 language set (SPEC §3.0, decision 2026-08-18): four languages,
/// fully interchangeable, so every one of the six pairs is on offer in both
/// orders. These pin the set itself rather than any behaviour built on it,
/// because the set is a product decision with a stated reason: direction is
/// inferred from which fixed-language session produced plausible output, and
/// that signal only works when the two languages are far enough apart. A case
/// added back to `Lang` without that argument fails here first.
///
/// This file replaces `PartnerOnlyLanguageTests`, which pinned the opposite
/// arrangement: #30's Tagalog and Vietnamese were selectable as the partner
/// and refused on the home side, and four gates enforced the split. Those
/// languages left the set with French and Chinese, `canBeHome` went with
/// them, and the gates had nothing left to reject.
@MainActor
final class LanguageSetTests: XCTestCase {

    func testTheSetIsExactlyTheFourV1Languages() {
        XCTAssertEqual(Set(TurnLogic.Lang.allCases), Set([.de, .en, .es, .ko]))
        XCTAssertEqual(TurnLogic.Lang.allCases.count, 4)
    }

    /// The retired codes must not decode. This is what makes the stored-value
    /// repair in `ConversationViewModel.init` fire (L1.75c/d) rather than
    /// seating a language the app no longer has strings, floors or a flag for.
    func testRetiredLanguagesDoNotDecode() {
        for raw in ["fr", "zh", "tl", "vi"] {
            XCTAssertNil(TurnLogic.Lang(rawValue: raw), "\(raw) is retired (SPEC §3.0)")
            XCTAssertTrue(ConversationViewModel.storedLangIsRetired(seeded(raw)),
                          "a stored \(raw) must be recognised as retired, not as 'never chosen'")
        }
        XCTAssertFalse(ConversationViewModel.storedLangIsRetired(seeded("ko")),
                       "a language still in the set is not a repair case")
        XCTAssertFalse(ConversationViewModel.storedLangIsRetired("settings.absent.\(UUID().uuidString)"),
                       "nothing stored is not a repair case either; that is a fresh install")
    }

    /// Fully interchangeable: every language seats on either side, and every
    /// one of the six pairs is reachable in both orders. `allCases` rather
    /// than a hand-written list, so this follows the enum (GitHub #22).
    func testEveryPairIsReachableInBothOrders() {
        var seen = Set<String>()
        for home in TurnLogic.Lang.allCases {
            for partner in TurnLogic.Lang.allCases where partner != home {
                let vm = ConversationViewModel()
                vm.homeLang = home
                vm.partnerLang = partner
                XCTAssertEqual(vm.homeLang, home, "\(home.rawValue) must seat as home")
                XCTAssertEqual(vm.partnerLang, partner)
                seen.insert("\(home.rawValue)\(partner.rawValue)")
            }
        }
        XCTAssertEqual(seen.count, 12, "six pairs, both orders")
    }

    /// Both wheels offer the same languages now. The home column used to
    /// filter out the partner-only pair; with the set interchangeable, the
    /// only thing either column drops is the language already on the other
    /// side, which is the distinct-pair rule and not a language-set rule.
    func testBothWheelsOfferTheWholeSet() {
        let name: (TurnLogic.Lang) -> String = { $0.rawValue }
        let home = LanguageColumn.selectableOptions(
            excludesOtherSide: false, otherSide: .en, displayName: name)
        XCTAssertEqual(Set(home), Set(TurnLogic.Lang.allCases),
                       "every language is a reader language now")

        let partner = LanguageColumn.selectableOptions(
            excludesOtherSide: true, otherSide: .en, displayName: name)
        XCTAssertEqual(Set(partner), Set(TurnLogic.Lang.allCases).subtracting([.en]))
    }

    /// Every language owns a full UI set, because every one of them can be the
    /// reader. `UIStrings.of` has no fallback branch left to hide a gap in.
    func testEveryLanguageHasItsOwnStringSet() {
        for lang in TurnLogic.Lang.allCases {
            let strings = UIStrings.of(lang)
            XCTAssertEqual(Set(strings.languageNames.keys), Set(TurnLogic.Lang.allCases),
                           "\(lang.rawValue) must name every language in the set")
            guard lang != .de else { continue }
            XCTAssertNotEqual(strings.done, UIStrings.german.done,
                              "\(lang.rawValue) falls back to German, so it has no set of its own")
        }
    }

    /// Seeds one key and returns it. The keys are process-wide, so this uses
    /// a fresh name per call rather than the real `settings.*` keys. The point
    /// here is `storedLangIsRetired`'s decode rule, not the pair.
    private func seeded(_ raw: String) -> String {
        let key = "settings.langProbe.\(UUID().uuidString)"
        UserDefaults.standard.set(raw, forKey: key)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }
        return key
    }
}
