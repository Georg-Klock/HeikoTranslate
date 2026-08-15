import XCTest
@testable import HeikoTranslate

/// The spoken translation must not change voice on its own.
///
/// Reported on device 2026-08-14: "the voice sounds female sometimes but
/// mostly male". Cause was in this repo — `sendSetup` sent no `speechConfig`
/// at all, so the server chose a voice per session and the choice was not
/// stable across reconnects. The app spends its entire design on saying WHO
/// is speaking (sides, colours, flags); a voice that changes by itself
/// contradicts that, and Heiko has no way to know whether it means anything.
///
/// These pin the wire frame rather than the intent. The voice was missing
/// from that frame for the app's whole life and nothing noticed, because
/// nothing looked at it.
@MainActor
final class VoiceStabilityTests: XCTestCase {

    private func speechConfig(of session: GeminiLiveSession) -> [String: Any]? {
        let setup = session.setupPayload()["setup"] as? [String: Any]
        let generation = setup?["generationConfig"] as? [String: Any]
        return generation?["speechConfig"] as? [String: Any]
    }

    private func requestedVoice(of session: GeminiLiveSession) -> String? {
        let voice = speechConfig(of: session)?["voiceConfig"] as? [String: Any]
        let prebuilt = voice?["prebuiltVoiceConfig"] as? [String: Any]
        return prebuilt?["voiceName"] as? String
    }

    private func session(target: String, voice: String) -> GeminiLiveSession {
        GeminiLiveSession(targetLanguageCode: target,
                          apiKey: "not-used-no-socket-is-opened",
                          voiceName: voice, onEvent: { _ in })
    }

    /// L1.95 — the setup frame always carries a voice.
    ///
    /// Fail-first: before the fix `speechConfig` was absent entirely, so
    /// every assertion here failed.
    func testL1_95_setupAlwaysRequestsAVoice() {
        let s = session(target: "en", voice: "Charon")
        XCTAssertNotNil(speechConfig(of: s),
                        "no speechConfig means the server picks, and it does not pick stably")
        XCTAssertEqual(requestedVoice(of: s), "Charon")
    }

    /// L1.96 — the voice sits inside `generationConfig`, where the API wants
    /// it. Its neighbours `inputAudioTranscription` and
    /// `outputAudioTranscription` are siblings of `generationConfig` and were
    /// rejected when nested (see `setupPayload`'s own comment), so nesting
    /// here is a real and easy mistake — and one the server would answer with
    /// silence rather than an error, since a bad voice request simply falls
    /// back to a default.
    func testL1_96_theVoiceIsNestedWhereTheAPIExpectsIt() {
        let setup = session(target: "en", voice: "Charon").setupPayload()["setup"] as? [String: Any]
        XCTAssertNil(setup?["speechConfig"],
                     "speechConfig must NOT be a sibling of generationConfig")
        XCTAssertNotNil((setup?["generationConfig"] as? [String: Any])?["speechConfig"],
                        "it belongs inside generationConfig")
    }

    /// L1.97 — the two directions get DIFFERENT voices, and the one speaking
    /// Heiko's words is his.
    ///
    /// The session translating into the partner's language carries Heiko's
    /// words outward; the one translating into the home language carries a
    /// stranger's words to him. Giving both the same voice would make every
    /// stranger sound exactly like Heiko, which is worse than the bug this
    /// fixes. Georg's call, 2026-08-14.
    func testL1_97_eachDirectionHasItsOwnVoice() {
        let outward = GeminiLiveTranslationService.voiceName(for: .en, home: .de)
        let inward = GeminiLiveTranslationService.voiceName(for: .de, home: .de)

        XCTAssertEqual(outward, GeminiLiveTranslationService.heikoVoice,
                       "translating INTO the partner's language speaks Heiko's words")
        XCTAssertEqual(inward, GeminiLiveTranslationService.partnerVoice,
                       "translating INTO the home language speaks the other person's words")
        XCTAssertNotEqual(outward, inward,
                          "a stranger must not sound like Heiko")
    }

    /// L1.98 — the split follows the HOME language, not a hardcoded German.
    /// The home wheel offers six languages; a Spanish home reader must get
    /// the same arrangement rather than German's.
    func testL1_98_theSplitFollowsWhicheverLanguageIsHome() {
        XCTAssertEqual(GeminiLiveTranslationService.voiceName(for: .es, home: .es),
                       GeminiLiveTranslationService.partnerVoice)
        XCTAssertEqual(GeminiLiveTranslationService.voiceName(for: .de, home: .es),
                       GeminiLiveTranslationService.heikoVoice)
    }

    /// L1.99 — the probes and replay harnesses request a voice too. They
    /// score transcripts rather than audio, so the NAME does not matter —
    /// but an omission would mean they stop exercising the same setup frame
    /// the app sends, which is the whole reason they compile the real
    /// session.
    func testL1_99_theHarnessDefaultIsAVoiceAndNotAnOmission() {
        let asHarnessesBuildIt = GeminiLiveSession(targetLanguageCode: "de",
                                                   apiKey: "not-used",
                                                   onEvent: { _ in })
        XCTAssertEqual(requestedVoice(of: asHarnessesBuildIt), GeminiLiveSession.defaultVoice)
        XCTAssertFalse(GeminiLiveSession.defaultVoice.isEmpty)
    }
}
