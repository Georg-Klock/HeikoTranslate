import Foundation
import AVFoundation
import Speech

/// The referee, ported to iOS 26's `SpeechAnalyzer` / `SpeechTranscriber`
/// (#135).
///
/// Why the port exists: the `SFSpeechRecognizer` implementation could only
/// testify for languages whose models the OWNER had installed, which measured
/// as German and English only — inert for exactly the de↔es and de↔fr pairs
/// that carry the bugs. On iOS 26 the app installs its own assets
/// (`SpeechAssetProbe`), verified on device: `fr_FR` downloaded in 29 seconds
/// with no Settings, no keyboard and nothing visible on the phone. But the old
/// API does not see those assets (`fr=STILL-NO` after a successful install),
/// so using them means using the new framework.
///
/// **Still OBSERVE-ONLY.** Nothing here is read by `TurnLogic`, the direction,
/// the commit or the audio gate — only by the `referee:` diagnostic line. The
/// open question this is built to answer is not coverage but ACCURACY: the old
/// path agreed with the app on 2 turns of 6, decided everything by which
/// recogniser stayed silent, and its confidence collided exactly as
/// `echoShare` did. Whether a substantially better model fixes that is
/// unmeasured, and measuring it is the entire point.
///
/// Shape difference from the old API, which is most of the work: a
/// `SpeechAnalyzer` is an actor fed by an `AsyncSequence` of `AnalyzerInput`,
/// not a task with a result callback. So each side owns a stream continuation
/// that the audio thread yields into, and a consuming task that drains
/// `transcriber.results` into the reading.
@available(iOS 26.0, *)
final class TranscriberReferee: @unchecked Sendable {

    typealias Lang = TurnLogic.Lang

    private final class Side {
        let lang: Lang
        var availability: RefereeEvidence.Availability = .ready
        var text: String = ""
        var confidence: Double = 0
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var analyzer: SpeechAnalyzer?
        var consumer: Task<Void, Never>?
        var converter: AVAudioConverter?
        var analyzerFormat: AVAudioFormat?
        init(lang: Lang) { self.lang = lang }
    }

    private let lock = NSLock()
    private var sides: [Lang: Side] = [:]
    private var order: [Lang] = []
    private var running = false

    // MARK: - Lifecycle

    func start(home: Lang, partner: Lang) {
        stop()
        lock.lock()
        order = [home, partner]
        for lang in order { sides[lang] = Side(lang: lang) }
        running = true
        lock.unlock()
        for lang in [home, partner] {
            Task { await self.spinUp(lang) }
        }
    }

