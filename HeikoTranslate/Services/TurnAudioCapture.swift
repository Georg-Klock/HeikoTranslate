import Foundation

/// Writes each turn's microphone audio to a file, labelled with what the app
/// decided, so a language decider can be measured off-device against real
/// speech instead of argued about (#135, Phase 0).
///
/// **Why this exists.** Every candidate for the "second witness" — a dedicated
/// language-ID model, a pair-restricted softmax, the existing two-session
/// arbitration — can be scored on the same clips, on a laptop, in minutes.
/// What has been missing is the clips. The diagnostic log carries both sides
/// of every turn as TEXT, which is exactly the corrupted evidence the whole
/// experiment is about: when the wrong-language session mis-transcribes, the
/// transcript agrees with it. Audio is the only artifact that lets a different
/// model disagree.
///
/// **The format is deliberate.** This captures the bytes the app already
/// converted for the wire — 16 kHz mono Int16 — rather than the raw tap
/// buffer. So a bench measures what Gemini actually heard, including whatever
/// the echo canceller and the converter did to it. A capture at the tap would
/// measure a different signal from the one that produced the failure.
///
/// **Privacy — read before enabling.** This writes real conversation audio to
/// the app container. Three things keep that honest, and all three must stay
/// true:
///
/// 1. **Off unless deliberately switched on.** The flag lives in
///    `Secrets.plist`, which is gitignored, so no committed state can turn it
///    on and a build made from a clean checkout cannot have it.
/// 2. **Nothing leaves the phone by itself.** Same rule the log lives by
///    (#8): the files sit in the container until a human runs
///    `Tools/pull_logs.sh`. No upload path exists here, and none may be added.
/// 3. **`docs/privacy-policy.md` is unaffected.** The policy's claim is about
///    which third party receives microphone audio. Writing to local storage
///    adds no recipient, and default-off adds no behaviour to a shipped build.
///
/// Recordings are Heiko's and his partner's voices. When a capture has served
/// its measurement, delete it; do not let a corpus of other people's
/// conversations accumulate because it was convenient. Nothing captured here
/// is ever committed — `logs/` is gitignored and this writes beside it.
///
/// Failure is inert everywhere (R8). No directory, no disk, a write that
/// throws: the capture records nothing and the app behaves exactly as it does
/// with the feature off. Nothing in this type may become load-bearing.
final class TurnAudioCapture: @unchecked Sendable {

    typealias Lang = TurnLogic.Lang

    /// Whether to capture at all, read once from the bundle.
    static let isEnabled: Bool = {
        // Same rule as AppConfig.interpreterMode: a measurement flag must not
        // reach the suite. Without this, a machine with capture enabled has
        // L1 writing real WAVs into the app container from every service test.
        if AppConfig.isRunningTests { return false }
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return captureFlag(in: plist)
    }()

    /// The rule, separated from where the plist comes from.
    ///
    /// Tested directly (L1.104a) rather than through `isEnabled`, because
    /// `isEnabled` reads whatever `Secrets.plist` this machine happens to have
    /// — and that file is gitignored and legitimately carries the flag during a
    /// measurement run. A test asserting on it turns L1 red for a reason that
    /// has nothing to do with the code, on the one machine that is mid-
    /// experiment. What must actually hold is this: **an absent key is off**,
    /// so a build with no such entry — every build made from a clean checkout,
    /// and every CI run, which has no `Secrets.plist` at all — cannot capture.
    static func captureFlag(in plist: [String: Any]?) -> Bool {
        guard let plist else { return false }
        // Accept a real boolean or the string form, because a plist edited by
        // hand acquires whichever the editor felt like writing.
        if let flag = plist["CAPTURE_TURN_AUDIO"] as? Bool { return flag }
        if let flag = plist["CAPTURE_TURN_AUDIO"] as? String {
            return ["YES", "true", "1"].contains(flag)
        }
        return false
    }

    /// The wire format, restated here so the WAV header cannot drift from it.
    /// If `GeminiLiveTranslationService`'s `targetFormat` ever changes, this
    /// must change with it — a header claiming 16 kHz over 24 kHz samples
    /// produces audio that plays slow and measures as a different language.
    static let sampleRate = 16_000
    private static let bytesPerSample = 2

    /// A turn longer than this is not a turn. The cap exists because `append`
    /// runs on the render thread and a stuck turn would otherwise grow without
    /// bound; 60 s is far past anything the turn clock allows.
    private static let maxBytes = sampleRate * bytesPerSample * 60

    private let lock = NSLock()
    private var pcm = Data()
    private var truncated = false
    private var home: Lang?
    private var partner: Lang?
    private var isPlayingOutput = false
    private var playbackEndedAt: Date?
    private var turnIndex = 0

