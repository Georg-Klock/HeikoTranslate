import AVFoundation
import Network

/// Runs exactly TWO concurrent Gemini Live Translate sessions — one targeting
/// each side of the selected language pair, HOME and PARTNER — because the API
/// supports only one fixed target language per session.
///
/// Direction comes from which session actually translated the utterance: a
/// session translates substantially only when the input was not already its
/// own target. Detected language codes are a veto and a straggler filter, not
/// the decision — they lie often enough that trusting them directly swallowed
/// whole turns. Those decisions live in `TurnLogic` (pure, testable); this
/// class owns the audio hardware, the sessions, and the timers that decide
/// when a turn ends.
///
/// The pair is explicit and user-chosen (settings). `Lang.allCases` is the
/// settings menu, never the session set — conflating them once had the startup
/// watchdog spin up all six languages.
///
/// The model is a continuous interpreter (each session streams 24kHz audio
/// nonstop), so output PCM is held until `TurnLogic.commit` makes the
/// translator irrevocable. The app then plays only that committed session's
/// audio; the hardware voice-processing unit's echo cancellation (see
/// `startAudioIO`) stops the app from re-hearing its own output. Each
/// completed turn is reported via `onUtterance`.
@MainActor
final class GeminiLiveTranslationService: ObservableObject {
    @Published private(set) var isRunning = false

    /// Target languages. Raw value is the BCP-47 code sent to the API.
    typealias Lang = TurnLogic.Lang

    /// Coarse state for the UI status line and pulse.
    enum Activity { case connecting, idle, understanding, translating }
    private var currentActivity: Activity = .idle
    private var anySessionReady = false
    private var readySessions: Set<Lang> = []

    /// Silence watchdog: finalizes a turn even when no translated audio ever
    /// played, so a stale `translator` can't persist into the next utterance.
    private var inputIdleTimer: Timer?
    private let inputIdleTimeout: TimeInterval = 1.6

    /// A finalize that would DROP the turn because the needed translation
    /// hasn't arrived gets deferred instead of giving up — SPEC §5.1: "keep
    /// showing live text and wait." Device log 2026-07-29 10:53: English
    /// spoken, en echo present, de translation still in flight on a starved
    /// uplink — the old code rejected at 1.6s and wiped the turn, which
    /// swallowed the bubble AND the audio.
    /// Shared with the L3 harness — see `FinalizePolicy`.
    private var finalizePolicy = FinalizePolicy()
    private var deferralTimer: Timer?

    private var sessions: [Lang: GeminiLiveSession] = [:]

    /// Which session instance is current, per language. Every asynchronous
    /// continuation — a session's event callback, a reconnect timer —
    /// captures the token current when it was created and checks it before
    /// acting, so anything from a stopped run or a replaced instance is
    /// dropped at the door. The rule itself lives in `SessionRegistry` so it
    /// is L1-testable without audio or network. GitHub #20.
    private var registry = SessionRegistry()

    /// The only way sessions are constructed: mints the token and wires the
    /// event callback behind a token check. `start()` and `reconnect()` both
    /// use it, so there is no path that creates an unguarded session.
    private func makeSession(_ lang: Lang, apiKey: String) -> GeminiLiveSession {
        let token = registry.register(lang)
        return GeminiLiveSession(targetLanguageCode: lang.rawValue, apiKey: apiKey) { [weak self] event in
            Task { @MainActor in
                guard let self, self.registry.isCurrent(token, for: lang) else { return }
                self.handle(lang, event)
            }
        }
    }
    /// The two languages this run is supposed to be running, and the ONLY
    /// ones any code here may connect. `Lang.allCases` is the settings menu
    /// (six languages), never the session set — conflating them made the
    /// startup watchdog spin up all six, which the device log caught as a
    /// turn with output from five sessions on a two-language pair.
    private var activePair: Set<Lang> = []
    private var dead: Set<Lang> = []
    /// Per-session reconnect attempts after an error, so a transient network
    /// blip doesn't kill a language for the rest of the conversation (R7) —
    /// but a persistent failure (bad key, no network) stops retrying and
    /// stays surfaced instead of looping.
    private var retryAttempts: [Lang: Int] = [:]

    /// How many abrupt post-handshake drops this language has seen since it
    /// last connected cleanly. Indexes `dropReconnectDelays`. GitHub #3.
    private var dropBackoff: [Lang: Int] = [:]
    /// Escalating cooldown after an abrupt drop; the last value repeats
    /// forever rather than the retries stopping.
    private let dropReconnectDelays: [TimeInterval] = [1.0, 2.0, 5.0, 10.0]
    private let sessionRetryDelays: [TimeInterval] = [2.0, 5.0, 10.0]

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    /// Mic converter state, deliberately NOT a stored property of this
    /// `@MainActor` type. See `MicConverterBox`. GitHub #2.
    private let micConverters = MicConverterBox()
    private var tapInstalled = false

    /// Startup health, for the watchdog below.
    private var micBufferCount = 0
    private var peakMicRMS: Double = 0
    /// Mic energy floor above which the turn has plausibly heard speech.
    /// Measured on device 2026-07-29: inter-turn silence peaks 0–75, real
    /// speech 991–5263 — straggler codes during that silence once settled
    /// a turn's language before its speech even began.
    private static let micSpeechRMSFloor: Double = 400
    /// Codes may only vote once this turn has actually heard something.
    private var speechHeardThisTurn = false
    private var audioRebuilds = 0
    private var startupWatchdog: Timer?
    private var micWatchdog: Timer?
    private var lastMicHeartbeat = Date.distantPast
    private var secondPeakRMS: Double = 0

    /// When the server last sent ANYTHING content-bearing. Healthy sessions
    /// stream usage frames about once a second, so this staying stale while
    /// we stream speech means the uplink is starved or the server is gone —
    /// the "I spoke for nine seconds and nothing happened" failure, which
    /// used to be completely silent (R8 violation, device log 2026-07-29).
    private var lastServerEventAt = Date.distantPast
    private var reportedServerSilence = false
    private let serverSilenceLimit: TimeInterval = 6.0

