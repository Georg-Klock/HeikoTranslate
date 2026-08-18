import Foundation
import NaturalLanguage

/// Which side of the pair the model just spoke in (#135, experiment).
///
/// **The idea this exists to serve.** In interpreter mode ONE session gets the
/// audio and picks the translation direction itself. The app still needs to
/// know which side the bubble belongs on — and the answer is simply *which
/// language the model chose to speak*. Route that output to the language key
/// it is in, and the session masquerades as whichever of the two sessions
/// "would have" translated in the shipping design. Every downstream rule —
/// the release timing, #78's mic-aware deferral through a breath pause, the
/// linger window, the truncation floors — then works unchanged, because it
/// sees exactly the shape it already knows.
///
/// That is the whole point of the hybrid: the model contributes the DIRECTION,
/// which L3 replay showed it gets right (10/11, including the mid-stream
/// switch), and the app keeps SEGMENTATION, which the same replay showed the
/// model gets wrong — it split a breath-paused German sentence into two turns,
/// the pre-#78 behaviour of talking over the speaker.
///
/// **Why classifying text is legitimate here, having been rejected in #135.**
/// The referee objection was that a text classifier confirms whatever the
/// wrong-language recogniser hallucinated: the transcript was the corrupted
/// evidence. This classifies the model's own clean translation, where the
/// language is the deliberate output rather than a guess about the input. It
/// is also constrained to the two configured languages, so it answers a binary
/// question rather than a 100-way one — the same pair restriction that took a
/// general LID model from 89.5% to 100% on the bench corpus.
enum InterpreterRouting {

    typealias Lang = TurnLogic.Lang

    /// Below this many characters the answer is not worth having. Two or three
    /// characters of a streamed translation ("Ja", "Es") are a prefix, not a
    /// language, and locking the turn's side to a prefix is how the shipping
    /// arbitration used to settle a direction from a false start.
    static let minimumCharacters = 6

    /// The language of `text`, restricted to the configured pair.
    ///
    /// Returns nil when the text is too short to judge or the classifier is
    /// unsure — the caller must treat that as "not yet", never as a side.
    /// Guessing early is worse than waiting: audio is held until the app's own
    /// turn clock releases it, so a late answer costs nothing and a wrong one
    /// costs the turn.
    static func side(of text: String, home: Lang, partner: Lang) -> Lang? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters, home != partner else { return nil }

        let recognizer = NLLanguageRecognizer()
        // Constrain to the pair. The app always knows both, so asking a
        // 100-way question and hoping is leaving the easy win on the table.
        recognizer.languageConstraints = [NLLanguage(bcp47(home)), NLLanguage(bcp47(partner))]
        recognizer.processString(trimmed)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let homeScore = hypotheses[NLLanguage(bcp47(home))] ?? 0
        let partnerScore = hypotheses[NLLanguage(bcp47(partner))] ?? 0
        guard homeScore > 0 || partnerScore > 0 else { return nil }
        return homeScore >= partnerScore ? home : partner
    }

    /// The classifier's language codes. Deliberately the bare language, not
    /// the app's region-qualified recognition locales (`es-MX`, `en-US`) —
    /// those are speech-recognition identifiers and this is text.
    private static func bcp47(_ lang: Lang) -> String {
        switch lang {
        case .de: return "de"
        case .en: return "en"
        case .es: return "es"
        case .fr: return "fr"
        case .ko: return "ko"
        case .zh: return "zh-Hans"
        // Partner-side only (#30/#28) — never a home language, but reachable
        // as the other half of a pair, so they need codes like the rest.
        case .tl: return "tl"
        case .vi: return "vi"
        }
    }
}
