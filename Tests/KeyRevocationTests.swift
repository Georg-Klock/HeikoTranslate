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

    // MARK: - The probe's broader standard (device-verified, round 3).

    func testProbeConvictsOnUnauthenticated() {
        // The body a scrambled key actually drew, phone day 2026-08-12.
        let body = """
        {"error":{"code":401,"message":"Request had invalid authentication credentials. \
        Expected OAuth 2 access token, login cookie or other valid authentication credential.",\
        "status":"UNAUTHENTICATED"}}
        """
        XCTAssertEqual(KeyCheck.verdict(fromProbeBody: body), .revoked,
                       "the probe built this request itself — an auth rejection IS the answer")
        XCTAssertEqual(KeyCheck.verdict(fromResponseBody: body), .inconclusive,
                       "a FRAME with the same text still only suspects — the probe stays the arbiter")
    }

    func testProbeStaysInconclusiveOnQuotaAndNetwork() {
        XCTAssertEqual(KeyCheck.verdict(fromProbeBody:
            #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"#), .inconclusive)
        XCTAssertEqual(KeyCheck.verdict(fromProbeBody: "<html>captive portal</html>"),
                       .inconclusive)
        XCTAssertEqual(KeyCheck.verdict(fromProbeBody: #"{"models":[]}"#), .inconclusive)
    }

    // MARK: - Auth suspicion from a close reason (device-verified shape).

    func testAuthRejectionReasonIsSuspectButNotConviction() {
        let reason = "Request had invalid authentication credentials. Expected OAuth 2 access token"
        XCTAssertTrue(KeyCheck.suspectsAuth(closeReason: reason))
        XCTAssertEqual(KeyCheck.verdict(fromResponseBody: reason), .inconclusive,
                       "suspicion routes to the probe; only the probe's body convicts")
    }

    func testOrdinaryCloseReasonsAreNotSuspect() {
        XCTAssertFalse(KeyCheck.suspectsAuth(closeReason: "(no reason given)"))
        XCTAssertFalse(KeyCheck.suspectsAuth(closeReason: "policy violation"))
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

    func testAuthSuspectErrorProbesImmediately() async {
        // Phone day 2026-08-12: the retry ladder needs ~17s to exhaust and
        // the person at the phone taps long before that. Suspicion must
        // start the probe on the FIRST auth-rejected close.
        let vm = makeModel(verdict: .revoked)
        vm.reportServiceErrorForTesting(
            "authentication rejected on close: Request had invalid authentication credentials.")
        await vm.awaitKeyConfirmationForTesting()
        XCTAssertTrue(vm.keyRevoked)
        XCTAssertEqual(vm.errorMessage, UIStrings.of(vm.homeLang).updateRequired)
    }

    func testPlainConnectionErrorNeverProbes() async {
        var probeRuns = 0
        let vm = ConversationViewModel()
        vm.permissionRequestForTesting = { true }
        vm.serviceStartForTesting = { true }
        vm.keyProbeForTesting = { probeRuns += 1; return .revoked }
        vm.reportServiceErrorForTesting("de: connection failed before handshake")
        await vm.awaitKeyConfirmationForTesting()
        XCTAssertEqual(probeRuns, 0, "no suspicion, no probe — bad WiFi must never ask")
        XCTAssertFalse(vm.keyRevoked)
        XCTAssertEqual(vm.errorMessage, UIStrings.of(vm.homeLang).connectionError)
    }

    func testRevokedStateSilencesTheStatusLine() async {
        let vm = makeModel(verdict: .revoked)
        vm.forceSessionsExhaustedForTesting()
        await vm.awaitKeyConfirmationForTesting()
        XCTAssertEqual(vm.statusText, "",
                       "'Verbinde…'/'Mikrofon pausiert' beside the sentence is a promise the app cannot keep")
    }

    func testEveryLanguageHasTheSentence() {
        for lang in TurnLogic.Lang.allCases where lang.canBeHome {
            XCTAssertFalse(UIStrings.of(lang).updateRequired.isEmpty)
        }
    }
}