    /// Called as the user's speech is transcribed, word by word, in the
    /// language being spoken — for a live "what I'm hearing" display.
    private var onPartialInput: ((String) -> Void)?
    /// Called once per finished spoken turn: both lines of the turn and whether
    /// the HOME language was spoken.
    private var onUtterance: ((_ original: String, _ translation: String, _ wasHome: Bool) -> Void)?
    private var onActivity: ((Activity) -> Void)?
    private var onError: ((String) -> Void)?
    /// Live microphone loudness, 0...1, ~15× a second. Drives the flag so the
    /// app visibly reacts the instant someone speaks — long before the API
    /// has decided anything.
    private var onInputLevel: ((Double) -> Void)?
    /// Which way this turn is going, once it's actually known: `true` German
    /// was spoken, `false` a foreign language, `nil` still undecided. Driven
    /// by which session translated — the reliable signal — so the live line
    /// can wait rather than guess a side and jump.
    private var onDirection: ((Bool?) -> Void)?
    /// Called when the server starts answering again after a reported
    /// silence, so the UI can clear the connection warning.
    private var onServerRecovered: (() -> Void)?
    /// Fired when every session in the pair is dead with no retries left, so
    /// the UI can say "stopped" instead of spinning forever. GitHub #4.
    private var onSessionsExhausted: (() -> Void)?

    /// Effective connection quality, measured end to end. iOS exposes no
    /// signal-strength API to apps (bars are private); what we CAN measure
    /// is better anyway: whether Google's answers are actually arriving.
    /// Healthy sessions stream usage frames ~1/s, so the gap since the last
    /// server event is a live throughput probe of the real path.
    enum ConnectionQuality: Equatable { case good, degraded, silent, offline }
    private var onConnectionQuality: ((ConnectionQuality) -> Void)?
    private var reportedQuality: ConnectionQuality = .good
    private var goodBeats = 0
    private let pathMonitor = NWPathMonitor()
    private var pathIsOnline = true
    private var lastReportedDirection: Bool??

    /// Per-utterance state. The decisions themselves (which language was
    /// spoken, which session translates, whose transcript to trust, when a
    /// turn may commit) live in `TurnLogic` so the L1 tests exercise the
    /// exact code the app runs.
    private var turn = TurnLogic()
    /// Each session's rendering of what was heard. Kept per-session because
    /// the session whose target equals the spoken language can transcribe
    /// garbage — `TurnLogic.bestTranscript` picks the trustworthy one.
    private var inputs: [Lang: String] = [:]
    private var outputs: [Lang: String] = [:]

    /// A stable, single-line record of what every active session heard.
    ///
    /// This is deliberately diagnostic-only: it must not influence which
    /// transcript TurnLogic commits. Quoting and escaping preserve an empty
    /// or multi-line raw transcript as one log entry, so the next diagnostic
    /// line cannot be mistaken for part of what Gemini heard. Kept internal so
    /// L1 can pin the exact format emitted by this real service.
    static func inputTranscriptDiagnosticLine(inputs: [Lang: String],
                                              sessions: Set<Lang>) -> String {
        let heard = sessions.sorted { $0.rawValue < $1.rawValue }.map { lang in
            "heard[\(lang.rawValue)] \"\(escapedDiagnosticTranscript(inputs[lang] ?? ""))\""
        }.joined(separator: "   ")
        return "  \(heard)"
    }

    private static func escapedDiagnosticTranscript(_ transcript: String) -> String {
        transcript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Translated audio, held until a turn has committed. The model is a
    /// *simultaneous* interpreter, but a provisional direction can still be
    /// invalidated by later codes or transcripts. Playing early is
    /// irreversible and can speak the other person's words as Heiko's.
    private var pendingOutput: [Lang: [Data]] = [:]
    private var directionRecheckTimer: Timer?
    /// After a commit, the translator's late audio chunks (text can arrive
    /// seconds before the audio on a starved uplink) play straight through
    /// for a short window instead of being misfiled into the next turn.
    private var lingeringTranslator: Lang?
    private var lingerUntil = Date.distantPast
    private let maxPendingOutputChunks = 1500   // ≈40s of 24kHz audio
    /// When input transcription last progressed — the output-tail timer must
    /// not finalize a turn whose speaker is still talking (R5).
    private var lastInputAt = Date.distantPast
    /// True once the speaker has been quiet long enough that answering is no
    /// longer an interruption. Gates all playback.
    private var speakerHasStopped = false
    private var speechEndTimer: Timer?
    // The transcript-idle threshold that arms release lives in
    // `SpeechEndPolicy`. The policy also owns the microphone veto: transcripts
    // may lag the speaker, while the microphone signal does not.
    /// Most recent mic buffer above `micSpeechRMSFloor`.
    private var lastLoudMicAt: Date?

    /// When a session's translation text last grew. A turn must not finalize
    /// while the translation is still arriving: device evidence showed
    /// "…wir haben im Moment keine" committed as one bubble and the rest of
    /// the same sentence, "Gurken mehr.", landing in the NEXT one against
    /// unrelated English (R1/R5).
    private var lastOutputAt = Date.distantPast
    private let outputQuietPause: TimeInterval = 0.9

    /// True when both sides have gone quiet long enough to end the turn.
    private var turnMayFinalize: Bool {
        let now = Date()
        return now.timeIntervalSince(lastInputAt) >= outputTailTimeout
            && now.timeIntervalSince(lastOutputAt) >= outputQuietPause
    }

    /// Minimum input quiet time before a turn may commit. Kept separate from
    /// `outputQuietPause`: both the speaker and translation stream must be
    /// quiet before held PCM is released.
    private var isPlayingOutput = false
    private var outputActivityTimer: Timer?
    private let outputTailTimeout: TimeInterval = 0.45

    private let speechRMSThreshold: Double = 220
    private var isSendingAudio = false

    /// Mic audio captured before the sockets finished connecting. Flushed on
    /// connect so a sentence spoken immediately after launch isn't lost (which
    /// is what forced a mute/unmute to get the first translation).
    private var pendingAudio: [Data] = []
    private let maxPendingChunks = 250

    func requestPermissions() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
    }

