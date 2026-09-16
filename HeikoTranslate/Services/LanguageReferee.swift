import Foundation
import AVFoundation
import CoreMedia
import Speech

/// The on-device language witness the translation service will hold (#135).
///
/// Two transcribers, one per side of the pair, read the same raw microphone
/// buffers the Gemini sessions get. At every turn boundary the service asks for
/// the turn's `RefereeEvidence` and the referee starts listening afresh.
///
/// **Observe-only (#135 Phase 1).** The evidence is for the diagnostic log. No
/// routing, commit, direction or audio decision may read it until device logs
/// have measured it against a human voice.
///
/// **Never fatal, never blocking (R8).** `start` returns at once; models load
/// and install in the background, and until they are ready — or forever, on an
/// OS or device that cannot run them — the evidence says `inconclusive` with the
/// reason. No call here throws, awaits, or can stop audio from reaching Gemini.
///
/// **On device only (#135 §6).** The transcriber has no network recognition
/// mode: nothing here sends audio anywhere. What does use the network is the
/// one-time model download through `AssetInventory`, which carries no audio.
/// `RefereeEvidenceTests` scans this file so a network-capable recognition API
/// cannot be added to it quietly.
///
/// **No new permission dialog.** The transcriber asks for no speech
/// authorization and needs no usage description beyond the microphone's the
/// app already has — measured 2026-09-16, see docs/experiments/lid-referee.md.
protocol LanguageRefereeing: AnyObject {
    /// Begin listening for a pair. Call when the audio tap starts, and again
    /// whenever the pair changes; any previous pair is torn down first.
    /// Returns immediately.
    func start(home: TurnLogic.Lang, partner: TurnLogic.Lang)

    /// Feed one raw tap buffer, in the input node's native format, BEFORE the
    /// service's own Int16/16 kHz conversion. Called on the tap's thread; never
    /// blocks beyond a short lock.
    func append(_ buffer: AVAudioPCMBuffer)

    /// The turn just ended: return what each side heard since the previous
    /// boundary, and start the next turn from here. `nil` only when no pair is
    /// running, i.e. before `start` or after `stop`.
    ///
    /// A snapshot, not a wait: whatever the transcribers have produced so far,
    /// volatile text included. The service's turn boundary comes after its own
    /// settle and translation delays, which are longer than the transcriber's
    /// lag, so the snapshot normally holds the whole utterance.
    func turnEnded() -> RefereeEvidence?

    /// Tear down both transcribers. Belongs in the service's one shared audio
    /// teardown, so a mute or a rebuild cannot leave them listening (#15, #127).
    func stop()
}

enum LanguageRefereeFactory {
    /// The transcriber referee where the OS has one, the inert one elsewhere.
    static func make() -> LanguageRefereeing {
        if #available(iOS 26.0, *) {
            return TranscriberReferee()
        }
        return InertLanguageReferee(reason: .unsupportedOS)
    }
}

/// The referee that cannot testify: on iOS before 26, and wherever a caller
/// needs the seam without the Speech framework. Every turn is inconclusive,
/// with the reason on both readings.
final class InertLanguageReferee: LanguageRefereeing {
    let reason: RefereeEvidence.Availability
    private var pair: (home: TurnLogic.Lang, partner: TurnLogic.Lang)?

    init(reason: RefereeEvidence.Availability) {
        self.reason = reason
    }

    func start(home: TurnLogic.Lang, partner: TurnLogic.Lang) {
        pair = (home, partner)
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func turnEnded() -> RefereeEvidence? {
        guard let pair else { return nil }
        return RefereeEvidence(home: .init(lang: pair.home, availability: reason),
                               partner: .init(lang: pair.partner, availability: reason))
    }

    func stop() {
        pair = nil
    }
}

// MARK: - SpeechTranscriber

/// Two `SpeechTranscriber`s behind one lock.
///
/// Shape: a `SpeechAnalyzer` is an actor fed by an `AsyncStream` of
/// `AnalyzerInput`, so each side owns a stream continuation the tap thread
/// yields into, a task draining `transcriber.results`, and its own converter
/// from the tap's format to the one the analyzer asked for.
///
/// Turn rotation keeps the analyzer running and moves a time boundary instead:
/// rebuilding one costs an async round trip and would miss the opening of the
/// next utterance (R4). Results are placed on the audio timeline by their
/// `range`, and anything that ends before the boundary belongs to the turn
/// already reported and is dropped.
@available(iOS 26.0, *)
final class TranscriberReferee: LanguageRefereeing, @unchecked Sendable {
    typealias Lang = TurnLogic.Lang

