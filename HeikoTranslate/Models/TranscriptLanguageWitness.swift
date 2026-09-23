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
/// - **It stays quiet when it is guessing.** A short text must score at
///   least `shortTextConfidence`, a longer one `minimumConfidence`. A
///   guessed vote is worse than no vote: the settle window waits for the
///   first code, so a wrong early one steers the whole turn.
///
/// Limited to the app's own language set, so a German sentence full of
/// English loanwords can be misread as English but never as Dutch.
struct TranscriptLanguageWitness {

    static let utteranceGap: TimeInterval = 1.0
    /// Below this many characters a text counts as SHORT and must clear
    /// `shortTextConfidence` instead of `minimumConfidence`.
    static let shortTextLength = 12

    private let recognizer = NLLanguageRecognizer()
    private var buffer = ""
    private var lastDeltaAt: Date?

    /// `candidates` is the app's language set as codes. Passed in rather than
    /// read from `TurnLogic.Lang` so the session harnesses can link this
    /// file without the turn sources.
    init(candidates: [String]) {
        self.candidates = candidates
    }

    private let candidates: [String]

    /// Feed one transcript fragment; returns a language code to vote with,
    /// or nil when there is not yet enough text to say.
    mutating func note(_ delta: String, at now: Date) -> String? {
        if let last = lastDeltaAt, now.timeIntervalSince(last) > Self.utteranceGap {
            buffer = ""
        }
        lastDeltaAt = now
        buffer += delta
        return Self.classify(buffer, candidates: candidates, with: recognizer)
    }

    /// The pure half, for tests and for the harnesses.
    static func classify(_ text: String, candidates: [String]) -> String? {
        classify(text, candidates: candidates, with: NLLanguageRecognizer())
    }

    /// The best-scoring CANDIDATE, if it is a confident one.
    ///
    /// `languageConstraints` looks like the way to do this and is not: measured
    /// 2026-09-23 on macOS, a recognizer constrained to de/en/es/ko still named
    /// "ok ok ok ok ok ok" Dutch and "Hmm hmm hmm hmm" Polish, and an L3
    /// replay on OpenAI carried `fi` and `id` votes into the turn. A vote for
    /// a language outside the pair is the #125 shape. So the full hypothesis
    /// list is read and filtered here, and a text none of the four clearly
    /// owns abstains.
    private static func classify(_ text: String, candidates: [String],
                                 with recognizer: NLLanguageRecognizer) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        recognizer.reset()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 100)
        guard let best = candidates
            .compactMap({ code in hypotheses[NLLanguage(rawValue: code)].map { (code, $0) } })
            .max(by: { $0.1 < $1.1 }),
              best.1 >= (trimmed.count < shortTextLength ? shortTextConfidence : minimumConfidence)
        else { return nil }
        return best.0
    }

    /// How sure the recognizer must be of the winning candidate. "Hello
    /// there" scores English at 0.64; filler that belongs to no language
    /// scores every candidate far lower.
    static let minimumConfidence = 0.5

    /// The bar for short text. It was a flat 12-character minimum until
    /// 2026-09-23, and that is what put "Ja, gerne." on the wrong side on
    /// device: OpenAI's home session repeats home speech instead of staying
    /// silent, and with no vote to say the speech was German the repeat was
    /// read as a translation. Length was the wrong proxy for "too little to
    /// tell". Measured scores: "Ja, gerne." de 0.91, "Danke." de 0.96,
    /// "Yeah" en 0.88, "Thank you." en 0.87 all clear it; "Ja" 0.08,
    /// "Okay." 0.39 and "Perfekt." 0.28 do not, and those still abstain.
    static let shortTextConfidence = 0.85
}
