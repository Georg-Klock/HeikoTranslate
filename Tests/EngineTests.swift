import XCTest
@testable import HeikoTranslate

/// L1 tests for the engine choice (Gemini / OpenAI / Grok): the pieces the
/// other two engines need that Gemini did not — resampling, a language read
/// off the transcript, two wire dialects — plus the one piece of wiring a
/// user touches, the switch on the settings sheet. Test IDs match
/// TESTING.md §L1.
@MainActor
final class EngineTests: XCTestCase {

    private let languageSet = ["de", "en", "es", "ko"]

    private func pcm(_ samples: [Int16]) -> Data {
        var data = Data()
        for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func samples(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count - 1, by: 2).map {
            Int16(littleEndian: data.subdata(in: $0..<$0 + 2).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
        }
    }

    // MARK: - Resampler

    /// L1.128 — chunking does not change the resampled audio.
    ///
    /// The mic delivers ~10 chunks a second, and OpenAI hears the resampled
    /// stream. If each chunk were resampled on its own, every seam would be a
    /// discontinuity — a click ten times a second that the recognizer has to
    /// hear through. Resampling in pieces must equal resampling whole.
    func testL1_128_chunkedResamplingEqualsWholeResampling() {
        let input = (0..<1600).map { Int16(clamping: Int(8000 * sin(Double($0) / 7))) }
        var whole = PCMResampler16to24()
        let expected = samples(whole.process(pcm(input)))

        var chunked = PCMResampler16to24()
        var got: [Int16] = []
        var offset = 0
        for size in [160, 1, 333, 2, 500, 17, 587] {   // uneven, including 1-sample chunks
            got += samples(chunked.process(pcm(Array(input[offset..<offset + size]))))
            offset += size
        }
        XCTAssertEqual(offset, input.count)
        XCTAssertEqual(got, expected, "a chunk seam changed the audio")
        // 3:2, give or take the one sample held back for the next seam.
        XCTAssertEqual(Double(expected.count), Double(input.count) * 1.5, accuracy: 2)
    }

    /// L1.128b — a constant signal stays exactly constant: interpolation
    /// adds nothing of its own.
    func testL1_128b_resamplingAConstantIsExact() {
        var r = PCMResampler16to24()
        let out = samples(r.process(pcm(Array(repeating: 1234, count: 100))))
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0 == 1234 })
    }

    // MARK: - Language witness

    /// L1.129 — the transcript witness names the language, and abstains on
    /// too little text.
    ///
    /// OpenAI and Grok report no language code, and `TurnLogic` decides
    /// direction from codes. An early wrong vote steers a whole turn (the
    /// settle window waits for the FIRST code), so abstaining is part of the
    /// contract, not a weakness.
    func testL1_129_witnessNamesTheLanguageAndAbstainsOnFragments() {
        XCTAssertEqual(TranscriptLanguageWitness.classify("Wo ist hier der Bahnhof, bitte?", candidates: languageSet), "de")
        XCTAssertEqual(TranscriptLanguageWitness.classify("Where is the train station, please?", candidates: languageSet), "en")
        XCTAssertEqual(TranscriptLanguageWitness.classify("¿Dónde está la estación de tren?", candidates: languageSet), "es")
        XCTAssertEqual(TranscriptLanguageWitness.classify("기차역이 어디에 있나요?", candidates: languageSet), "ko")
        XCTAssertNil(TranscriptLanguageWitness.classify("Ja", candidates: languageSet), "two letters is a guess")
    }

    /// L1.129b — the witness forgets between utterances.
    ///
    /// A German reply right after an English sentence must not be classified
    /// together with it — that would vote English for the reply's opening,
    /// which is the stale-vote shape the settle window was built against.
    func testL1_129b_witnessForgetsAcrossAPause() {
        var w = TranscriptLanguageWitness(candidates: languageSet)
        let t0 = Date()
        XCTAssertEqual(w.note("Where is the train station? I need to catch a train.", at: t0), "en")
        // Within the gap, German fragments still sit on the English buffer...
        XCTAssertEqual(w.note(" Ja", at: t0.addingTimeInterval(0.2)), "en")
        // ...after a real pause they start fresh.
        let later = t0.addingTimeInterval(TranscriptLanguageWitness.utteranceGap + 0.5)
        XCTAssertEqual(w.note("Der Zug fährt um acht Uhr ab.", at: later), "de")
    }

    // MARK: - OpenAI dialect

    /// L1.130 — OpenAI's setup names the target, and audio goes out at 24kHz.
    func testL1_130_openAISetupAndAudioFormat() throws {
        let d = OpenAITranslateDialect(target: "de", languageSet: languageSet)
        let request = d.request(apiKey: "k")
        XCTAssertEqual(request.url?.path, "/v1/realtime/translations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")

        let setup = try XCTUnwrap(d.setupMessages().first)
        let session = try XCTUnwrap(setup["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual(output["language"] as? String, "de")

        let message = d.audioMessage(pcm(Array(repeating: 0, count: 160)))
        XCTAssertEqual(message["type"] as? String, "session.input_audio_buffer.append")
        let sent = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(message["audio"] as? String)))
        XCTAssertEqual(Double(sent.count / 2), 240, accuracy: 2, "160 samples at 16kHz is ~240 at 24kHz")
    }

    /// L1.130b — OpenAI's frames become the events the turn machinery reads,
    /// including a language code it never sent.
    func testL1_130b_openAIFramesBecomeEvents() {
        let d = OpenAITranslateDialect(target: "de", languageSet: languageSet)
        let heard = d.parse("session.input_transcript.delta",
                            ["delta": "Where is the train station, please?"])
        XCTAssertEqual(heard.map(describe), ["inputLanguage(en)", "inputTranscript"])

        XCTAssertEqual(d.parse("session.output_transcript.delta", ["delta": "Wo ist"]).map(describe),
                       ["outputTranscript"])
        let chunk = pcm([1, 2, 3]).base64EncodedString()
        XCTAssertEqual(d.parse("session.output_audio.delta", ["delta": chunk, "sample_rate": 24_000]).map(describe),
                       ["audioChunk"])
        XCTAssertEqual(d.parse("session.closed", [:]).map(describe), ["serverEnding"])
        XCTAssertEqual(d.parse("error", ["error": ["code": "bad", "message": "x"]]).map(describe), ["serverError"])
    }

    // MARK: - Grok dialect

    /// L1.131 — a cumulative transcript contributes only what is new.
    ///
    /// The service APPENDS every input transcript it receives. A frame that
    /// carries the whole transcript so far, appended as-is, would repeat
    /// every word of the turn once per update.
    func testL1_131_grokCumulativeTranscriptIsNotRepeated() {
        let d = GrokVoiceDialect(target: "de", languageSet: languageSet)
        var text = ""
        for (type, full) in [("conversation.item.input_audio_transcription.updated", "Where is"),
                             ("conversation.item.input_audio_transcription.updated", "Where is the train"),
                             ("conversation.item.input_audio_transcription.completed", "Where is the train station?")] {
            for case .event(.inputTranscript(let t)) in d.parse(type, ["item_id": "i1", "transcript": full]) {
                text += t
            }
        }
        XCTAssertEqual(text, "Where is the train station?")
    }

    /// L1.131b — each response prunes the history it leaves behind, so the
    /// next utterance meets a session that has only seen its instructions.
    func testL1_131b_grokPrunesHistoryAfterEachResponse() {
        let d = GrokVoiceDialect(target: "de", languageSet: languageSet)
        _ = d.parse("conversation.item.created", ["item": ["id": "user1"]])
        _ = d.parse("response.output_item.added", ["item": ["id": "reply1"]])
        let done = d.parse("response.done", [:])
        XCTAssertEqual(done.map(describe), ["turnComplete", "send(user1)", "send(reply1)"])
        XCTAssertEqual(d.parse("response.done", [:]).map(describe), ["turnComplete"],
                       "an item is deleted once, not every turn")
        XCTAssertTrue(d.instructions.contains("into German"))
    }

    // MARK: - Transport

    /// L1.132 — readiness is announced once, and a server `error` kills a
    /// session only before it is ready.
    ///
    /// The OpenAI-style protocols answer a rejected client event with an
    /// `error` frame and carry on. Treating every one as fatal would tear
    /// down a working session over, say, a history delete the server had
    /// already done.
    func testL1_132_transportReadinessAndErrorSeverity() {
        var events: [String] = []
        let session = RealtimeSocketSession(
            dialect: OpenAITranslateDialect(target: "de", languageSet: languageSet),
            apiKey: "k") { events.append(describe(.event($0))) }
        session.handleServerMessageForTesting(#"{"type":"error","error":{"code":"x","message":"early"}}"#)
        session.handleServerMessageForTesting(#"{"type":"session.updated","session":{}}"#)
        session.handleServerMessageForTesting(#"{"type":"session.updated","session":{}}"#)
        session.handleServerMessageForTesting(#"{"type":"error","error":{"code":"x","message":"late"}}"#)
        XCTAssertEqual(events, ["error", "setupComplete", "debug"])
        session.close()
    }

    /// L1.132b — a missing key says which one, instead of a bare 401.
    func testL1_132b_missingKeyIsNamed() {
        var message: String?
        let session = RealtimeSocketSession(
            dialect: GrokVoiceDialect(target: "en", languageSet: languageSet), apiKey: "") {
            if case .error(let m) = $0 { message = m }
        }
        session.connect()
        XCTAssertEqual(message, "no API key for grok/en in Secrets.plist")
        session.close()
    }

    // MARK: - The switch

    /// L1.133 — choosing an engine mid-conversation switches the sessions
    /// once, on dismissal, like a language change (#146); choosing the one
    /// already running costs nothing.
    func testL1_133_engineChangeRestartsOnceOnDismiss() async {
        let vm = ConversationViewModel()
        vm.homeLang = .de
        vm.partnerLang = .en
        vm.engine = .gemini
        defer { vm.engine = .gemini }
        vm.permissionRequestForTesting = { true }
        vm.serviceStartForTesting = { true }
        await vm.beginListening()
        XCTAssertEqual(vm.runningEngine, .gemini)

        vm.engine = .openAI
        vm.engine = .grok
        XCTAssertEqual(vm.languageRestartCount, 0, "the sheet is open: nothing reaches the sessions")
        XCTAssertEqual(UserDefaults.standard.string(forKey: TranslationEngine.defaultsKey), "grok",
                       "the choice persists at once")
        vm.languageSelectionDidFinish()
        XCTAssertEqual(vm.languageRestartCount, 1)

        let settled = ConversationViewModel()   // same defaults: same engine
        XCTAssertEqual(settled.engine, .grok, "the choice survives a relaunch")
    }

    /// L1.133b — picking the running engine again restarts nothing, and an
    /// unknown stored value falls back to Gemini instead of failing.
    func testL1_133b_sameEngineIsFreeAndUnknownFallsBack() async {
        let vm = ConversationViewModel()
        vm.engine = .gemini
        vm.permissionRequestForTesting = { true }
        vm.serviceStartForTesting = { true }
        await vm.beginListening()
        vm.engine = .openAI
        vm.engine = .gemini
        vm.languageSelectionDidFinish()
        XCTAssertEqual(vm.languageRestartCount, 0)

        let defaults = UserDefaults(suiteName: "EngineTests")!
        defaults.set("carrier-pigeon", forKey: TranslationEngine.defaultsKey)
        XCTAssertEqual(TranslationEngine.load(from: defaults), .gemini)
        defaults.removePersistentDomain(forName: "EngineTests")
    }
}

/// A comparable name for a dialect output, so tests read as a sequence.
private func describe(_ output: DialectOutput) -> String {
    switch output {
    case .event(let e):
        switch e {
        case .inputLanguage(let c): return "inputLanguage(\(c))"
        case .inputTranscript: return "inputTranscript"
        case .outputTranscript: return "outputTranscript"
        case .audioChunk: return "audioChunk"
        case .turnComplete: return "turnComplete"
        case .setupComplete: return "setupComplete"
        case .error: return "error"
        case .debug: return "debug"
        default: return "\(e)"
        }
    case .send(let json): return "send(\(json["item_id"] as? String ?? "?"))"
    case .serverError: return "serverError"
    case .serverEnding: return "serverEnding"
    }
}