    private struct Segment {
        let range: CMTimeRange
        let text: String
        let confidenceSum: Double
        let confidenceCharacters: Int
    }

    private final class Side {
        let lang: Lang
        var availability: RefereeEvidence.Availability = .assetsNotInstalled
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        var analyzer: SpeechAnalyzer?
        var consumer: Task<Void, Never>?
        var format: AVAudioFormat?
        var converter: AVAudioConverter?
        /// Frames yielded to the analyzer, in its format: the audio clock the
        /// results' ranges are measured on.
        var framesYielded: AVAudioFramePosition = 0
        var turnStart: CMTime = .zero
        var finals: [Segment] = []
        var volatile: Segment?
        init(lang: Lang) { self.lang = lang }
    }

    private let lock = NSLock()
    private var sides: [Side] = []
    /// Bumped by every start and stop, so work begun for an old pair cannot
    /// attach itself to a new one.
    private var generation = 0

    /// Locales with an install already under way in this process.
    private static let installLock = NSLock()
    private static var installing: Set<String> = []

    // MARK: Lifecycle

    func start(home: Lang, partner: Lang) {
        stop()
        lock.lock()
        generation += 1
        let current = generation
        sides = [Side(lang: home), Side(lang: partner)]
        let started = sides
        lock.unlock()

        guard SpeechTranscriber.isAvailable else {
            for side in started { set(.unavailableOnDevice, on: side, generation: current) }
            DiagnosticLog.shared.log("referee", "SpeechTranscriber unavailable on this device — inert")
            return
        }
        for side in started {
            Task(priority: .utility) { await self.prepare(side, generation: current) }
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        let old = sides
        sides = []
        lock.unlock()
        for side in old { Self.tearDown(side) }
    }

    private static func tearDown(_ side: Side) {
        side.continuation?.finish()
        side.consumer?.cancel()
        if let analyzer = side.analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == self.generation
    }

    private func set(_ availability: RefereeEvidence.Availability, on side: Side, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        guard generation == self.generation else { return }
        side.availability = availability
    }

    private static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults],
                          attributeOptions: [.transcriptionConfidence])
    }

    /// Resolve the locale, install its model if missing, then start listening.
    private func prepare(_ side: Side, generation: Int) async {
        let wanted = Locale(identifier: RefereeEvidence.localeIdentifier(for: side.lang))
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            set(.unsupportedLocale, on: side, generation: generation)
            DiagnosticLog.shared.log("referee", "[\(side.lang.rawValue)] \(wanted.identifier) unsupported — inert")
            return
        }
        let module = Self.module(for: locale)
        if await AssetInventory.status(forModules: [module]) != .installed {
            set(.assetsNotInstalled, on: side, generation: generation)
            guard await Self.install(module, locale: locale), isCurrent(generation) else { return }
        }
        await listen(side, module: module, locale: locale, generation: generation)
    }

    /// Download the model in the background, silently. `false` when it did not
    /// end installed, or another start is already fetching it — that start
    /// owns it, and the next `start` after it lands will find it installed.
    private static func install(_ module: SpeechTranscriber, locale: Locale) async -> Bool {
        guard claimInstall(locale.identifier) else { return false }
        defer { releaseInstall(locale.identifier) }
        let clock = ContinuousClock()
        let began = clock.now
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                DiagnosticLog.shared.log("referee", "install \(locale.identifier) …")
                try await request.downloadAndInstall()
            }
        } catch {
            DiagnosticLog.shared.log("referee", "install \(locale.identifier) FAILED: \(error.localizedDescription)")
            return false
        }
        let installed = await AssetInventory.status(forModules: [module]) == .installed
        DiagnosticLog.shared.log("referee", "install \(locale.identifier) \(installed ? "done" : "incomplete") after \(clock.now - began)")
        return installed
    }

    private static func claimInstall(_ identifier: String) -> Bool {
        installLock.lock(); defer { installLock.unlock() }
        return installing.insert(identifier).inserted
    }

    private static func releaseInstall(_ identifier: String) {
        installLock.lock(); defer { installLock.unlock() }
        installing.remove(identifier)
    }

    private func listen(_ side: Side, module: SpeechTranscriber, locale: Locale, generation: Int) async {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            set(.failed("no compatible audio format"), on: side, generation: generation)
            return
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])
        let consumer = Task(priority: .utility) { [weak self] in
            do {
                for try await result in module.results {
                    self?.record(result, on: side, generation: generation)
                }
            } catch {
                self?.set(.failed(error.localizedDescription), on: side, generation: generation)
            }
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            consumer.cancel()
            continuation.finish()
            set(.failed("start: \(error.localizedDescription)"), on: side, generation: generation)
            return
        }

        if attach(side, continuation: continuation, analyzer: analyzer, consumer: consumer,
                  format: format, generation: generation) {
            DiagnosticLog.shared.log("referee", "[\(side.lang.rawValue)] listening (\(locale.identifier), \(Int(format.sampleRate)) Hz)")
        } else {
            continuation.finish()
            consumer.cancel()
            await analyzer.cancelAndFinishNow()
        }
    }

    /// Hand a started analyzer to its side, unless a stop or a new pair got
    /// there first — then the caller tears it down.
    private func attach(_ side: Side, continuation: AsyncStream<AnalyzerInput>.Continuation,
                        analyzer: SpeechAnalyzer, consumer: Task<Void, Never>,
                        format: AVAudioFormat, generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == self.generation else { return false }
        side.continuation = continuation
        side.analyzer = analyzer
        side.consumer = consumer
        side.format = format
        side.availability = .ready
        return true
    }

    // MARK: Results

    private func record(_ result: SpeechTranscriber.Result, on side: Side, generation: Int) {
        var sum = 0.0
        var counted = 0
        for run in result.text.runs {
            guard let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { continue }
            let n = result.text[run.range].characters.count
            sum += c * Double(n)
            counted += n
        }
        let segment = Segment(range: result.range, text: String(result.text.characters),
                              confidenceSum: sum, confidenceCharacters: counted)

        lock.lock(); defer { lock.unlock() }
        guard generation == self.generation else { return }
        // Wholly before the boundary: the previous turn's, already reported.
        if CMTimeCompare(CMTimeRangeGetEnd(result.range), side.turnStart) <= 0 { return }
        if result.isFinal {
            side.finals.append(segment)
            side.volatile = nil
        } else {
            side.volatile = segment
        }
    }

    // MARK: Audio

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let targets = sides.compactMap { side in side.format.map { (side, $0) } }
        lock.unlock()
        for (side, format) in targets {
            guard let converted = convert(buffer, to: format, side: side) else { continue }
            lock.lock()
            let continuation = side.continuation
            if continuation != nil { side.framesYielded += AVAudioFramePosition(converted.frameLength) }
            lock.unlock()
            continuation?.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Only the tap's thread converts, so the converter needs no lock of its
    /// own; it is rebuilt if the input format changes (a route change).
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, side: Side) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if side.converter == nil || side.converter?.inputFormat != buffer.format {
            side.converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter = side.converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var handed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if handed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    // MARK: Turns

    func turnEnded() -> RefereeEvidence? {
        lock.lock()
        guard sides.count == 2 else {
            lock.unlock()
            return nil
        }
        let readings = sides.map(Self.reading)
        var boundaries: [(SpeechAnalyzer, CMTime)] = []
        for side in sides {
            let rate = side.format.map { Int32($0.sampleRate) } ?? 16_000
            let boundary = CMTime(value: CMTimeValue(side.framesYielded), timescale: rate)
            side.turnStart = boundary
            side.finals = []
            side.volatile = nil
            if let analyzer = side.analyzer { boundaries.append((analyzer, boundary)) }
        }
        lock.unlock()

        // Close the ended turn's pending text so it finalizes before the
        // boundary, where `record` drops it, rather than bleeding into the next
        // turn. Fire and forget: nothing waits on it.
        for (analyzer, boundary) in boundaries {
            Task(priority: .utility) { try? await analyzer.finalize(through: boundary) }
        }
        return RefereeEvidence(home: readings[0], partner: readings[1])
    }

    /// Called with `lock` held.
    private static func reading(_ side: Side) -> RefereeEvidence.Reading {
        guard side.availability == .ready else {
            return .init(lang: side.lang, availability: side.availability)
        }
        let segments = side.finals + [side.volatile].compactMap { $0 }
        let characters = segments.reduce(0) { $0 + $1.confidenceCharacters }
        let sum = segments.reduce(0.0) { $0 + $1.confidenceSum }
        return .init(lang: side.lang, availability: .ready,
                     text: segments.map(\.text).joined(),
                     confidence: characters > 0 ? sum / Double(characters) : nil)
    }
}
