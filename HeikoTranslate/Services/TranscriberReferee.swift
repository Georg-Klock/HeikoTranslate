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
        guard let resolved = installed.first(where: { $0.hasPrefix(code) }) else {
            setAvailability(.noOnDeviceModel, for: lang)
            DiagnosticLog.shared.log("referee", "[\(lang.rawValue)] no installed locale for \(code) — inert")
            return
        }

        let transcriber = SpeechTranscriber(locale: Locale(identifier: resolved),
                                            preset: .progressiveTranscription)
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
                    self.setText(String(result.text.characters), for: lang)
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
        for side in sides.values { side.text = "" }
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
        // Confidence is an AttributedString attribute on this API rather than a
        // scalar per segment, and the old path's confidence was measured
        // useless anyway (0.94 on a foreign word against 0.62 on a correct
        // native sentence). Reported as 0 and deliberately not used: the
        // question this port answers is whether the TEXT is better.
        return (RefereeEvidence.Reading(lang: h.lang, availability: h.availability, text: h.text, confidence: 0),
                RefereeEvidence.Reading(lang: p.lang, availability: p.availability, text: p.text, confidence: 0))
    }

    private func setText(_ text: String, for lang: Lang) {
        lock.lock(); defer { lock.unlock() }
        sides[lang]?.text = text
    }

    private func setAvailability(_ a: RefereeEvidence.Availability, for lang: Lang) {
        lock.lock(); defer { lock.unlock() }
        sides[lang]?.availability = a
    }
}
