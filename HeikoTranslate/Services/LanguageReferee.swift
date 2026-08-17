import Foundation
import AVFoundation
import Speech

/// The second witness, running on device (GitHub #135, Phase 1).
///
/// Two `SFSpeechRecognizer`s — one per side of the pair — read the same
/// microphone buffers the Gemini sessions get. They cannot jointly drift to a
/// third language the way #125's pair does, because neither has a model for
/// one loaded.
///
/// **This is OBSERVE-ONLY and must stay that way in this phase.** Nothing here
/// is consulted by `TurnLogic`, the direction, the commit, or the audio gate.
/// It writes one `referee:` line per turn and nothing else. The precedent is
/// #112: `serverContent.interrupted` was parsed, surfaced and logged with no
/// behaviour change, because a signal that is silently swallowed looks
/// identical to one that never arrives — and the same is true of a witness
/// whose accuracy against a human voice in a real room has never been
/// measured. TTS fixtures could not reproduce #32; they will not settle this
/// either.
///
/// Every failure mode is inert rather than fatal (R8). No on-device model, no
/// authorization, a recognizer that dies mid-turn: the referee records why and
/// stands down. The app must behave exactly as it does today when this class
/// can say nothing, which is also what makes it safe to carry on a branch that
/// gets deployed to a real phone.
///
/// No protocol seam, deliberately: the decision logic lives in
/// `RefereeEvidence` (pure, covered by L1.95–L1.97b), and this half is pure
/// I/O that no app decision depends on. A seam here would be scaffolding with
/// no consumer. That changes the day Phase 2 wires a verdict into anything.
///
/// Thread safety: `append` is called from the audio render thread, the
/// recognition callbacks arrive on their own queue, and the readings are read
/// from the main actor. All shared state is behind one lock, the same shape
/// `MicConverterBox` uses for the converter.
final class LanguageReferee: @unchecked Sendable {

    typealias Lang = TurnLogic.Lang

    private struct Side {
        let recognizer: SFSpeechRecognizer?
        var availability: RefereeEvidence.Availability
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var text: String = ""
        var confidence: Double = 0
    }

    /// On iOS 26 the whole job is delegated to `TranscriberReferee`: the app
    /// can install its own assets there (verified on device — `fr_FR` in 29
    /// seconds, silently), and the old API cannot see them. Held as
    /// `AnyObject` because a stored property cannot name an `@available` type
    /// from a class that is not itself gated.
    private var modernBox: AnyObject?

    private let lock = NSLock()
    private var sides: [Lang: Side] = [:]
    private var order: [Lang] = []
    private var running = false

