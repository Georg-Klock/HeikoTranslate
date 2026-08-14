import XCTest
@testable import HeikoTranslate

/// GitHub #112: the spoken translation stutters — a false start, then the
/// corrected sentence — while the written bubble is always right.
///
/// The cause is in `GeminiLiveTranslationService`: every audio chunk of a
/// turn is held in `pendingOutput` and all of them are played at commit,
/// with no way to drop the ones belonging to a rendering the model
/// abandoned. The server says when that happens — `serverContent.interrupted`
/// — and the app listed that key as known-benign and read it nowhere.
///
/// These tests pin the parser end of the diagnostic that establishes whether
/// this preview model sends the signal at all. They deliberately do NOT pin
/// any behaviour change: nothing is discarded yet, because `turnComplete`
/// and `generationComplete` are documented as unreliable on this model and
/// `interrupted` may be too. A frame that is silently swallowed looks
/// identical to a model that never sends one, which is the confusion this
/// has to end.
final class InterruptedSignalTests: XCTestCase {

    /// Collect events from the real parser, driven without a socket.
    private func events(from frame: String) -> [GeminiLiveSession.Event] {
        var collected: [GeminiLiveSession.Event] = []
        let session = GeminiLiveSession(targetLanguageCode: "en",
                                        apiKey: "not-used-no-socket-is-opened",
                                        onEvent: { collected.append($0) })
        session.handleServerMessageForTesting(frame)
        return collected
    }

    private func containsInterrupted(_ events: [GeminiLiveSession.Event]) -> Bool {
        events.contains { if case .interrupted = $0 { return true }; return false }
    }

    /// L1.80 — an `interrupted` frame surfaces as `.interrupted`.
    ///
    /// Fail-first: before the parser read the key, this frame produced no
    /// event at all — the shape #112 was invisible in.
    func testL1_80_interruptedFrameSurfacesAsAnEvent() {
        XCTAssertTrue(containsInterrupted(events(from: #"{"serverContent":{"interrupted":true}}"#)),
                      "an interrupted frame must reach the orchestrator — silently dropping it is #112")
    }

    /// L1.80b — `interrupted` is read as a BOOLEAN, not as key presence.
    /// `"interrupted": false` is the server saying the response was NOT
    /// abandoned; treating the key's mere presence as truth would discard
    /// good audio once the fix lands on top of this.
    func testL1_80b_interruptedFalseIsNotAnInterruption() {
        XCTAssertFalse(containsInterrupted(events(from: #"{"serverContent":{"interrupted":false}}"#)),
                       "interrupted:false means the response stands")
    }

    /// L1.80c — the signal survives arriving alongside the content it
    /// supersedes. The real frame that matters carries a transcript in the
    /// same message, and an early `return` in the parser would lose it.
    func testL1_80c_interruptedIsNotLostWhenItSharesAFrameWithContent() {
        let frame = #"""
        {"serverContent":{"outputTranscription":{"text":"Where"},"interrupted":true}}
        """#
        let collected = events(from: frame)
        XCTAssertTrue(containsInterrupted(collected),
                      "interrupted must survive sharing a frame with a transcript")
        XCTAssertTrue(collected.contains { if case .outputTranscript(let t) = $0 { return t == "Where" }; return false },
                      "and must not swallow the transcript it arrived with")
    }

    /// L1.80d — an ordinary frame does not produce the signal, so a log line
    /// on device means something. Without this the diagnostic could fire on
    /// every frame and prove nothing.
    func testL1_80d_ordinaryFramesDoNotSignalInterruption() {
        XCTAssertFalse(containsInterrupted(events(from: #"{"serverContent":{"turnComplete":true}}"#)))
        XCTAssertFalse(containsInterrupted(events(from: #"{"serverContent":{"outputTranscription":{"text":"Where can I find"}}}"#)))
        XCTAssertFalse(containsInterrupted(events(from: #"{"setupComplete":{}}"#)))
    }

    /// L1.80e — `interrupted` stays a KNOWN key, so surfacing it did not
    /// turn every interruption into an "unrecognized keys" diagnostic. The
    /// two mechanisms are independent and both must hold.
    func testL1_80e_interruptedDoesNotAlsoLogAsUnrecognized() {
        let collected = events(from: #"{"serverContent":{"interrupted":true}}"#)
        XCTAssertFalse(collected.contains { if case .raw = $0 { return true }; return false },
                       "a recognised key must not also be surfaced as raw")
    }
}