    func start(
        home: Lang,
        partner: Lang,
        onPartialInput: @escaping (String) -> Void,
        onUtterance: @escaping (_ original: String, _ translation: String, _ wasHome: Bool) -> Void,
        onActivity: @escaping (Activity) -> Void,
        onError: @escaping (String) -> Void,
        onInputLevel: ((Double) -> Void)? = nil,
        onDirection: ((Bool?) -> Void)? = nil,
        onServerRecovered: (() -> Void)? = nil,
        onSessionsExhausted: (() -> Void)? = nil,
        onConnectionQuality: ((ConnectionQuality) -> Void)? = nil
    ) throws {
        // Second line of defence for GitHub #1. Whatever the caller does, a
        // start() that lands while we are already running must not install a
        // second tap on bus 0 (AVAudioEngine traps) and must not overwrite
        // `sessions` while the previous WebSockets are still open — those
        // would keep streaming and billing with no reference left to close
        // them. Tearing down first makes a duplicate start merely redundant.
        if isRunning {
            diag("app", "start() while already running — tearing the previous run down first")
            stopSession()
        }
        self.onServerRecovered = onServerRecovered
        self.onSessionsExhausted = onSessionsExhausted
        self.onConnectionQuality = onConnectionQuality
        startPathMonitorIfNeeded()
        self.onInputLevel = onInputLevel
        self.onDirection = onDirection
        lastReportedDirection = nil
        self.onPartialInput = onPartialInput
        self.onUtterance = onUtterance
        self.onActivity = onActivity
        self.onError = onError
        anySessionReady = false
        setActivity(.connecting)
        turn = TurnLogic(home: home, partner: partner)
        resetForNextUtterance()
        dead = []
        retryAttempts = [:]
        dropBackoff = [:]
        // A fresh start is a fresh verdict: without this, a warning frozen
        // at mute time (nothing publishes while muted) sits over
        // "Verbinde…" for seconds after unmuting on a healthy network.
        reportedQuality = .good
        goodBeats = 0
        isPlayingOutput = false

        // Audio first: if the engine can't start, we throw before any
        // session connects, so a failure leaks no live, billed WebSockets.
        // Mic stays closed until the sessions report setupComplete.
        isSendingAudio = false
        readySessions = []
        pendingAudio = []
        try startAudioIO()

        // One session per side of the selected pair, both fed the same mic
        // audio. The pair is explicit (settings), so exactly two sessions.
        activePair = [home, partner]
        let apiKey = AppConfig.geminiAPIKey
        for lang in [home, partner] {
            let session = makeSession(lang, apiKey: apiKey)
            sessions[lang] = session
            session.connect()
        }
        lastServerEventAt = Date()
        reportedServerSilence = false
        isRunning = true
        diag("app", "listening started, pair \(home.rawValue)↔\(partner.rawValue)")
        startWatchdogs()
    }

    /// Send everything captured while connecting, then resume live streaming.
    private func flushPendingAudio() {
        guard !pendingAudio.isEmpty else { return }
        let queued = pendingAudio
        pendingAudio = []
        for chunk in queued {
            for (lang, session) in sessions where !dead.contains(lang) {
                session.sendAudio(chunk)
            }
        }
    }

    private func resetForNextUtterance() {
        turn.endTurn()
        inputs = [:]
        outputs = [:]
        pendingOutput = [:]
        speechHeardThisTurn = false
        stopDirectionRecheck()
        lastOutputAt = .distantPast
        speakerHasStopped = false
        speechEndTimer?.invalidate()
        speechEndTimer = nil
    }

    private func setActivity(_ a: Activity) {
        guard a != currentActivity else { return }
        currentActivity = a
        onActivity?(a)
    }

    /// Mute button — tears everything down.
    func stopSession() {
        diag("app", "listening stopped; mic buffers this run=\(micBufferCount) peakRMS=\(Int(peakMicRMS))")
        DiagnosticLog.shared.flush()
        isSendingAudio = false
        anySessionReady = false
        readySessions = []
        inputIdleTimer?.invalidate()
        inputIdleTimer = nil
        deferralTimer?.invalidate()
        deferralTimer = nil
        finalizePolicy.reset()
        startupWatchdog?.invalidate()
        startupWatchdog = nil
        micWatchdog?.invalidate()
        micWatchdog = nil
        speechEndTimer?.invalidate()
        speechEndTimer = nil
        speakerHasStopped = false
        lastLoudMicAt = nil
        pendingOutput = [:]
        stopDirectionRecheck()
        lingeringTranslator = nil
        isPlayingOutput = false
        outputActivityTimer?.invalidate()
        outputActivityTimer = nil
        stopAudioIO()
        for s in sessions.values { s.close() }
        sessions = [:]
        // Clearing the tokens is what actually seals this run: every session
        // callback and reconnect timer created during it captured one of
        // these values and checks it before acting. GitHub #20.
        registry.clear()
        activePair = []
        setActivity(.idle)
        isRunning = false
    }

    // MARK: - Audio I/O

