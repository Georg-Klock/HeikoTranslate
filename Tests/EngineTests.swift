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
        // Filler the recognizer assigns to a language OUTSIDE the set
        // (measured: Dutch, Polish). `languageConstraints` did not stop
        // those, and an L3 run on OpenAI carried `fi`/`id` votes. Whatever
        // comes back must be one of the four, or nothing.
        for filler in ["ok ok ok ok ok ok", "Hmm hmm hmm hmm", "mhm mhm mhm mhm"] {
            let code = TranscriptLanguageWitness.classify(filler, candidates: languageSet)
            XCTAssertTrue(code == nil || languageSet.contains(code!), "\(filler) voted \(code!)")
        }
    }

    /// L1.129c — short replies vote when the recognizer is sure, and only
    /// then.
    ///
    /// Device run 2026-09-23 on OpenAI: "Ja, gerne." landed LEFT. OpenAI's
    /// home session repeats home speech rather than staying silent, and the
    /// old 12-character minimum left the turn with no vote to say the speech
    /// was German, so the repeat read as a translation. The bar for short
    /// text is now confidence, not length.
    func testL1_129c_shortRepliesVoteOnlyWhenSure() {
        XCTAssertEqual(TranscriptLanguageWitness.classify("Ja, gerne.", candidates: languageSet), "de")
        XCTAssertEqual(TranscriptLanguageWitness.classify("Danke.", candidates: languageSet), "de")
        XCTAssertEqual(TranscriptLanguageWitness.classify("Yeah", candidates: languageSet), "en")
        XCTAssertEqual(TranscriptLanguageWitness.classify("Thank you.", candidates: languageSet), "en")
        for unsure in ["Ja", "Okay.", "Perfekt."] {
            XCTAssertNil(TranscriptLanguageWitness.classify(unsure, candidates: languageSet),
                         "\(unsure) is too ambiguous to vote")
        }
    }

    /// L1.134 — a bubble does not open with the previous sentence's
    /// punctuation, and keeps its own Spanish opening mark.
    ///
    /// Seen on device 2026-09-23 as ". Und wo kann ich…" and "? We can
    /// call…": a turn's closing punctuation arriving after its commit.
    func testL1_134_bubbleDropsStrayLeadingPunctuation() {
        let b = TurnLogic.Bubble(original: " . Und wo kann ich ein Taxi bekommen?",
                                 translation: "? And where can I get a taxi?", isHome: true)
        XCTAssertEqual(b.original, "Und wo kann ich ein Taxi bekommen?")
        XCTAssertEqual(b.translation, "And where can I get a taxi?")
        XCTAssertEqual(TurnLogic.Bubble.withoutStrayLead("¿Dónde está?"), "¿Dónde está?")
        XCTAssertEqual(TurnLogic.Bubble.withoutStrayLead("…"), "")
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

    // MARK: - Silence gate

    /// Feeds `seconds` of 100ms chunks at one loudness, returning what the
    /// gate sent. Each chunk's first byte is its index, so order is checkable.
    private func feed(_ gate: inout AudioGate, rms: Double, seconds: Double,
                      from start: inout Date, index: inout UInt8) -> [Data] {
        var sent: [Data] = []
        for _ in 0..<Int((seconds * 10).rounded()) {
            var chunk = Data(count: 3200)
            chunk[0] = index
            index &+= 1
            sent += gate.admit(chunk, rms: rms, at: start).send
            start = start.addingTimeInterval(0.1)
        }
        return sent
    }

    /// L1.135 — silence stays on the phone; speech goes out with the second
    /// before it, in order.
    ///
    /// OpenAI bills per minute of audio received, per session, silence
    /// included, and the app listens from launch (R4). The pre-roll is what
    /// keeps the gate from costing the first syllable: a word's onset is
    /// quieter than the threshold that opens the gate.
    func testL1_135_silenceIsHeldAndSpeechCarriesItsPreRoll() {
        var gate = AudioGate()
        var t = Date(timeIntervalSince1970: 0)
        var i: UInt8 = 0
        XCTAssertTrue(feed(&gate, rms: 30, seconds: 10, from: &t, index: &i).isEmpty,
                      "ten seconds of room noise: nothing sent")
        XCTAssertFalse(gate.isOpen)

        let onset = feed(&gate, rms: 3000, seconds: 0.1, from: &t, index: &i)
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(onset.count, 11, "one second of pre-roll (10 chunks) plus the loud chunk")
        XCTAssertEqual(onset.map { $0[0] }, Array(90...100).map(UInt8.init), "oldest first, nothing reordered")
    }

    /// L1.135b — the gate stays open through `hangover` after the last loud
    /// chunk, then closes; a pause shorter than that sends straight through.
    ///
    /// The model needs trailing silence to finish the sentence it is
    /// translating, and a speaker who breathes mid-sentence must not be cut.
    func testL1_135b_hangoverKeepsTheTailAndBridgesPauses() {
        var gate = AudioGate()
        var t = Date(timeIntervalSince1970: 0)
        var i: UInt8 = 0
        _ = feed(&gate, rms: 3000, seconds: 2, from: &t, index: &i)
        let pause = feed(&gate, rms: 30, seconds: 2, from: &t, index: &i)
        XCTAssertEqual(pause.count, 20, "a 2s pause inside the hangover is sent whole")
        _ = feed(&gate, rms: 3000, seconds: 1, from: &t, index: &i)
        let tail = feed(&gate, rms: 30, seconds: 10, from: &t, index: &i)
        XCTAssertEqual(Double(tail.count), AudioGate.hangover * 10, accuracy: 1,
                       "the tail is the hangover, then nothing")
        XCTAssertFalse(gate.isOpen)
        XCTAssertTrue(gate.summary.hasPrefix("audio gate: sent"))
        XCTAssertLessThan(gate.sentBytes, gate.offeredBytes)
    }

    // MARK: - One-session interpreter

    /// L1.136 — one session serves both sides: a reply goes to the side of
    /// the language it is IN, only once that language is known, and names
    /// the speaker's language as a vote on both sides.
    ///
    /// The service expects two sessions and reads direction from which one
    /// translated. The hub reproduces that shape from one connection: a
    /// German speaker's English reply must arrive on the English side only,
    /// held until its transcript says it is English.
    func testL1_136_interpreterRoutesTheReplyToItsLanguage() {
        var got: [String] = []
        let (hub, _) = InterpreterHub.makeForTesting(pair: ["de", "en"]) { lang, event in
            switch event {
            case .audioChunk: got.append("\(lang):audio")
            case .outputTranscript(let t): got.append("\(lang):out(\(t))")
            case .inputLanguage(let c): got.append("\(lang):vote(\(c))")
            case .turnComplete: got.append("\(lang):done")
            default: break
            }
        }
        hub.simulate(.audioChunk(Data([1, 2])))            // before any words: held
        XCTAssertTrue(got.isEmpty, "audio before the language is known is held, not guessed")
        hub.simulate(.outputTranscript("I'm doing well, thank you."))
        XCTAssertEqual(got, ["de:vote(de)", "en:vote(de)", "en:audio", "en:out(I'm doing well, thank you.)"])
        got = []
        hub.simulate(.audioChunk(Data([3])))
        hub.simulate(.turnComplete)
        XCTAssertEqual(got.filter { !$0.hasSuffix("done") }, ["en:audio"], "the rest of the reply follows directly")

        // The next reply starts fresh and can go the other way.
        got = []
        hub.simulate(.outputTranscript("Wo ist der Bahnhof, bitte?"))
        XCTAssertEqual(got, ["de:vote(en)", "en:vote(en)", "de:out(Wo ist der Bahnhof, bitte?)"])
    }

    /// L1.136b — a reply too short to classify mid-stream still goes
    /// somewhere at its end, on the better of the two readings.
    func testL1_136b_aShortReplyIsRoutedAtItsEnd() {
        var got: [String] = []
        let (hub, _) = InterpreterHub.makeForTesting(pair: ["de", "en"]) { lang, event in
            if case .outputTranscript = event { got.append(lang) }
        }
        hub.simulate(.outputTranscript("Ja"))
        XCTAssertTrue(got.isEmpty)
        hub.simulate(.turnComplete)
        XCTAssertEqual(got.count, 1, "delivered to exactly one side at the end of the reply")
    }

    // MARK: - Soniox

    private func token(_ text: String, final: Bool = true, status: String = "original",
                       language: String? = nil) -> [String: Any] {
        var t: [String: Any] = ["text": text, "is_final": final, "translation_status": status]
        if let language { t["language"] = language }
        return t
    }

    /// L1.137 — Soniox's tokens: finals only, originals are the speaker's
    /// words and vote, translations go to their language's voice stream, and
    /// `<end>` closes the utterance.
    ///
    /// Non-final tokens are revised by later messages, and the service
    /// appends every transcript it receives, so a non-final passed on would
    /// stay in the bubble after Soniox corrected it.
    func testL1_137_sonioxTokensBecomeWordsVotesAndVoice() {
        var p = SonioxTokenParser(pair: ["de", "en"])
        XCTAssertEqual(p.consume([token("Wo ist", final: false, language: "de")]), [.vote(language: "de")],
                       "a draft votes, but is not a transcript")
        let first = p.consume([
            token("Wo", language: "de"), token(" ist", language: "de"),
            token("Where", status: "translation", language: "en"),
            token(" is", status: "translation", language: "en"),
        ])
        XCTAssertEqual(first, [
            .vote(language: "de"),
            .spoken(text: "Wo ist"),
            .translated(text: "Where is", language: "en"),
            .speak(streamID: "u0-en", text: "Where is", language: "en", opens: true),
        ])
        let rest = p.consume([
            token(" der Bahnhof?", language: "de"),
            token(" the station?", status: "translation", language: "en"),
            token("<end>"),
        ])
        XCTAssertEqual(rest, [
            .vote(language: "de"),
            .spoken(text: " der Bahnhof?"),
            .translated(text: " the station?", language: "en"),
            .speak(streamID: "u0-en", text: " the station?", language: "en", opens: false),
            .endSpeech(streamID: "u0-en"),
            .utteranceEnded,
        ])
        // The reply opens a new stream, in the other language.
        let reply = p.consume([token("Right", language: "en"),
                               token("Rechts", status: "translation", language: "de")])
        XCTAssertEqual(reply.last, .speak(streamID: "u1-de", text: "Rechts", language: "de", opens: true))
        XCTAssertEqual(SonioxTokenParser.language(ofStream: "u1-de"), "de")
    }

    /// L1.137b — a translation labelled outside the pair is dropped rather
    /// than routed to a side that does not exist.
    func testL1_137b_sonioxIgnoresLanguagesOutsideThePair() {
        var p = SonioxTokenParser(pair: ["de", "en"])
        XCTAssertEqual(p.consume([token("Hola", status: "translation", language: "es")]), [])
    }

    /// L1.137c — a labelled output skips the hub's classification: it goes
    /// straight to its side, with no vote of the hub's own.
    func testL1_137c_labelledOutputGoesStraightToItsSide() {
        var got: [String] = []
        let (hub, _) = InterpreterHub.makeForTesting(pair: ["de", "en"]) { lang, event in
            switch event {
            case .audioChunk: got.append("\(lang):audio")
            case .inputLanguage: got.append("\(lang):vote")
            default: break
            }
        }
        hub.simulate(.audioChunk(Data([1])), language: "de")
        XCTAssertEqual(got, ["de:audio"])
    }

    /// L1.138 — the stale-code window is Gemini's, not Soniox's.
    ///
    /// Right after a German turn ends, a German code is a straggler on
    /// Gemini (the sessions re-announce a finished turn's language for ~2s)
    /// and must be dropped. On Soniox a code only exists while words are
    /// being spoken, so the same code is the speaker's next sentence, and
    /// dropping it left that sentence with no language at all.
    func testL1_138_sonioxCodesAreNeverStragglers() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var gemini = TurnLogic(home: .de, partner: .en)
        gemini.noteInputLanguage("de", from: .de, at: t0)
        gemini.endTurn(at: t0.addingTimeInterval(1))
        XCTAssertNil(gemini.noteInputLanguage("de", from: .de, at: t0.addingTimeInterval(2)),
                     "Gemini: a same-language code right after a turn is a straggler")

        var soniox = TurnLogic(home: .de, partner: .en)
        soniox.codesStraggle = false
        soniox.noteInputLanguage("de", from: .de, at: t0)
        soniox.endTurn(at: t0.addingTimeInterval(1))
        soniox.noteInputLanguage("de", from: .de, at: t0.addingTimeInterval(2))
        soniox.noteInputLanguage("de", from: .en, at: t0.addingTimeInterval(2.1))
        XCTAssertEqual(soniox.noteInputLanguage("de", from: .de, at: t0.addingTimeInterval(4)), .de,
                       "Soniox: the same code is the next sentence, and it settles")
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
        defaults.set(TranslationEngine.defaultGeneration, forKey: TranslationEngine.generationKey)
        defaults.set("carrier-pigeon", forKey: TranslationEngine.defaultsKey)
        XCTAssertEqual(TranslationEngine.load(from: defaults), .default)
        defaults.removePersistentDomain(forName: "EngineTests")
    }

    /// L1.139 — Soniox is the default, and a phone that picked an engine
    /// before the default changed is moved to it once; a choice made after
    /// that sticks.
    func testL1_139_newDefaultIsAdoptedOnceThenChoicesStick() {
        XCTAssertEqual(TranslationEngine.default, .soniox)
        let defaults = UserDefaults(suiteName: "EngineTests139")!
        defer { defaults.removePersistentDomain(forName: "EngineTests139") }
        defaults.set("openai-realtime", forKey: TranslationEngine.defaultsKey)   // picked while testing
        XCTAssertEqual(TranslationEngine.load(from: defaults), .soniox, "moved to the new default once")
        defaults.set("gemini", forKey: TranslationEngine.defaultsKey)            // chosen afterwards
        XCTAssertEqual(TranslationEngine.load(from: defaults), .gemini, "a later choice sticks")
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