    /// Where captures land. A sibling of the diagnostic log rather than a
    /// subdirectory of it, so log rotation can never delete audio and
    /// `Tools/pull_logs.sh` picks both up in one pass.
    private let directory: URL
    private let manifestURL: URL

    /// Whether THIS instance captures. Defaults to the plist flag, so the app
    /// is off unless deliberately switched on; tests inject `true` with a
    /// temporary directory so the real type is exercised rather than a copy of
    /// its logic. Without this seam `isEnabled` is a `Bundle.main` read that no
    /// test can reach, and a WAV header is exactly the kind of thing that is
    /// wrong silently — every captured file would measure as a different
    /// language and a whole device session would be wasted before anyone knew.
    private let enabled: Bool

    /// Distinguishes this launch's clips from every other launch's.
    ///
    /// **Measured 2026-08-17.** The turn counter restarts at 1 each launch, so
    /// a second session's `turn-0001-de-fr.wav` silently REPLACED the first
    /// session's file while the first session's manifest row stayed — still
    /// describing a clip that no longer existed. A labeller would have heard
    /// one utterance and recorded a label for another, and nothing in the data
    /// would have shown it: 15 rows, 8 files, no error anywhere. Evidence that
    /// overwrites itself is worse than evidence that is missing.
    private let session: String

    init(directory: URL? = nil, enabled: Bool = TurnAudioCapture.isEnabled,
         session: String? = nil) {
        self.session = session ?? Self.sessionStamp.string(from: Date())
        let base = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("turn-audio", isDirectory: true)
        self.directory = base
        self.manifestURL = base.appendingPathComponent("manifest.jsonl")
        self.enabled = enabled
    }

    // MARK: - Lifecycle