    private func startAudioIO() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        // Engage the hardware voice-processing I/O unit — real acoustic echo
        // cancellation. `.voiceChat` mode alone does NOT turn this on for an
        // AVAudioEngine; with it we can run full-duplex (listen while
        // speaking) like the native voice agents, instead of muting the mic
        // during playback.
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            diag("audio", "AEC could NOT be enabled: \(error)")
        }

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)

        // Start the engine BEFORE reading the input format or installing the
        // tap. Enabling voice processing re-negotiates the input hardware, and
        // on a cold launch the node reports a placeholder format until the
        // engine is actually running — a tap installed against that format
        // receives nothing, which is the "had to mute and unmute" symptom.
        audioEngine.prepare()
        try audioEngine.start()

        let inputFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "GeminiLiveTranslationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter (input format \(inputFormat))"])
        }
        micConverters.set(converter, inputFormat: inputFormat)
        diag("audio", "converter built for \(inputFormat)")

        // Passing `format: nil` makes the tap adopt the node's ACTUAL format at
        // install time. At cold launch the session/route is still settling, so
        // a format captured a moment earlier can be wrong — and every buffer
        // then fails conversion, which is exactly the "spoke at launch, nothing
        // happened until I muted and unmuted" bug (R4). The converter is
        // rebuilt below whenever a buffer's real format doesn't match it.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            // This block runs on the real-time audio render thread, NOT the
            // main actor — `installTap` stores it and AVAudioEngine calls it
            // directly, a path that never goes through Swift's actor
            // executor. So it must not touch this type's stored properties.
            // The box owns the converter behind a lock, and does the
            // compare-and-rebuild as one atomic step. GitHub #2.
            guard let resolved = self.micConverters.converter(for: buffer.format, target: targetFormat),
                  let pcmData = Self.convert(buffer: buffer, using: resolved.converter, targetFormat: targetFormat)
            else { return }
            // Formatting the description is an allocation, so only pay for it
            // on the rare rebuild — and log it from the main-actor hop below
            // rather than from the render thread.
            let rebuiltFormat = resolved.didRebuild ? "\(buffer.format)" : nil

            // Loudness for the UI, before any network round trip.
            let rms = Self.rms(of: pcmData)
            let level = min(1.0, rms / 4000.0)
            Task { @MainActor in
                guard self.isRunning else { return }
                if let rebuiltFormat {
                    diag("audio", "format changed to \(rebuiltFormat) — converter rebuilt")
                }
                self.micBufferCount += 1
                self.peakMicRMS = max(self.peakMicRMS, rms)
                self.secondPeakRMS = max(self.secondPeakRMS, rms)
                if rms > Self.micSpeechRMSFloor {
                    self.speechHeardThisTurn = true
                    self.lastLoudMicAt = Date()
                }
                // One line a second, so "the room was quiet" is always
                // distinguishable from "the microphone was dead".
                if Date().timeIntervalSince(self.lastMicHeartbeat) >= 1.0 {
                    diag("audio", "mic alive: \(self.micBufferCount) buffers, peak this second \(Int(self.secondPeakRMS))")
                    self.lastMicHeartbeat = Date()
                    self.secondPeakRMS = 0
                    self.checkServerSilence()
                }
                self.onInputLevel?(level)
            }

            Task { @MainActor in
                // Full-duplex: keep forwarding the mic even while a translation
                // plays — the AEC cancels our own output, so we don't loop.
                guard self.isRunning else { return }
                guard self.isSendingAudio else {
                    // Not connected yet — hold the audio, don't drop it.
                    if self.pendingAudio.count < self.maxPendingChunks {
                        self.pendingAudio.append(pcmData)
                    }
                    return
                }
                for (lang, session) in self.sessions where !self.dead.contains(lang) {
                    session.sendAudio(pcmData)
                }
            }
        }
        tapInstalled = true
        playerNode.play()
        diag("audio", "engine started, input format \(inputFormat)")
    }

    // MARK: - Startup watchdogs
    //
    // Two independent things have to come up for the app to hear anything:
    // the audio engine must deliver microphone buffers, and all three
    // sessions must finish their handshake. On device, one of them
    // intermittently doesn't — and the app just sat there looking alive,
    // which is why a manual mute/unmute became the ritual. Each has a
    // watchdog that logs precisely what stalled and then performs the same
    // recovery by itself, once.

    private func startWatchdogs() {
        micBufferCount = 0
        peakMicRMS = 0
        audioRebuilds = 0
        startupWatchdog?.invalidate()
        // The tap should deliver its first buffer within ~20ms (1024 frames
        // at 48kHz). Measured on device: when the first start comes up dead
        // it stays dead, so half a second is plenty to tell the two apart —
        // and it shrinks the window where speech is lost from 3.4s to ~0.6s.
        micWatchdog?.invalidate()
        micWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkMicAlive() }
        }
        startupWatchdog = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkStartupHealth() }
        }
    }

    /// Device evidence (2026-07-27): on the first start of a process the
    /// input tap can deliver *zero* buffers while all three sessions connect
    /// perfectly — enabling voice processing reconfigures the input hardware
    /// out from under the freshly installed tap. Rebuilding the audio path
    /// fixes it instantly, which is exactly what the manual mute/unmute was
    /// doing by hand.
    private func checkMicAlive() {
        guard isRunning, micBufferCount == 0, audioRebuilds < 2 else { return }
        audioRebuilds += 1
        diag("watchdog", "@0.5s NO mic buffers — rebuilding audio I/O (attempt \(audioRebuilds))")
        stopAudioIO()
        do { try startAudioIO() } catch {
            diag("watchdog", "audio rebuild FAILED: \(error.localizedDescription)")
            onError?("audio restart failed: \(error.localizedDescription)")
        }
        micWatchdog?.invalidate()
        micWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkMicAlive() }
        }
    }

    private func checkStartupHealth() {
        guard isRunning else { return }
        let missing = activePair.subtracting(readySessions)
        diag("watchdog", "@3s micBuffers=\(micBufferCount) peakRMS=\(Int(peakMicRMS)) ready=\(readySessions.map(\.rawValue).sorted()) missing=\(missing.map(\.rawValue).sorted()) sendingAudio=\(isSendingAudio)")

        // Backstop for the fast check above.
        if micBufferCount == 0 { checkMicAlive() }

        // A session is still not through its handshake, with no error. Don't
        // hold the whole app hostage to it: reconnect the laggard and open
        // the mic with whoever is ready.
        if !missing.isEmpty {
            diag("watchdog", "reconnecting stalled session(s) \(missing.map(\.rawValue).sorted())")
            for lang in missing {
                sessions[lang]?.close()
                reconnect(lang)
            }
            if !readySessions.isEmpty, !anySessionReady {
                diag("watchdog", "opening mic with PARTIAL readiness \(readySessions.map(\.rawValue).sorted())")
                anySessionReady = true
                isSendingAudio = true
                setActivity(.idle)
                flushPendingAudio()
            }
        }
    }

    private func stopAudioIO() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        playerNode.stop()
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, targetFormat: AVAudioFormat) -> Data? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var delivered = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, let channelData = outBuffer.int16ChannelData else { return nil }
        let frameLength = Int(outBuffer.frameLength)
        return Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)
    }

    // MARK: - Session events

    private func handle(_ lang: Lang, _ event: GeminiLiveSession.Event) {
        // A session outside the current pair is a leftover from a pair
        // change that hasn't finished closing. Its output must not reach the
        // turn logic — that is how a de↔en turn ended up holding Korean and
        // Chinese translations. The old `activePair.isEmpty ||` clause is
        // gone: stopSession() sets activePair = [], so the clause waved
        // through every late event in exactly the post-stop window this guard
        // exists for. The token check in makeSession's callback already drops
        // those; this guard now states only its documented intent. GitHub #20.
        guard activePair.contains(lang) else {
            if case .usage(let usage) = event { CostTracker.shared.record(usage: usage) }
            return
        }
        switch event {
        case .opened:
            // Handshake only — the session can't process audio until the
            // server acknowledges setup. Gating readiness on .opened (an old
            // bug) opened the mic early and silently lost the first
            // utterance into sessions that weren't listening yet.
            break
        case .setupComplete:
            lastServerEventAt = Date()
            readySessions.insert(lang)
            retryAttempts[lang] = 0
            // A clean handshake means the network recovered — start the drop
            // cooldown over, so one bad tunnel doesn't leave this language on
            // a 10s delay for the rest of the trip. GitHub #3.
            dropBackoff[lang] = 0
            openMicIfReady()
        case .audioChunk(let data):
            lastServerEventAt = Date()
            handleAudioChunk(data, from: lang)
        case .inputLanguage(let code):
            noteInputLanguage(code, from: lang)
            // Codes are crossed-direction evidence now, so a
            // code event must re-derive like an output event does — a late
            // foreign settle has to clear a provisional homeSpoken BEFORE
            // the release flushes audio for it, and late crossed votes have
            // to be able to correct the translator (#84 review).
            turn.noteOutputs(outputs, inputs: inputs)
            reportDirectionIfChanged()
        case .outputLanguage:
            break
        case .inputTranscript(let text):
            lastServerEventAt = Date()
            noteServerRecovered()
            inputs[lang, default: ""] += text
            noteInputActivity()
            onPartialInput?(turn.bestTranscript(from: inputs))
            resetInputIdleTimer()
        case .outputTranscript(let text):
            outputs[lang, default: ""] += text
            lastOutputAt = Date()
            // A session translating is the authoritative direction signal —
            // the German session really translates only non-German input.
            turn.noteOutputs(outputs, inputs: inputs)
            reportDirectionIfChanged()
        case .turnComplete:
            break
        case .usage(let usage):
            lastServerEventAt = Date()
            noteServerRecovered()
            CostTracker.shared.record(usage: usage)
        case .raw(let text):
            diag("session", "[\(lang.rawValue)] raw: \(text.prefix(300))")
        case .closed(let expected):
            if expected {
                // A goAway: the server announced the duration limit and we
                // closed on cue. Nothing is wrong, so reconnect immediately —
                // any delay here is dead air mid-conversation.
                dropBackoff[lang] = 0
                reconnect(lang)
            } else {
                // An abrupt post-handshake drop. Previously this took the same
                // immediate path, so a connection that kept completing its
                // handshake and then dying — a cell handoff, a train, a lift —
                // reconnected with no cooldown for as long as the flakiness
                // lasted. Back off instead. GitHub #3.
                scheduleDropReconnect(lang)
            }
        case .error(let message):
            diag("session", "[\(lang.rawValue)] ERROR: \(message)")
            dead.insert(lang)
            readySessions.remove(lang)
            onError?("\(lang): \(message)")
            scheduleSessionRetry(lang)
            // One failed session must not hold the mic shut for the two
            // that work — open (degraded) rather than spin forever (R8).
            openMicIfReady()
        case .debug(let message):
            diag("session", "[\(lang.rawValue)] \(message)")
        }
    }

    /// Open the mic once every session that is still alive has completed
    /// setup. Dead sessions don't count toward the requirement — a single
    /// failed handshake out of three must not leave the app connecting
    /// forever while speech silently overflows the pending buffer.
    private func openMicIfReady() {
        let required = sessions.count - dead.count
        guard !anySessionReady, required > 0,
              readySessions.subtracting(dead).count >= required else { return }
        anySessionReady = true
        isSendingAudio = true
        diag("audio", "mic OPEN (all ready); flushing \(pendingAudio.count) buffered chunks")
        setActivity(.idle)
        flushPendingAudio()
    }

    /// After a session error, try to bring that language back with backoff
    /// (R7). Attempts reset on a successful setup, so only persistently
    /// failing sessions stay dead — and their error stays on screen.
    /// Every session in the pair is dead and nothing is left to retry, so stop
    /// claiming to be connecting.
    ///
    /// Without this the app sat with the spinner up forever while showing a
    /// connection error at the same time — two contradictory signals, and no
    /// hint that the fix was to tap the (still "connecting") button. The
    /// realistic trigger is no network at launch, which for this app means the
    /// moment Heiko lands. SPEC R8: never sit in a state where speaking does
    /// nothing; recover, or say so. GitHub #4.
    private func failIfPairIsDead() {
        guard isRunning, !activePair.isEmpty, activePair.isSubset(of: dead) else { return }
        guard activePair.allSatisfy({ retryAttempts[$0, default: 0] >= sessionRetryDelays.count }) else { return }
        diag("session", "pair is dead and retries are exhausted — stopping rather than showing 'Verbinde…' forever")
        let notify = onSessionsExhausted
        stopSession()
        notify?()
    }

    private func scheduleSessionRetry(_ lang: Lang) {
        let attempts = retryAttempts[lang, default: 0]
        guard attempts < sessionRetryDelays.count else {
            failIfPairIsDead()
            return
        }
        retryAttempts[lang] = attempts + 1
        let token = registry.token(for: lang)
        Timer.scheduledTimer(withTimeInterval: sessionRetryDelays[attempts], repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, self.dead.contains(lang),
                      self.registry.isCurrent(token, for: lang) else { return }
                self.dead.remove(lang)
                self.reconnect(lang)
            }
        }
    }

    /// Reconnect after an abrupt post-handshake drop, with an escalating
    /// cooldown.
    ///
    /// Deliberately NOT capped the way `scheduleSessionRetry` is. That path
    /// gives up after three attempts because a pre-handshake failure usually
    /// means something permanently wrong (bad key, no route). A socket that
    /// completes its handshake and then drops is the opposite: the network is
    /// there and intermittent. The person holding this phone is abroad,
    /// relying on it to order lunch, and a translator that permanently stopped
    /// trying after 17 seconds in a lift would be useless. So the delay
    /// escalates and then holds — slow enough never to storm, persistent
    /// enough to recover whenever the network does. GitHub #3.
    private func scheduleDropReconnect(_ lang: Lang) {
        let step = dropBackoff[lang, default: 0]
        let delay = dropReconnectDelays[min(step, dropReconnectDelays.count - 1)]
        dropBackoff[lang] = step + 1
        diag("session", "[\(lang.rawValue)] abrupt drop — reconnecting in \(delay)s (attempt \(step + 1))")
        // The token pins this timer to the session it was armed FOR. Guarding
        // on isRunning alone was a real bug (GitHub #20): mute during the
        // delay, then unmute, and isRunning is true again — the stale timer
        // fired into the fresh run and REPLACED a healthy session, because
        // start() had also reset `dead`, so every guard passed. The retry path
        // above was safe only by accident (its dead-guard fails after a
        // restart); this one had no such accident.
        let token = registry.token(for: lang)
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning,
                      self.registry.isCurrent(token, for: lang) else { return }
                self.reconnect(lang)
            }
        }
    }

    private func reconnect(_ lang: Lang) {
        guard isRunning, !dead.contains(lang), activePair.contains(lang) else { return }
        // Close the instance being replaced. On the .error path the old
        // transport is not necessarily dead (an error frame is not a closed
        // socket), and close() is also what invalidates its URLSession —
        // without this, the orphan stayed retained forever with whatever
        // socket state it still had. Same one-line discipline the #1 fix
        // added to start(). GitHub #19.
        sessions[lang]?.close()
        let session = makeSession(lang, apiKey: AppConfig.geminiAPIKey)
        sessions[lang] = session
        session.connect()
        diag("session", "[\(lang.rawValue)] reconnected")
    }

    private func noteInputLanguage(_ code: String, from session: Lang) {
        // Codes that arrive while the mic has heard nothing this turn are
        // stragglers from the previous turn by construction — one device
        // run showed them settling the NEXT turn's language during 8s of
        // silence, vetoing the German that followed (2026-07-29 15:03).
        guard speechHeardThisTurn else {
            diag("turn", "language code \(code) [\(session.rawValue)] (ignored: no speech this turn)")
            return
        }
        // The reporting session is in the log line because it is now part of
        // the decision (the per-session crossed evidence) — a device log that
        // shows only the code cannot distinguish the crossed mis-hearing
        // pattern from an ordinary settle (#83, and #81's spirit).
        diag("turn", "language code \(code) [\(session.rawValue)]")
        if turn.noteInputLanguage(code, from: session) != nil {
            setActivity(.understanding)
        }
    }

    /// Publish the turn's direction the moment it's known — and only then.
    private func reportDirectionIfChanged() {
        let current: Bool? = turn.direction.map { $0 == .homeSpoken }
        guard lastReportedDirection == nil || lastReportedDirection! != current else { return }
        lastReportedDirection = current
        diag("turn", "direction → \(current.map { $0 ? "home" : "foreign" } ?? "undecided")")
        onDirection?(current)
    }

    private func handleAudioChunk(_ data: Data, from lang: Lang) {
        let rms = Self.rms(of: data)
        // Audio IS output. The finalize gate (output quiet ≥0.9s) used to
        // watch only transcript events, so a turn could finalize while its
        // translation audio was still streaming in — and the reset dropped
        // the rest of the sentence.
        if rms > speechRMSThreshold { lastOutputAt = Date() }

        // Home-session audio corroborates the transcript signal, but only
        // once the transcript itself is substantial — a false start must not
        // flip the turn's direction. (`turn.home`, not `.de` — the hardcode
        // predated configurable pairs and silently disabled this
        // corroboration for any non-German home; latent until now because
        // Heiko's home is German, same class as #38.)
        if lang == turn.home, rms > speechRMSThreshold {
            turn.noteOutputs(outputs, inputs: inputs)
            reportDirectionIfChanged()
        }

        // The straggling tail of the JUST-committed turn's translation:
        // play it through, and drop the other session's stale audio —
        // buffering either would misfile last turn's sound into this one.
        if let lingering = lingeringTranslator {
            if Date() >= lingerUntil || Date().timeIntervalSince(lastInputAt) < 1.0 {
                lingeringTranslator = nil   // window over, or new speech owns the buffers again
            } else if lang == lingering {
                if rms > speechRMSThreshold { play(pcm24kChunk: data) }
                return
            } else {
                return
            }
        }

        // Every current-turn chunk stays recoverable until commit. A
        // provisional translator is not permission to speak: late language
        // evidence can still clear or change it, and PCM handed to `play()`
        // cannot be recalled. `finalizeTurn` releases only
        // `turn.committedTranslator`.
        if pendingOutput[lang, default: []].count < maxPendingOutputChunks {
            pendingOutput[lang, default: []].append(data)
        }
    }

    /// Release queued PCM only after `TurnLogic.commit` has made the side
    /// immutable. This is intentionally the sole current-turn path to
    /// `play()`: the linger path above belongs to an already committed turn.
    private func releaseCommittedOutput(for translator: Lang) {
        guard turn.committedTranslator == translator else { return }
        let queued = pendingOutput[translator] ?? []
        pendingOutput = [:]
        guard !queued.isEmpty else { return }
        diag("turn", "releasing \(queued.count) held translation chunks at commit")
        for chunk in queued where Self.rms(of: chunk) > speechRMSThreshold {
            play(pcm24kChunk: chunk)
        }
    }

    /// Called whenever the person's speech progresses. Restarts the clock
    /// that decides when they've finished.
    private var pathMonitorStarted = false
    private func startPathMonitorIfNeeded() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.pathIsOnline = path.status == .satisfied
                diag("session", "network path: \(path.status == .satisfied ? "online" : "OFFLINE") (\(path.isExpensive ? "cellular/expensive" : "unmetered")\(path.isConstrained ? ", low-data-mode" : ""))")
                self.publishQuality()
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    /// The uplink can starve without a single local error: sockets connect,
    /// sends buffer into TCP, and the server simply never answers. Grade the
    /// connection every heartbeat and keep the UI's banner truthful.
    private func checkServerSilence() {
        guard isRunning, isSendingAudio, anySessionReady else { return }
        let silence = Date().timeIntervalSince(lastServerEventAt)
        if silence > serverSilenceLimit, !reportedServerSilence {
            reportedServerSilence = true
            diag("session", "server SILENT for \(Int(silence))s while streaming (peak mic \(Int(peakMicRMS))) — starved uplink or server issue")
        }
        publishQuality()
    }

    /// Hysteresis so the banner doesn't flap: degrading is immediate,
    /// recovering needs three consecutive healthy beats.
    private func publishQuality() {
        let silence = Date().timeIntervalSince(lastServerEventAt)
        let current: ConnectionQuality
        if !pathIsOnline {
            current = .offline
        } else if isRunning, isSendingAudio, anySessionReady, silence > serverSilenceLimit {
            current = .silent
        } else if isRunning, isSendingAudio, anySessionReady, silence > 3.0 {
            current = .degraded
        } else {
            current = .good
        }
        if current == .good, reportedQuality != .good {
            goodBeats += 1
            guard goodBeats >= 3 else { return }
        } else {
            goodBeats = 0
        }
        guard current != reportedQuality else { return }
        reportedQuality = current
        diag("session", "connection quality → \(current)")
        onConnectionQuality?(current)
    }

    private func noteServerRecovered() {
        guard reportedServerSilence else { return }
        reportedServerSilence = false
        diag("session", "server responding again")
        onServerRecovered?()
    }

    private func noteInputActivity() {
        lastInputAt = Date()
        lingeringTranslator = nil   // new speech owns the buffers again
        speakerHasStopped = false
        speechEndTimer?.invalidate()
        speechEndTimer = Timer.scheduledTimer(
            withTimeInterval: SpeechEndPolicy.transcriptIdleThreshold,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.speakerStopped() }
        }
    }

    private func speakerStopped(deferredSince: Date? = nil) {
        guard isRunning, !speakerHasStopped else { return }
        if !SpeechEndPolicy.mayRelease(
            now: Date(),
            lastLoudMicAt: lastLoudMicAt,
            deferredSince: deferredSince
        ) {
            let since = deferredSince ?? Date()
            if deferredSince == nil {
                diag("turn", "speaker-stop deferred — mic still hears speech")
            }
            speechEndTimer?.invalidate()
            speechEndTimer = Timer.scheduledTimer(
                withTimeInterval: SpeechEndPolicy.recheckInterval,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in self?.speakerStopped(deferredSince: since) }
            }
            return
        }
        speakerHasStopped = true
        diag("turn", "speaker stopped — waiting for committed translation audio")
        // Re-evaluate first: the home-silence confirm is time-based, and on a
        // laggy connection the whole translation can arrive in one burst
        // shorter than the confirm window — no later event ever re-checks,
        // and the held audio never plays (measured 2026-07-29, turn 1).
        turn.noteOutputs(outputs, inputs: inputs)
        reportDirectionIfChanged()
        startDirectionRecheck()
    }

    /// While translated audio sits in `pendingOutput` waiting for a
    /// direction, keep re-evaluating on a clock — the confirm window can
    /// elapse without any new server event to trigger it.
    private func startDirectionRecheck() {
        directionRecheckTimer?.invalidate()
        directionRecheckTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning, self.speakerHasStopped else {
                    self.stopDirectionRecheck()
                    return
                }
                self.turn.noteOutputs(self.outputs, inputs: self.inputs)
                self.reportDirectionIfChanged()
                if self.turn.direction != nil {
                    self.stopDirectionRecheck()
                }
            }
        }
    }

    private func stopDirectionRecheck() {
        directionRecheckTimer?.invalidate()
        directionRecheckTimer = nil
    }

    private static func rms(of pcm16: Data) -> Double {
        let count = pcm16.count / MemoryLayout<Int16>.size
        guard count > 0 else { return 0 }
        var sumSquares = 0.0
        pcm16.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let s = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sumSquares += s * s
            }
        }
        return (sumSquares / Double(count)).squareRoot()
    }

    /// Mark that a translation is playing; when it's been quiet for the tail
    /// timeout, that's the end of the turn — report it and get ready for the
    /// next one.
    /// If speech stops and no translated audio ever arrives (e.g. we picked
    /// a session that stays silent), still finalize the turn so `translator`
    /// can't go stale and swallow the next utterance.
    private func resetInputIdleTimer() {
        inputIdleTimer?.invalidate()
        inputIdleTimer = Timer.scheduledTimer(withTimeInterval: inputIdleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPlayingOutput else { return }
                // Same rule as the output-tail path: a translation still
                // arriving means the turn isn't over.
                guard self.turnMayFinalize else {
                    self.resetInputIdleTimer()
                    return
                }
                self.finalizeTurn()
            }
        }
    }

    private func finalizeTurn() {
        // A timer Task already on the main queue can land here after the
        // mute tore everything down — no late bubbles, no late audio.
        guard isRunning else { return }
        inputIdleTimer?.invalidate()
        inputIdleTimer = nil
        deferralTimer?.invalidate()
        deferralTimer = nil
        // A committed turn stays alive until its output tail is quiet. The
        // timer below comes back through here to perform the actual reset;
        // calling `commit` a second time would turn a successful turn into an
        // "already committed" rejection and lose its state.
        if turn.hasCommitted {
            resetForNextUtterance()
            onPartialInput?("")
            reportDirectionIfChanged()
            setActivity(.idle)
            return
        }
        emitUtterance()
        // The commit itself can be what resolves the direction (its home
        // branch needs no confirm window). Any audio still held for that
        // turn may play NOW — but only through the committed-translator
        // gate, never a provisional direction.
        if let t = turn.committedTranslator {
            reportDirectionIfChanged()
            releaseCommittedOutput(for: t)
            // On a starved uplink the translation TEXT can commit whole
            // seconds before its audio arrives. Let the translator's late
            // chunks play straight through for a grace window instead of
            // misfiling them into the next turn's buffers.
            lingeringTranslator = t
            lingerUntil = Date().addingTimeInterval(2.5)
            markOutputActive()
            return
        }
        // The decision itself lives in FinalizePolicy so the L3 harness runs
        // THIS rule rather than its own copy — the harness had no deferral at
        // all, which made the release gate report swallowed turns the app
        // would have recovered. GitHub #21.
        let outcome = finalizePolicy.decide(committed: turn.hasCommitted,
                                            rejectReason: turn.lastRejectReason)
        if outcome == .waitForTranslation {
            let reason = turn.lastRejectReason ?? "?"
            diag("turn", "finalize DEFERRED (\(reason)) — waiting for the missing translation, attempt \(finalizePolicy.deferrals)/\(FinalizePolicy.maxDeferrals)")
            deferralTimer = Timer.scheduledTimer(withTimeInterval: FinalizePolicy.deferralInterval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    // If new speech started meanwhile, the normal timers own
                    // the turn again — don't force-finalize mid-sentence. The
                    // rule and its clock live in FinalizePolicy so the harness
                    // runs THIS one. GitHub #21.
                    guard FinalizePolicy.deferredRetryIsDue(now: Date(),
                                                            lastInputAt: self.lastInputAt) else { return }
                    self.finalizeTurn()
                }
            }
            return
        }
        resetForNextUtterance()
        // Clear the live provisional line even when the turn produced no
        // bubble (e.g. no translation ever arrived) — otherwise the faded
        // "still working" text lingers on screen forever (SPEC §5.1).
        onPartialInput?("")
        reportDirectionIfChanged()   // back to "undecided" for the next turn
        setActivity(.idle)
    }

    /// A committed translation may finish playing only after both the input
    /// and output streams are quiet. This timer never releases PCM; it merely
    /// preserves the committed turn long enough for its tail, then returns to
    /// `finalizeTurn` for cleanup.
    private func markOutputActive() {
        isPlayingOutput = true
        setActivity(.translating)
        outputActivityTimer?.invalidate()
        outputActivityTimer = Timer.scheduledTimer(withTimeInterval: outputTailTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.turnMayFinalize {
                    self.markOutputActive()
                    return
                }
                self.isPlayingOutput = false
                self.finalizeTurn()
            }
        }
    }

    /// Commit the turn to a bubble. `TurnLogic.commit` enforces SPEC §5.1's
    /// four conditions: language known, something said, translation present,
    /// and not already committed.
    private func emitUtterance() {
        let outputSummary = outputs.keys.sorted { $0.rawValue < $1.rawValue }.map { "\($0.rawValue)=\((outputs[$0] ?? "").count)" }.joined(separator: " ")
        guard let bubble = turn.commit(inputs: inputs, outputs: outputs) else {
            diag("turn", "commit REJECTED: \(turn.lastRejectReason ?? "?") (outputs \(outputSummary), direction \(String(describing: turn.direction)))")
            return
        }
        diag("turn", "commit \(bubble.isHome ? "RIGHT/home" : "LEFT/foreign") via \(turn.translator?.rawValue ?? "?") | \(bubble.original.prefix(60)) → \(bubble.translation.prefix(60))")
        diag("turn", Self.inputTranscriptDiagnosticLine(inputs: inputs, sessions: activePair))
        onUtterance?(bubble.original, bubble.translation, bubble.isHome)  // R2: side from spoken language
    }

    private func play(pcm24kChunk data: Data) {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let floatChannel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<sampleCount {
                let sample = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<Int16>.size, as: Int16.self)
                floatChannel[i] = Float(Int16(littleEndian: sample)) / 32768.0
            }
        }
        playerNode.scheduleBuffer(buffer)
    }
}

