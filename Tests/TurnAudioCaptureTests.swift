import XCTest
@testable import HeikoTranslate

/// GitHub #135, Phase 0: the capture that produces the corpus a candidate
/// language decider is scored on.
///
/// **Why this is tested at L1 rather than found on a phone.** The capture runs
/// during a device session that needs a person, a room and a native partner
/// voice. If the WAV header is wrong, nothing fails: the app behaves normally,
/// files appear, and the corpus is silently unusable — a header claiming the
/// wrong sample rate makes every clip play at the wrong speed and measure as a
/// different language. That failure costs a whole session and looks like a bad
/// model. It is cheap to pin here and expensive to discover there.
///
/// The privacy invariant is tested first and deliberately: a capture that
/// writes when it was not switched on is a much worse bug than one that fails
/// to write.
final class TurnAudioCaptureTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-audio-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    /// One second of 16 kHz mono Int16, as the wire path produces it.
    private func pcm(seconds: Double = 1.0, value: Int16 = 1234) -> Data {
        let count = Int(Double(TurnAudioCapture.sampleRate) * seconds)
        var samples = [Int16](repeating: value, count: count)
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func wavFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
    }

    private func manifestLines() -> [String] {
        let url = directory.appendingPathComponent("manifest.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian
        }
    }

    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt16.self).littleEndian
        }
    }

    private func ascii(_ data: Data, _ offset: Int) -> String {
        String(decoding: data.subdata(in: offset..<(offset + 4)), as: UTF8.self)
    }

    // MARK: - L1.104: the privacy invariant

    /// The default. A build that has not been deliberately switched on must
    /// leave no trace whatsoever — not an empty directory, not a manifest.
    func testL1_104_disabledCaptureWritesNothing() {
        let capture = TurnAudioCapture(directory: directory, enabled: false)
        capture.start(home: .de, partner: .es)
        capture.append(pcm())
        capture.finish(decision: "de")

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "capture is off: it must not even create its directory")
    }

    /// The flag rule, tested on the parse rather than on `isEnabled`.
    ///
    /// `isEnabled` reads whatever `Secrets.plist` this machine has, and that
    /// file is gitignored and legitimately carries the flag during a
    /// measurement run — asserting on it turns L1 red on the one machine
    /// mid-experiment, for a reason unrelated to the code. The invariant that
    /// actually matters is that ONLY an explicit true switches capture on:
    /// no plist, no key, or any other value must be off, which covers every
    /// build from a clean checkout and every CI run.
    func testL1_104a_captureIsOffUnlessExplicitlyEnabled() {
        XCTAssertFalse(TurnAudioCapture.captureFlag(in: nil), "no plist at all")
        XCTAssertFalse(TurnAudioCapture.captureFlag(in: [:]), "no keys")
        XCTAssertFalse(TurnAudioCapture.captureFlag(in: ["GEMINI_API_KEY": "x"]),
                       "the key is absent — this is what a shipped build looks like")
        XCTAssertFalse(TurnAudioCapture.captureFlag(in: ["CAPTURE_TURN_AUDIO": false]))
        XCTAssertFalse(TurnAudioCapture.captureFlag(in: ["CAPTURE_TURN_AUDIO": "NO"]))
        XCTAssertFalse(TurnAudioCapture.captureFlag(in: ["CAPTURE_TURN_AUDIO": 0]))

        XCTAssertTrue(TurnAudioCapture.captureFlag(in: ["CAPTURE_TURN_AUDIO": true]))
        XCTAssertTrue(TurnAudioCapture.captureFlag(in: ["CAPTURE_TURN_AUDIO": "YES"]),
                      "a hand-edited plist may carry the string form")
    }

    // MARK: - L1.104b–d: the header that would fail silently

    func testL1_104b_writesOneWavPerFinishedTurn() {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .es)
        capture.append(pcm(seconds: 0.5))
        capture.finish(decision: "de")
        capture.append(pcm(seconds: 0.5))
        capture.finish(decision: "es")

        XCTAssertEqual(wavFiles().count, 2, "one file per committed turn")
        XCTAssertEqual(manifestLines().count, 2, "one manifest row per file")
    }

    /// The load-bearing one. Every field a decoder reads must match the wire
    /// format the app actually captured, because a wrong value here is
    /// inaudible to the app and fatal to the corpus.
    func testL1_104c_wavHeaderDeclaresTheWireFormat() throws {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .es)
        let audio = pcm(seconds: 2.0)
        capture.append(audio)
        capture.finish(decision: "de")

        let url = try XCTUnwrap(wavFiles().first)
        let file = try Data(contentsOf: url)

        XCTAssertEqual(ascii(file, 0), "RIFF")
        XCTAssertEqual(ascii(file, 8), "WAVE")
        XCTAssertEqual(ascii(file, 12), "fmt ")
        XCTAssertEqual(u32(file, 16), 16, "PCM fmt chunk is 16 bytes")
        XCTAssertEqual(u16(file, 20), 1, "format 1 = uncompressed PCM")
        XCTAssertEqual(u16(file, 22), 1, "mono")
        XCTAssertEqual(u32(file, 24), UInt32(TurnAudioCapture.sampleRate),
                       "16 kHz — a wrong rate here plays the clip at the wrong speed and measures as another language")
        XCTAssertEqual(u16(file, 34), 16, "16-bit samples")
        XCTAssertEqual(u32(file, 28), UInt32(TurnAudioCapture.sampleRate * 2),
                       "byte rate = rate x channels x bytes-per-sample")
        XCTAssertEqual(u16(file, 32), 2, "block align = channels x bytes-per-sample")
        XCTAssertEqual(ascii(file, 36), "data")

        // The two length fields must agree with the real payload, or decoders
        // truncate or read past the end.
        XCTAssertEqual(u32(file, 40), UInt32(audio.count), "data chunk size")
        XCTAssertEqual(u32(file, 4), UInt32(36 + audio.count), "RIFF size = 36 + data")
        XCTAssertEqual(file.count, 44 + audio.count, "44-byte header, then the samples")
    }

    /// The samples must survive unchanged. A capture that quietly resamples or
    /// re-encodes would measure something other than what the session sent.
    func testL1_104d_samplesAreByteIdentical() throws {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .es)
        let audio = pcm(seconds: 0.25, value: -4321)
        capture.append(audio)
        capture.finish(decision: "de")

        let file = try Data(contentsOf: try XCTUnwrap(wavFiles().first))
        XCTAssertEqual(file.suffix(from: 44), audio, "payload must be the bytes that were appended")
    }

    // MARK: - L1.104e–f: the manifest must not invent ground truth

    func testL1_104e_manifestRecordsDecisionAndLeavesTruthNull() throws {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .fr)
        capture.append(pcm(seconds: 0.5))
        capture.finish(decision: "REJECTED codes-veto")

        let line = try XCTUnwrap(manifestLines().first)
        XCTAssertTrue(line.contains("\"decision\":\"REJECTED codes-veto\""), line)
        XCTAssertTrue(line.contains("\"home\":\"de\""), line)
        XCTAssertTrue(line.contains("\"partner\":\"fr\""), line)
        // The whole point: the app's answer is the thing under test, so it must
        // never be recorded as the answer. A bench that read `decision` as
        // truth would score the app against itself and always agree.
        XCTAssertTrue(line.contains("\"truth\":null"),
                      "truth must be null until a human labels it — never the app's own verdict")
    }

    func testL1_104f_manifestRowIsParseableJSON() throws {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .es)
        capture.append(pcm(seconds: 0.1))
        // A reject reason carrying a quote and a backslash — the escaping path.
        capture.finish(decision: "REJECTED \"odd\" \\ reason")

        let line = try XCTUnwrap(manifestLines().first)
        let data = try XCTUnwrap(line.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let row = try XCTUnwrap(object)
        XCTAssertEqual(row["decision"] as? String, "REJECTED \"odd\" \\ reason")
        XCTAssertTrue(row["truth"] is NSNull, "truth is null, not absent and not empty")
    }

    // MARK: - L1.104g–h: one turn's audio must not become another's evidence

    func testL1_104g_rotateDiscardsUnwrittenAudio() {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .es)
        capture.append(pcm(seconds: 1.0))
        capture.rotate()                       // turn ended without a commit
        capture.append(pcm(seconds: 0.25))
        capture.finish(decision: "es")

        let files = wavFiles()
        XCTAssertEqual(files.count, 1)
        let size = (try? Data(contentsOf: files[0]).count) ?? 0
        let expected = 44 + Int(Double(TurnAudioCapture.sampleRate) * 0.25) * 2
        XCTAssertEqual(size, expected,
                       "the discarded turn's second of audio must not be prepended to this one")
    }

    func testL1_104h_finishWithNoAudioWritesNothing() {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .es)
        capture.finish(decision: "de")
        XCTAssertTrue(wavFiles().isEmpty, "a silent turn is not a clip")
        XCTAssertTrue(manifestLines().isEmpty, "and must not leave a row pointing at no file")
    }

    // MARK: - L1.104o–p: our own voice is not evidence

    /// Measured 2026-08-17 (build 2.4.64): captured clips contained TWO
    /// languages — the app's German translation of the previous turn, leaking
    /// past the echo canceller into the start of the buffer, then the French
    /// that was actually spoken. `turn-0001`'s envelope showed 600–2000 RMS
    /// from 8.75 s to 12.5 s, then real speech at 4400 from 13.25 s. A clip
    /// carrying both is not mislabelled by a model that reads the German —
    /// the clip is wrong, and no trim can separate them.
    func testL1_104o_dropsAudioWhileTheAppIsSpeaking() throws {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .fr)

        capture.setPlayingOutput(true)
        capture.append(pcm(seconds: 2.0, value: 6000))   // our own output
        capture.setPlayingOutput(false)
        // The tail after playback is dropped too — our output is still
        // decaying in the room and the AEC's estimate lags.
        capture.append(pcm(seconds: 0.2, value: 6000))

        XCTAssertNil(TurnAudioCapture.speechBounds(in: Data()),
                     "sanity: no speech in nothing")
        capture.finish(decision: "fr")
        XCTAssertTrue(wavFiles().isEmpty,
                      "a turn that only contains our own voice is not a clip")
    }

    /// And the gate must open again, or the capture silently records nothing
    /// for the rest of the session — a failure that looks exactly like a
    /// capture that was never enabled.
    func testL1_104p_recordsAgainAfterPlaybackTailPasses() throws {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .fr)

        capture.setPlayingOutput(true)
        capture.append(pcm(seconds: 1.0, value: 6000))
        capture.setPlayingOutput(false)

        // Past the 0.4s tail.
        Thread.sleep(forTimeInterval: 0.45)
        capture.append(pcm(seconds: 1.0, value: 6000))
        capture.finish(decision: "fr")

        let file = try Data(contentsOf: try XCTUnwrap(wavFiles().first))
        let seconds = Double((file.count - 44) / 2) / Double(TurnAudioCapture.sampleRate)
        XCTAssertEqual(seconds, 1.0, accuracy: 0.1,
                       "only the audio after the tail, and all of it")
    }

    // MARK: - L1.104k–n: the trim, measured on device before it existed

    /// Silence either side of the speech must go. Measured 2026-08-17 (build
    /// 2.4.64): the first real capture run produced five clips of 16.5–18.8 s
    /// that were 5–20% speech, because a turn's buffer runs from the previous
    /// commit and carries every second of silence since. A clip that is nine
    /// parts room tone measures room tone.
    func testL1_104k_trimsSilenceToTheUtterance() throws {
        var buffer = Data()
        buffer.append(pcm(seconds: 8.0, value: 0))        // dead air before
        buffer.append(pcm(seconds: 1.0, value: 6000))     // the utterance
        buffer.append(pcm(seconds: 7.0, value: 0))        // dead air after

        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .fr)
        capture.append(buffer)
        capture.finish(decision: "fr")

        let file = try Data(contentsOf: try XCTUnwrap(wavFiles().first))
        let seconds = Double((file.count - 44) / 2) / Double(TurnAudioCapture.sampleRate)
        // 1 s of speech plus 0.25 s margin either side, and nothing like 16 s.
        XCTAssertEqual(seconds, 1.5, accuracy: 0.1,
                       "the clip must be the utterance, not the turn window")
    }

    /// The margin is not decoration: a hard cut at the first loud frame clips
    /// word onsets, and onset is what a phonotactic classifier reads.
    func testL1_104l_keepsMarginAroundTheSpeech() throws {
        var buffer = Data()
        buffer.append(pcm(seconds: 2.0, value: 0))
        buffer.append(pcm(seconds: 0.5, value: 6000))
        buffer.append(pcm(seconds: 2.0, value: 0))

        let bounds = try XCTUnwrap(TurnAudioCapture.speechBounds(in: buffer))
        let startSeconds = Double(bounds.lowerBound / 2) / Double(TurnAudioCapture.sampleRate)
        XCTAssertEqual(startSeconds, 1.75, accuracy: 0.05, "0.25 s kept before the onset")
        XCTAssertGreaterThan(bounds.count, 0)
    }

    /// A turn that never crossed the mic floor is not a clip. It would enter
    /// the corpus as a labellable file with nothing in it to label.
    func testL1_104m_dropsTurnsWithNoSpeech() {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .fr)
        capture.append(pcm(seconds: 12.0, value: 0))
        capture.finish(decision: "fr")

        XCTAssertTrue(wavFiles().isEmpty, "room tone is not an utterance")
        XCTAssertTrue(manifestLines().isEmpty)
        XCTAssertNil(TurnAudioCapture.speechBounds(in: pcm(seconds: 1.0, value: 0)))
    }

    /// Both durations are recorded, so the trim is auditable. A clip whose raw
    /// span was 18 s and whose speech was 1 s is a different turn from one that
    /// was 1 s all along, and only the pair distinguishes them.
    func testL1_104n_manifestKeepsRawAndTrimmedDurations() throws {
        var buffer = Data()
        buffer.append(pcm(seconds: 6.0, value: 0))
        buffer.append(pcm(seconds: 1.0, value: 6000))

        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .fr)
        capture.append(buffer)
        capture.finish(decision: "fr")

        let row = try XCTUnwrap(manifestLines().first)
        let data = try XCTUnwrap(row.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let seconds = Double(try XCTUnwrap(object["seconds"] as? String)) ?? 0
        let raw = Double(try XCTUnwrap(object["rawSeconds"] as? String)) ?? 0
        XCTAssertEqual(raw, 7.0, accuracy: 0.05, "the whole turn window")
        XCTAssertLessThan(seconds, 1.6, "the speech inside it")
        XCTAssertGreaterThan(raw, seconds, "and the pair shows the trim happened")
    }

    /// `append` runs on the audio render thread, so an unbounded buffer is a
    /// memory bug on a 3 GB phone. The cap must hold and must be recorded, so a
    /// truncated clip is not silently scored as a whole turn.
    func testL1_104i_capsRunawayTurnsAndFlagsThem() throws {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .es)
        for _ in 0..<70 { capture.append(pcm(seconds: 1.0)) }   // 70s against a 60s cap
        capture.finish(decision: "de")

        let file = try Data(contentsOf: try XCTUnwrap(wavFiles().first))
        let maxBytes = TurnAudioCapture.sampleRate * 2 * 60
        XCTAssertLessThanOrEqual(file.count, 44 + maxBytes, "the cap must actually bound the buffer")
        XCTAssertTrue(try XCTUnwrap(manifestLines().first).contains("\"truncated\":\"true\""),
                      "a truncated clip must say so, or it is scored as a complete turn")
    }

    /// Nothing may be written after the session ends — `stop` clears the pair,
    /// and a late buffer from a render thread that has not noticed yet must be
    /// dropped rather than attributed to the next session.
    func testL1_104j_stopEndsCapture() {
        let capture = TurnAudioCapture(directory: directory, enabled: true)
        capture.start(home: .de, partner: .es)
        capture.stop()
        capture.append(pcm(seconds: 0.5))
        capture.finish(decision: "de")
        XCTAssertTrue(wavFiles().isEmpty, "audio arriving after stop belongs to no turn")
    }
}