    /// Begin a capture session for one language pair. Safe to call when
    /// disabled; it does nothing.
    func start(home: Lang, partner: Lang) {
        guard enabled else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            DiagnosticLog.shared.log("capture", "cannot create \(directory.lastPathComponent) — capture off: \(error.localizedDescription)")
            return
        }
        lock.lock()
        self.home = home
        self.partner = partner
        pcm.removeAll(keepingCapacity: true)
        truncated = false
        isPlayingOutput = false
        playbackEndedAt = nil
        lock.unlock()
        DiagnosticLog.shared.log("capture", "TURN AUDIO CAPTURE IS ON — writing \(home.rawValue)/\(partner.rawValue) turns to \(directory.lastPathComponent)/")
    }

    func stop() {
        guard enabled else { return }
        lock.lock()
        home = nil
        partner = nil
        pcm.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    // MARK: - Audio

    /// Whether the app is speaking its own translation right now.
    ///
    /// **Measured 2026-08-17 (build 2.4.64), and the reason this exists.** The
    /// first device capture run produced clips containing TWO languages: the
    /// app's German translation of the PREVIOUS turn, played through the phone
    /// speaker into the mic at the start of the buffer, and the French phrase
    /// that was actually spoken at the end. The energy envelope of
    /// `turn-0001` shows it plainly — 600–2000 RMS bumps from 8.75 s to
    /// 12.5 s, then the real speech at 4400 from 13.25 s.
    ///
    /// Hardware echo cancellation attenuates our own output but does not
    /// remove it, and it does not have to: full-duplex is a feature, the
    /// residue is only a problem for a file that gets labelled with ONE
    /// language. A clip carrying both is not mislabelled by a candidate model
    /// that reads the German — the clip is wrong.
    ///
    /// Mirrored here behind this type's own lock rather than read from the
    /// service: `append` runs on the render thread and may not touch main-actor
    /// state.
    func setPlayingOutput(_ playing: Bool) {
        guard enabled else { return }
        lock.lock()
        isPlayingOutput = playing
        if !playing { playbackEndedAt = Date() }
        lock.unlock()
    }

    /// How long after playback stops to keep dropping audio. The tail of our
    /// own output is still decaying in the room, and the AEC's estimate lags.
    private static let playbackTailSeconds: TimeInterval = 0.4

    /// Called from the audio render thread with the SAME 16 kHz mono Int16
    /// bytes the session sends upstream. Must stay cheap: a lock and an
    /// append, no formatting, no file I/O, no allocation beyond the buffer's
    /// own growth.
    func append(_ chunk: Data) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard home != nil else { return }
        // Never record while we are talking, nor in the tail after it. This is
        // the difference between a corpus of utterances and a corpus of
        // conversations-with-ourselves.
        if isPlayingOutput { return }
        if let ended = playbackEndedAt,
           Date().timeIntervalSince(ended) < Self.playbackTailSeconds { return }
        guard pcm.count + chunk.count <= Self.maxBytes else {
            truncated = true
            return
        }
        pcm.append(chunk)
    }

    // MARK: - Writing

    /// Write this turn's audio with the app's own verdict attached, then clear.
    ///
    /// `decision` is what the app concluded, NOT ground truth — it is the
    /// thing under test. The manifest keeps a separate `truth` field, left
    /// null here and filled in by whoever labels the corpus. Conflating the
    /// two would make every bench score the app against itself and report
    /// perfect agreement.
    func finish(decision: String) {
        guard enabled else { return }
        lock.lock()
        let audio = pcm
        let wasTruncated = truncated
        let home = self.home
        let partner = self.partner
        pcm.removeAll(keepingCapacity: true)
        truncated = false
        turnIndex += 1
        let index = turnIndex
        lock.unlock()

        guard let home, let partner, !audio.isEmpty else { return }

        // Trim to the speech. A turn's buffer runs from the last commit to
        // this one, so it carries every second of silence since the previous
        // utterance — measured at 80–95% of the first device captures. A clip
        // that is mostly room tone measures room tone.
        //
        // A turn with NO speech in it is not a clip and is dropped here: it is
        // the app committing on something that never reached the mic floor,
        // and it would enter the corpus as a labellable file with nothing in
        // it to label.
        guard let speech = Self.speechBounds(in: audio) else {
            DiagnosticLog.shared.log("capture", "turn \(index) dropped — no audio above the speech floor")
            return
        }
        let trimmed = audio.subdata(in: speech)

        let name = String(format: "turn-%@-%04d-%@-%@.wav", session, index, home.rawValue, partner.rawValue)
        let url = directory.appendingPathComponent(name)
        do {
            try Self.wav(from: trimmed).write(to: url, options: .atomic)
        } catch {
            DiagnosticLog.shared.log("capture", "turn \(index) NOT written: \(error.localizedDescription)")
            return
        }

        func duration(_ bytes: Int) -> Double {
            Double(bytes / Self.bytesPerSample) / Double(Self.sampleRate)
        }
        let seconds = duration(trimmed.count)
        let rawSeconds = duration(audio.count)
        append(manifest: [
            "file": name,
            "home": home.rawValue,
            "partner": partner.rawValue,
            "decision": decision,
            "seconds": String(format: "%.2f", seconds),
            // Both durations, so the trim is auditable rather than a silent
            // edit to the evidence: a clip whose raw span was twenty seconds
            // and whose speech was one is a different turn from one that was
            // one second all along, and only the pair says which.
            "rawSeconds": String(format: "%.2f", rawSeconds),
            "truncated": wasTruncated ? "true" : "false",
            "recorded": Self.timestamp.string(from: Date()),
        ])
        DiagnosticLog.shared.log("capture", "turn \(index) → \(name) (\(String(format: "%.2f", seconds))s speech of \(String(format: "%.2f", rawSeconds))s, decision \(decision))")
    }

    /// A turn that ended without a commit — clear it rather than letting it
    /// run into the next one. The referee's `rotate()` rule, for the same
    /// reason: one turn's audio must not become another turn's evidence.
    func rotate() {
        guard enabled else { return }
        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        truncated = false
        lock.unlock()
    }

    // MARK: - Internals

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    /// Short enough to keep a filename readable, precise enough that two
    /// launches in the same minute do not collide.
    private static let sessionStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmmss"
        return f
    }()

    /// JSONL by hand rather than `JSONEncoder`: every value here is a string
    /// this type produced, the escaping surface is one function, and a
    /// manifest that keeps appending after a malformed row is worth more than
    /// a typed encoder that throws on one.
    private func append(manifest fields: [String: String]) {
        let body = fields.keys.sorted().map { key in
            "\"\(Self.escaped(key))\":\"\(Self.escaped(fields[key] ?? ""))\""
        }.joined(separator: ",")
        // `truth` is null, not "", so a labelling pass can tell "not yet
        // labelled" from "labelled as nothing".
        guard let line = "{\(body),\"truth\":null}\n".data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: manifestURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: manifestURL, options: .atomic)
        }
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// The speech floor the app already measured for the mic path
    /// (`micSpeechRMSFloor`), restated rather than shared because this type
    /// must not depend on the service. Room tone sits far below it; measured
    /// speech ran 991–5263.
    static let speechRMSFloor: Double = 400

    /// Keep this much either side of the speech. A hard cut at the first loud
    /// frame clips word onsets — plosives especially — and onset is exactly
    /// what a phonotactic classifier reads.
    private static let marginSeconds = 0.25

    /// The span of `pcm` that actually contains speech, or nil if none does.
    ///
    /// **Why this exists, measured on device 2026-08-17 (build 2.4.64).** The
    /// first real capture run produced five clips of 16.5–18.8 s that were
    /// **5–20% speech** — 0.9–3.7 s of French inside ~16 s of silence. The
    /// buffer accumulates from the start of a turn to its commit, and a turn
    /// spans the whole gap since the last one, so the dead air between
    /// utterances is captured as part of the utterance.
    ///
    /// That is not a cosmetic problem. Whisper zero-pads to 30 s and leading
    /// silence is a documented cause of wrong language verdicts; ECAPA and
    /// Silero average over frames, so nine parts silence to one part speech
    /// moves the embedding toward whatever silence looks like. The literature
    /// is blunt about the size of this: adding VAD and matching chunk length
    /// took 2-second error from 23.53 to 10.45 EER, more than every
    /// architectural change in the same paper combined.
    ///
    /// Deliberately a plain RMS gate rather than a real VAD: the decision here
    /// is only "where does the audio stop being room tone", the floor is one
    /// the app already measured, and a dependency that can fail is a
    /// dependency that can fail silently in a capture nobody is watching.
    static func speechBounds(in pcm: Data) -> Range<Int>? {
        let frame = sampleRate / 50                       // 20 ms
        let bytesPerFrame = frame * bytesPerSample
        guard pcm.count >= bytesPerFrame else { return nil }

        let samples = pcm.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self))
        }
        let frameCount = samples.count / frame

        var loud = [Bool](repeating: false, count: frameCount)
        for index in 0..<frameCount {
            let slice = samples[(index * frame)..<((index + 1) * frame)]
            var sum = 0.0
            for sample in slice { sum += Double(sample) * Double(sample) }
            loud[index] = (sum / Double(frame)).squareRoot() > speechRMSFloor
        }

        // Speech is a RUN of loud frames, not a loud frame.
        //
        // Measured 2026-08-17 (build 2.4.66): a clip that was near-silent for
        // its first 5.5 s and loud thereafter was not trimmed at all, because
        // first-loud-to-last-loud is defeated by one 20 ms transient near the
        // start — a chair, a tap on the phone, a door. A single frame kept
        // twelve seconds of silence and the clip went into the corpus at its
        // full length. Requiring `minRun` consecutive frames costs nothing and
        // makes the bound depend on the speech rather than on the loudest
        // accident in the room.
        let minRun = 5                                   // 100 ms
        /// The frame where a run of `minRun` loud frames begins, in the
        /// direction of travel. Scanning forwards that is the run's first
        /// frame; scanning backwards it is the run's LAST frame going
        /// forwards, so the offset is added rather than subtracted — getting
        /// that sign wrong silently shortened every clip by 160 ms at the
        /// tail, which the fixture caught only because it asserts a duration.
        func runEdge(_ range: some Sequence<Int>, forwards: Bool) -> Int? {
            var count = 0
            for index in range {
                count = loud[index] ? count + 1 : 0
                if count == minRun {
                    return forwards ? index - (minRun - 1) : index + (minRun - 1)
                }
            }
            return nil
        }
        guard let first = runEdge(0..<frameCount, forwards: true),
              let last = runEdge((0..<frameCount).reversed(), forwards: false)
        else { return nil }

        // BYTE offsets, not sample indices — the caller slices `Data`. Returning
        // sample indices silently halved every clip, keeping the first half of
        // the speech and calling it the whole utterance (caught by L1.104c/d,
        // which assert the payload against what was appended).
        // Clamp the end to the DATA, not to the last whole frame: a buffer
        // whose length is not a multiple of 20 ms would otherwise lose its
        // final partial frame, quietly clipping the tail of every clip that
        // runs to the end of the turn.
        let margin = Int(marginSeconds * 50)
        let start = max(0, first - margin) * bytesPerFrame
        let end = min(pcm.count, (last + 1 + margin) * bytesPerFrame)
        return start..<end
    }

    /// A 44-byte canonical PCM WAV header followed by the samples. Written
    /// here rather than via AVAudioFile because the bytes are already in the
    /// exact target format — going back through an AVAudioBuffer to get them
    /// written would add a conversion whose only possible effect is to change
    /// the thing being measured.
    static func wav(from pcm: Data) -> Data {
        let channels = 1
        let bitsPerSample = bytesPerSample * 8
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var out = Data(capacity: 44 + pcm.count)
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { out.append(contentsOf: $0) } }

        out.append(contentsOf: Array("RIFF".utf8))
        u32(36 + pcm.count)
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        u32(16)              // PCM fmt chunk size
        u16(1)               // format: PCM, uncompressed
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        out.append(contentsOf: Array("data".utf8))
        u32(pcm.count)
        out.append(pcm)
        return out
    }
}