    private func spinUp(_ lang: Lang) async {
        let identifier = RefereeEvidence.speechLocaleIdentifier(for: lang)
        // Match the OS's own spelling — asking for es-MX must not miss an
        // es_419 asset, and the installed list is the authority.
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
        let code = String(identifier.prefix(2))
        // Prefer the EXACT locale, then the language's own country, then any
        // regional variant. The first device run picked `de_CH` and `de_AT`
        // for German and `fr_CH` for French, because the installed list is
        // alphabetical and `first(where: hasPrefix)` took whatever sorted
        // first — a Swiss German model on standard German speech. Regional
        // models are not interchangeable, and this is a transcription-quality
        // bug hiding as a locale-string detail.
        let wantedUnderscored = identifier.replacingOccurrences(of: "-", with: "_")
        let resolvedOrNil = installed.first { $0 == wantedUnderscored }
            ?? installed.first { $0 == code + "_" + code.uppercased() }
            ?? installed.first { $0.hasPrefix(code) }
        guard let resolved = resolvedOrNil else {
            setAvailability(.noOnDeviceModel, for: lang)
            DiagnosticLog.shared.log("referee", "[\(lang.rawValue)] no installed locale for \(code) — inert")
            return
        }

        // Confidence has to be REQUESTED — the presets do not carry it, which
        // is why the first run reported 0.00 on every turn. It is the missing
        // discriminator: the run that broke "longer transcript wins" had the
        // English recogniser emit 207 characters of fluent nonsense
        // ("Hello, is Bengal, conditioner, to Ghana…") against 36 characters
        // of correct German, so length cannot tell confident from garbled and
        // a per-run score might.
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: resolved),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.transcriptionConfidence])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            setAvailability(.failed("no compatible audio format"), for: lang)
            return
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Drain results into the reading. `progressiveTranscription` reports
        // volatile results as they firm up, which is what the turn clock needs
        // — the verdict is read at commit, not whenever a final lands.
        let consumer = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    self.setReading(text: String(result.text.characters),
                                    confidence: Self.meanConfidence(of: result.text),
                                    for: lang)
                }
            } catch {
                self?.setAvailability(.failed(error.localizedDescription), for: lang)
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            setAvailability(.failed("start: \(error.localizedDescription)"), for: lang)
            consumer.cancel()
            continuation.finish()
            return
        }

        lock.lock()
        if running, let side = sides[lang] {
            side.continuation = continuation
            side.analyzer = analyzer
            side.consumer = consumer
            side.analyzerFormat = format
        } else {
            continuation.finish()
            consumer.cancel()
        }
        lock.unlock()
        DiagnosticLog.shared.log("referee", "[\(lang.rawValue)] SpeechTranscriber ready (\(resolved), \(Int(format.sampleRate))Hz)")
    }

    func stop() {
        lock.lock()
        running = false
        let all = Array(sides.values)
        sides = [:]
        order = []
        lock.unlock()
        for side in all {
            side.continuation?.finish()
            side.consumer?.cancel()
            let analyzer = side.analyzer
            Task { await analyzer?.cancelAndFinishNow() }
        }
    }

    /// One turn's recognition must not carry into the next — the same rule the
    /// Gemini side enforces with `speechHeardThisTurn` and `staleCodeGrace`.
    ///
    /// The text is cleared rather than the analyzer torn down and rebuilt:
    /// spinning up an analyzer costs an async round trip and would miss the
    /// opening of the next utterance, which is exactly the R4 failure this
    /// project has spent the most time on.
    func rotate() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        // Confidence must be cleared WITH the text, not left behind. Device
        // evidence (2.4.62): a turn logged `heard[en] "" conf=0.93` — an empty
        // reading carrying the previous turn's score, which reads as strong
        // testimony for a side that said nothing at all. Two fields, one
        // lifetime.
        for side in sides.values {
            side.text = ""
            side.confidence = 0
        }
    }

    // MARK: - Audio

    /// Called from the audio render thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard running else { lock.unlock(); return }
        let targets = order.compactMap { sides[$0] }
        lock.unlock()

        for side in targets {
            guard let continuation = side.continuation,
                  let format = side.analyzerFormat else { continue }
            guard let converted = convert(buffer, to: format, side: side) else { continue }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// The tap's format is the input node's, which is not what the analyzer
    /// asked for. Converting per side rather than once because the two sides
    /// can in principle want different formats.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, side: Side) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if side.converter == nil || side.converter?.inputFormat != buffer.format {
            side.converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter = side.converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        let source = SingleShot(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if let b = source.take() {
                outStatus.pointee = .haveData
                return b
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// Hands the buffer to the converter's input block exactly once — the same
    /// idiom the service uses for its own converter, and for the same reason.
    private final class SingleShot: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    // MARK: - Readings

    func currentReadings() -> (home: RefereeEvidence.Reading, partner: RefereeEvidence.Reading)? {
        lock.lock()
        defer { lock.unlock() }
        guard order.count == 2, let h = sides[order[0]], let p = sides[order[1]] else { return nil }
        return (RefereeEvidence.Reading(lang: h.lang, availability: h.availability, text: h.text, confidence: h.confidence),
                RefereeEvidence.Reading(lang: p.lang, availability: p.availability, text: p.text, confidence: p.confidence))
    }

    private func setReading(text: String, confidence: Double, for lang: Lang) {
        lock.lock(); defer { lock.unlock() }
        sides[lang]?.text = text
        // A zero means "this result carried no confidence attribute", not
        // "the recogniser is unsure" — volatile results frequently arrive
        // without one. Measured on 2.4.63: roughly a third of turns logged
        // conf=0.00 on BOTH sides, which is unreadable as evidence, and on
        // several of them an earlier result in the same turn had reported a
        // perfectly good score that the final volatile result then erased.
        // So confidence only ever moves UP within a turn, and `rotate` is
        // what resets it.
        if confidence > 0 {
            sides[lang]?.confidence = max(sides[lang]?.confidence ?? 0, confidence)
        }
    }

    /// Mean `transcriptionConfidence` across the runs that carry one, weighted
    /// by run length so a one-word run cannot outvote a clause.
    static func meanConfidence(of text: AttributedString) -> Double {
        var weighted = 0.0
        var characters = 0
        for run in text.runs {
            guard let score = run.transcriptionConfidence else { continue }
            let n = text[run.range].characters.count
            guard n > 0 else { continue }
            weighted += score * Double(n)
            characters += n
        }
        guard characters > 0 else { return 0 }
        return weighted / Double(characters)
    }

    private func setAvailability(_ a: RefereeEvidence.Availability, for lang: Lang) {
        lock.lock(); defer { lock.unlock() }
        sides[lang]?.availability = a
    }
}
