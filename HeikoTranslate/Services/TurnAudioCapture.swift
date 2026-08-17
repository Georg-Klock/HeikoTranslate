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

    init(directory: URL? = nil, enabled: Bool = TurnAudioCapture.isEnabled) {
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

    /// Called from the audio render thread with the SAME 16 kHz mono Int16
    /// bytes the session sends upstream. Must stay cheap: a lock and an
    /// append, no formatting, no file I/O, no allocation beyond the buffer's
    /// own growth.
    func append(_ chunk: Data) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard home != nil else { return }
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

        let name = String(format: "turn-%04d-%@-%@.wav", index, home.rawValue, partner.rawValue)
        let url = directory.appendingPathComponent(name)
        do {
            try Self.wav(from: audio).write(to: url, options: .atomic)
        } catch {
            DiagnosticLog.shared.log("capture", "turn \(index) NOT written: \(error.localizedDescription)")
            return
        }

        let seconds = Double(audio.count / Self.bytesPerSample) / Double(Self.sampleRate)
        append(manifest: [
            "file": name,
            "home": home.rawValue,
            "partner": partner.rawValue,
            "decision": decision,
            "seconds": String(format: "%.2f", seconds),
            "truncated": wasTruncated ? "true" : "false",
            "recorded": Self.timestamp.string(from: Date()),
        ])
        DiagnosticLog.shared.log("capture", "turn \(index) → \(name) (\(String(format: "%.2f", seconds))s, decision \(decision))")
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