    /// Ask once per process. The dialog is a real cost to a user who speaks no
    /// English (#135 §5) — it is requested here, off the start path, rather
    /// than woven into `beginListening()`, whose interleavings are pinned by
    /// L1.66a–m and must not gain a new await.
    static func requestAuthorizationIfNeeded() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            DiagnosticLog.shared.log("referee", "speech authorization → \(describe(status))")
        }
    }

    /// Log, once per launch, which languages this device can actually run
    /// on-device recognition for.
    ///
    /// The first device run (#135, 2026-08-17) found only `de` and `en`
    /// available on an iPhone 14 Pro — leaving the referee inert for exactly
    /// the pairs that carry the bugs. That answer only appeared for whichever
    /// pair happened to be selected, so establishing it for six languages
    /// meant six pair switches. One launch should answer it.
    ///
    /// `supportsOnDeviceRecognition` reports whether the model is INSTALLED,
    /// not whether the hardware could run it, so this is also the readout for
    /// whether enabling a dictation language in Settings changed anything.
    ///
    /// Capability queries only: no authorization request, no audio, no
    /// recognition task. Safe to call before the user has granted anything.
    static func logOnDeviceCapability() {
        let states = Lang.allCases.map { lang -> String in
            let identifier = RefereeEvidence.speechLocaleIdentifier(for: lang)
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else {
                return "\(lang.rawValue)=no-recognizer"
            }
            return "\(lang.rawValue)=\(recognizer.supportsOnDeviceRecognition ? "on-device" : "NO-MODEL")"
        }
        DiagnosticLog.shared.log("referee", "on-device capability: " + states.joined(separator: " ")
            + " | auth=\(describe(SFSpeechRecognizer.authorizationStatus()))")
    }

    static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    // MARK: - Lifecycle

    /// Build both recognizers for the pair and start their first tasks.
    /// Called from `startAudioIO`, so it shares the tap's lifetime exactly and
    /// never runs under the L1 audio seam.
    func start(home: Lang, partner: Lang) {
        stop()
        if #available(iOS 26.0, *) {
            let modern = TranscriberReferee()
            modernBox = modern
            modern.start(home: home, partner: partner)
            DiagnosticLog.shared.log("referee", "start pair \(home.rawValue)/\(partner.rawValue) — via SpeechTranscriber (iOS 26)")
            return
        }
        lock.lock()
        order = [home, partner]
        let authorized = SFSpeechRecognizer.authorizationStatus() == .authorized
        for lang in order {
            let identifier = RefereeEvidence.speechLocaleIdentifier(for: lang)
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
            var availability: RefereeEvidence.Availability = .ready
            if recognizer == nil {
                availability = .failed("no recognizer for \(identifier)")
            } else if !authorized {
                availability = .unauthorized
            } else if !(recognizer?.supportsOnDeviceRecognition ?? false) {
                // The privacy invariant: a locale with no on-device model
                // stands down. It must NEVER fall back to network
                // recognition, which would send audio to Apple and make
                // docs/privacy-policy.md untrue (#135 §6).
                availability = .noOnDeviceModel
            } else if !(recognizer?.isAvailable ?? false) {
                availability = .failed("recognizer unavailable")
            }
            sides[lang] = Side(recognizer: recognizer, availability: availability)
        }
        running = true
        let summary = order.map { "\($0.rawValue)=\(describeAvailability(sides[$0]?.availability ?? .failed("?")))" }
            .joined(separator: " ")
        lock.unlock()

        DiagnosticLog.shared.log("referee", "start pair \(home.rawValue)/\(partner.rawValue) — \(summary)")
        startTasks()
    }

    func stop() {
        if #available(iOS 26.0, *), let modern = modernBox as? TranscriberReferee {
            modern.stop()
            modernBox = nil
            return
        }
        lock.lock()
        running = false
        let toCancel = sides.values.compactMap { $0.task }
        let toEnd = sides.values.compactMap { $0.request }
        sides = [:]
        order = []
        lock.unlock()
        for request in toEnd { request.endAudio() }
        for task in toCancel { task.cancel() }
    }

    /// End this turn's recognition and begin the next. Per-turn isolation is
    /// not a workaround for the task duration limit — it is the same rule the
    /// Gemini side already lives by: one turn's context must not leak into the
    /// next, which is what `speechHeardThisTurn` and `staleCodeGrace` exist to
    /// enforce against straggler codes.
    func rotate() {
        if #available(iOS 26.0, *), let modern = modernBox as? TranscriberReferee {
            modern.rotate()
            return
        }
        lock.lock()
        guard running else { lock.unlock(); return }
        let toCancel = sides.values.compactMap { $0.task }
        let toEnd = sides.values.compactMap { $0.request }
        for lang in order {
            sides[lang]?.request = nil
            sides[lang]?.task = nil
            sides[lang]?.text = ""
            sides[lang]?.confidence = 0
        }
        lock.unlock()
        for request in toEnd { request.endAudio() }
        for task in toCancel { task.cancel() }
        startTasks()
    }

    // MARK: - Audio

    /// Called from the audio render thread. Must not touch anything unguarded
    /// and must never throw work back onto that thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        if #available(iOS 26.0, *), let modern = modernBox as? TranscriberReferee {
            modern.append(buffer)
            return
        }
        lock.lock()
        guard running else { lock.unlock(); return }
        let requests = order.compactMap { sides[$0]?.request }
        lock.unlock()
        for request in requests { request.append(buffer) }
    }

    // MARK: - Readings

    /// A snapshot of what each recognizer has heard this turn, for the log
    /// line. Never blocks on a final result — Phase 1 wants what the referee
    /// would have said at the moment the turn was decided.
    func currentReadings() -> (home: RefereeEvidence.Reading, partner: RefereeEvidence.Reading)? {
        if #available(iOS 26.0, *), let modern = modernBox as? TranscriberReferee {
            return modern.currentReadings()
        }
        lock.lock()
        defer { lock.unlock() }
        guard order.count == 2,
              let home = sides[order[0]], let partner = sides[order[1]] else { return nil }
        return (RefereeEvidence.Reading(lang: order[0],
                                        availability: home.availability,
                                        text: home.text,
                                        confidence: home.confidence),
                RefereeEvidence.Reading(lang: order[1],
                                        availability: partner.availability,
                                        text: partner.text,
                                        confidence: partner.confidence))
    }

    // MARK: - Internals

    private func startTasks() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let langs = order
        lock.unlock()

        for lang in langs {
            lock.lock()
            guard running,
                  let side = sides[lang],
                  side.availability == .ready,
                  let recognizer = side.recognizer,
                  side.task == nil
            else { lock.unlock(); continue }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            // Partial results are the point: the turn is decided by the
            // Gemini side's own clocks, and the referee has to be readable at
            // that instant rather than whenever a final result lands.
            request.shouldReportPartialResults = true
            sides[lang]?.request = request
            lock.unlock()

            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.running, self.sides[lang] != nil else { return }
                if let result {
                    self.sides[lang]?.text = result.bestTranscription.formattedString
                    let segments = result.bestTranscription.segments
                    if !segments.isEmpty {
                        let total = segments.reduce(0.0) { $0 + Double($1.confidence) }
                        self.sides[lang]?.confidence = total / Double(segments.count)
                    }
                }
                if error != nil || (result?.isFinal ?? false) {
                    // The task is spent. Leave the text standing — it is this
                    // turn's testimony — and let the next rotate() start a
                    // fresh one. Deliberately NOT restarted here: a recognizer
                    // failing repeatedly would otherwise spin for the whole
                    // session.
                    self.sides[lang]?.task = nil
                }
            }
            lock.lock()
            if running { sides[lang]?.task = task } else { task.cancel() }
            lock.unlock()
        }
    }

    private func describeAvailability(_ a: RefereeEvidence.Availability) -> String {
        switch a {
        case .ready: return "ready"
        case .noOnDeviceModel: return "NO-ON-DEVICE-MODEL"
        case .unauthorized: return "unauthorized"
        case .failed(let why): return "failed(\(why))"
        }
    }

    /// The one line this phase exists to produce. Says what each recognizer
    /// heard, what the referee would have concluded, and what the app actually
    /// decided — so a device log answers "would the referee have been right?"
    /// on the turns that are currently wrong, without instrumenting anything
    /// further.
    func diagnosticLine(appDecision: String) -> String? {
        guard let readings = currentReadings() else { return nil }
        let score = RefereeEvidence.score(home: readings.home, partner: readings.partner)
        let verdict: String
        switch RefereeEvidence.verdict(home: readings.home, partner: readings.partner) {
        case .spoke(let lang): verdict = lang.rawValue
        case .inconclusive(let why): verdict = "inconclusive(\(why))"
        }
        func render(_ r: RefereeEvidence.Reading) -> String {
            switch r.availability {
            case .ready:
                return "heard[\(r.lang.rawValue)] \"\(GeminiLiveTranslationService.escapedDiagnosticTranscript(r.trimmed))\" conf=\(String(format: "%.2f", r.confidence))"
            default:
                return "heard[\(r.lang.rawValue)] <\(describeAvailability(r.availability))>"
            }
        }
        return "referee: \(verdict) | app: \(appDecision) | "
            + render(readings.home) + "  " + render(readings.partner)
            + " | confΔ=\(String(format: "%+.2f", score.confidenceDelta))"
            + " ratio=\(String(format: "%.3f", score.lengthRatio))"
            + " onlyOne=\(score.onlyOneSubstantive)"
    }
}