/// The mic converter and the format it was built for, owned outside any actor.
///
/// These two values are read and written from the AVAudioEngine tap block,
/// which runs on the real-time audio render thread — `installTap` stores the
/// block and the engine invokes it directly, a path that never goes through
/// Swift's actor executor. They used to be stored properties of the
/// `@MainActor` service, so the render thread mutated them while the main
/// actor rebuilt the audio path from `startAudioIO()`/`stopAudioIO()` — which
/// the mic watchdog does on real hardware, by design, whenever the first tap
/// delivers zero buffers. Nothing forced those accesses onto one thread, and
/// "minimal" concurrency checking does not flag a closure handed to a C
/// callback API, so it compiled clean. GitHub #2.
///
/// The compare-and-rebuild is one atomic step under the lock, which also
/// closes the check-then-act window the old inline code had.
final class MicConverterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func set(_ converter: AVAudioConverter?, inputFormat: AVAudioFormat?) {
        lock.lock()
        defer { lock.unlock() }
        self.converter = converter
        self.inputFormat = inputFormat
    }

    /// A converter matching `format`, rebuilt if the incoming buffer's format
    /// has changed out from under us (a mid-flight route change would
    /// otherwise silently kill capture). `nil` only if one cannot be built.
    func converter(for format: AVAudioFormat,
                   target: AVAudioFormat) -> (converter: AVAudioConverter, didRebuild: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        if let converter, format == inputFormat {
            return (converter, false)
        }
        guard let rebuilt = AVAudioConverter(from: format, to: target) else { return nil }
        converter = rebuilt
        inputFormat = format
        return (rebuilt, true)
    }
}
