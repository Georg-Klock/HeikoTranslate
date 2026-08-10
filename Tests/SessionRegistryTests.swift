import XCTest
@testable import HeikoTranslate

/// L1 tests for `SessionRegistry` — the rule that decides whether an
/// asynchronous continuation (a session's event callback, a reconnect timer)
/// still belongs to the current run and the current session instance.
///
/// These exist because GitHub #20 was a defect in the #3 fix: the
/// drop-reconnect timer guarded only `isRunning`, which is true again after a
/// mute/unmute, so a timer armed before the mute replaced a healthy session
/// after it. That path was unreachable from any test — the service needs audio
/// hardware and a network — so the rule was extracted here, pure, for the same
/// reason `TurnLogic` was. Test IDs match TESTING.md §L1.
final class SessionRegistryTests: XCTestCase {

    /// L1.30 — the mute/unmute race that #20 was filed for.
    ///
    /// Timeline: a drop is detected and a reconnect timer is armed, capturing
    /// the token of the session that dropped. The user mutes (`clear()`), then
    /// unmutes — a fresh session for the same language is registered. The old
    /// timer finally fires. It must NOT act: in the service every other guard
    /// (`isRunning`, `dead`, `activePair`) has been reset to a passing state by
    /// the restart, so this check is the only thing standing between a stale
    /// timer and a healthy live session being torn down and replaced.
    func testL1_30_timerArmedBeforeMuteIsInertAfterUnmute() {
        var registry = SessionRegistry()
        _ = registry.register(.de)
        let armedToken = registry.token(for: .de)   // captured by the timer

        registry.clear()                            // user mutes
        _ = registry.register(.de)                  // user unmutes: new session

        XCTAssertFalse(registry.isCurrent(armedToken, for: .de),
                       "a timer armed before the mute must not act on the session that replaced it")
    }

    /// L1.30b — a replaced session's late event must not be attributed to its
    /// successor. Events are routed by language, so without this a zombie's
    /// `setupComplete` marks the CURRENT session ready and can open the mic
    /// before it has finished setup — the documented "first utterance silently
    /// lost" failure, reached by the back door.
    func testL1_30b_supersededSessionCannotActAsItsSuccessor() {
        var registry = SessionRegistry()
        let first = registry.register(.en)
        let second = registry.register(.en)         // reconnect replaces it

        XCTAssertFalse(registry.isCurrent(first, for: .en), "the superseded instance is not current")
        XCTAssertTrue(registry.isCurrent(second, for: .en), "the replacement is")
    }

    /// L1.30c — after a stop, nothing from that run validates. This is the
    /// post-`stopSession()` window where the old `activePair.isEmpty ||` guard
    /// was vacuous and let every late event through.
    func testL1_30c_nothingFromAStoppedRunIsCurrent() {
        var registry = SessionRegistry()
        let de = registry.register(.de)
        let en = registry.register(.en)

        registry.clear()

        XCTAssertFalse(registry.isCurrent(de, for: .de))
        XCTAssertFalse(registry.isCurrent(en, for: .en))
    }

    /// L1.30d — a nil token is never current, including against a cleared
    /// registry. Without the explicit guard, `tokens[lang] == token` compares
    /// `nil == nil` and returns TRUE after `clear()` — which would wave through
    /// precisely the stale continuations this type exists to stop. The most
    /// dangerous case, because it looks correct.
    func testL1_30d_nilTokenIsNeverCurrent() {
        var registry = SessionRegistry()
        XCTAssertFalse(registry.isCurrent(nil, for: .de), "nothing registered")

        _ = registry.register(.de)
        registry.clear()
        XCTAssertFalse(registry.isCurrent(nil, for: .de), "cleared — nil must not match nil")
    }

    /// L1.30e — languages are independent. Reconnecting one side of the pair
    /// must not invalidate the other's in-flight work.
    func testL1_30e_registeringOneLanguageDoesNotDisturbTheOther() {
        var registry = SessionRegistry()
        let de = registry.register(.de)
        let en = registry.register(.en)

        _ = registry.register(.de)                  // de reconnects

        XCTAssertFalse(registry.isCurrent(de, for: .de), "de's old token is superseded")
        XCTAssertTrue(registry.isCurrent(en, for: .en), "en is untouched")
    }

    /// L1.30f — a token is only valid for the language it was minted for.
    func testL1_30f_tokensDoNotCrossLanguages() {
        var registry = SessionRegistry()
        let de = registry.register(.de)
        _ = registry.register(.en)

        XCTAssertFalse(registry.isCurrent(de, for: .en))
    }
}
