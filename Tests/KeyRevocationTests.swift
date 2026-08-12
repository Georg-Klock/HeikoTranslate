import XCTest
@testable import HeikoTranslate

/// GitHub #9: the piece that makes revoke-first rotation safe. A revoked key
/// must upgrade the message from "try again" (false) to "update the app"
/// (true), and must never convict on evidence that merely LOOKS like a dead
/// key — quota, airport WiFi, a server hiccup.
@MainActor
final class KeyRevocationTests: XCTestCase {

    // MARK: - The classifier, against realistic response shapes.
    // Bodies are invented but mirror the documented error format.

    func testInvalidKeyBodyConvicts() {
        let body = """
        {"error":{"code":400,"message":"API key not valid. Please pass a valid API key.",\
        "status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo",\
        "reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}
        """
        XCTAssertEqual(KeyCheck.verdict(fromResponseBody: body), .revoked)
    }

    func testReasonAloneConvicts() {
        XCTAssertEqual(KeyCheck.verdict(fromResponseBody: "closed: API_KEY_INVALID"),
                       .revoked,
                       "an error frame or close reason carrying the marker is already proof")
    }

    func testQuotaExhaustionDoesNotConvict() {
        let body = """
        {"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).",\
        "status":"RESOURCE_EXHAUSTED"}}
        """
        XCTAssertEqual(KeyCheck.verdict(fromResponseBody: body), .inconclusive,
                       "quota heals by itself — 'update the app' would be a lie")
    }

    func testHealthyAndGarbageBodiesDoNotConvict() {
        XCTAssertEqual(KeyCheck.verdict(fromResponseBody: #"{"models":[{"name":"models/x"}]}"#),
                       .inconclusive)
        XCTAssertEqual(KeyCheck.verdict(fromResponseBody: ""), .inconclusive)
        XCTAssertEqual(KeyCheck.verdict(fromResponseBody: "<html>captive portal</html>"),
                       .inconclusive,
                       "a hotel login page is a network problem, not a key problem")
    }

    // MARK: - The state it drives, through the real view model paths.

    private func makeModel(verdict: KeyCheck.Verdict) -> ConversationViewModel {
        let vm = ConversationViewModel()
        vm.permissionRequestForTesting = { true }
        vm.serviceStartForTesting = { true }
        vm.keyProbeForTesting = { verdict }
        return vm
    }

    func testConfirmedRevocationShowsTheUpdateSentence() async {
        let vm = makeModel(verdict: .revoked)
        vm.forceSessionsExhaustedForTesting()
        await vm.awaitKeyConfirmationForTesting()
        XCTAssertTrue(vm.keyRevoked)
        XCTAssertEqual(vm.errorMessage, UIStrings.of(vm.homeLang).updateRequired,
                       "the sentence must be the reader's, not always German")
    }

    func testInconclusiveProbeKeepsTheGenericMessaging() async {
        let vm = makeModel(verdict: .inconclusive)
        vm.forceSessionsExhaustedForTesting()
        await vm.awaitKeyConfirmationForTesting()
        XCTAssertFalse(vm.keyRevoked)
        XCTAssertNotEqual(vm.errorMessage, UIStrings.of(vm.homeLang).updateRequired,
                          "no conviction without the marker — bad WiFi stays 'try again'")
    }

    func testRevokedStateRefusesToStartListening() async {
        let vm = makeModel(verdict: .revoked)
        vm.forceSessionsExhaustedForTesting()
        await vm.awaitKeyConfirmationForTesting()
        await vm.beginListening()
        XCTAssertFalse(vm.isListening,
                       "an automatic resume must not replace the update sentence with 'Verbinde…'")
        XCTAssertEqual(vm.errorMessage, UIStrings.of(vm.homeLang).updateRequired)
    }

    func testEveryLanguageHasTheSentence() {
        for lang in TurnLogic.Lang.allCases where lang.canBeHome {
            XCTAssertFalse(UIStrings.of(lang).updateRequired.isEmpty)
        }
    }
}
