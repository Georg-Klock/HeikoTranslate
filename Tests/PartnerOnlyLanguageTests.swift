import XCTest
@testable import HeikoTranslate

/// GitHub #30 (decision 2026-08-12): Tagalog and Vietnamese are PARTNER-ONLY
/// — the model translates them (verified live, targetprobe 2026-08-12), but
/// neither is an app language, so the home side must never become one. Three
/// gates enforce it: the home wheel's filter, the collision swap's fallback,
/// and the home binding's own guard — the last two pinned here.
@MainActor
final class PartnerOnlyLanguageTests: XCTestCase {

    func testCanBeHomeTable() {
        for lang in [TurnLogic.Lang.de, .en, .es, .fr, .ko, .zh] {
            XCTAssertTrue(lang.canBeHome, "\(lang.rawValue)")
        }
        XCTAssertFalse(TurnLogic.Lang.tl.canBeHome)
        XCTAssertFalse(TurnLogic.Lang.vi.canBeHome)
    }

    // A conversation with a Tagalog speaker, then picking the home language
    // on the partner wheel: the SPEC §4.4 swap would have put Tagalog on the
    // home side — a reader language with no UI set. The swap falls back.
    func testCollisionSwapNeverPutsPartnerOnlyOnHome() {
        let vm = ConversationViewModel()
        vm.homeLang = .de
        vm.partnerLang = .tl
        XCTAssertEqual(vm.partnerLang, .tl, "tl is selectable as the partner")

        vm.partnerLang = .de   // collide with home
        XCTAssertEqual(vm.partnerLang, .de)
        XCTAssertEqual(vm.homeLang, .en,
                       "the swap must fall back — Tagalog can never be the reader")
        XCTAssertNotEqual(vm.homeLang, vm.partnerLang)
    }

    // The same collision when the picked language IS the default home: the
    // fallback must dodge to the default partner instead of colliding again.
    func testCollisionFallbackAvoidsSecondCollision() {
        let vm = ConversationViewModel()
        vm.homeLang = .es
        vm.partnerLang = .vi
        vm.partnerLang = .es   // collide; old partner vi cannot take home
        XCTAssertEqual(vm.homeLang, .de, "non-colliding default home")
        XCTAssertNotEqual(vm.homeLang, vm.partnerLang)
    }

    // The binding itself refuses partner-only home, whatever wrote it.
    func testHomeBindingRefusesPartnerOnly() {
        let vm = ConversationViewModel()
        vm.homeLang = .de
        vm.partnerLang = .en
        vm.homeLang = .vi
        XCTAssertEqual(vm.homeLang, .de, "the previous home survives")
        XCTAssertNotEqual(vm.homeLang, vm.partnerLang)
    }
}
