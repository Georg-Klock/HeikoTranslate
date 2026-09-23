import Foundation
import NaturalLanguage

/// Reads the spoken language off an input transcript, for engines whose
/// server does not report one.
///
/// Gemini streams a `languageCode` with its input transcription, and
/// `TurnLogic`'s settle window votes on those codes. OpenAI's translation
/// endpoint sends transcript text only, and Grok's voice agent the same. This
/// turns their text into the same votes, so the turn machinery above stays
/// engine-agnostic.
///
/// Two properties matter more than accuracy on any single call:
///
/// - **It forgets between utterances.** Transcript text accumulates only
///   while deltas keep arriving; a gap longer than `utteranceGap` starts a
///   fresh buffer. Without that, a German reply would be classified together
///   with the English sentence before it and vote English for its first
///   second — exactly the stale-vote failure the settle window exists for.
/// - **It stays quiet on too little text.** Below `minimumCharacters` the
///   recognizer is guessing, and a guessed vote is worse than no vote: the
///   settle window waits for the first code, so a wrong early one steers the
///   whole turn.
///
/// Constrained to the app's own language set, so a German sentence full of
/// English loanwords can be misread as English but never as Dutch.
struct TranscriptLanguageWitness {

    static let utteranceGap: TimeInterval = 1.0
    static let minimumCharacters = 12

    private let recognizer = NLLanguageRecognizer()
    private var buffer = ""
    private var lastDeltaAt: Date?

    /// `candidates` is the app's language set as codes. Passed in rather than
    /// read from `TurnLogic.Lang` so the session harnesses can link this
    /// file without the turn sources.
    init(candidates: [String]) {
        recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
    }

    /// Feed one transcript fragment; returns a language code to vote with,
    /// or nil when there is not yet enough text to say.
    mutating func note(_ delta: String, at now: Date) -> String? {
        if let last = lastDeltaAt, now.timeIntervalSince(last) > Self.utteranceGap {
            buffer = ""
        }
        lastDeltaAt = now
        buffer += delta
        return Self.classify(buffer, with: recognizer)
    }

    /// The pure half, for tests and for the harnesses.
    static func classify(_ text: String, candidates: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
        return classify(text, with: recognizer)
    }

    private static func classify(_ text: String, with recognizer: NLLanguageRecognizer) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return nil }
        recognizer.reset()
        recognizer.processString(trimmed)
        return recognizer.dominantLanguage?.rawValue
    }
}
