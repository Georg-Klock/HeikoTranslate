import Foundation

/// Strips hesitation noises ("ähm", "um") out of committed transcript lines.
/// Heiko is reading these to follow a conversation, not studying a verbatim
/// transcript, and the model faithfully translates every "um" into an "ähm".
///
/// **The admission rule, enforced ruthlessly:** a token belongs in a list only
/// if it cannot be a real word, an abbreviation, or a meaning-carrying
/// response in *any* language that list is applied to. Deleting a real word
/// leaves a fluent, plausible sentence that Heiko has no way to know is
/// wrong — far worse than leaving a stray "ähm" in.
///
/// An adversarial review on 2026-07-28 caught this list being too greedy.
/// Everything below was removed for cause, and must not come back:
///
/// | Token | Why it is NOT filler |
/// |-------|----------------------|
/// | `mm`  | millimetres — "6 mm lang" → "6 lang", unit silently gone |
/// | `mhm` | the spoken "yes" in German *and* English — a whole answer vanished |
/// | `hm`  | "Hm?" is a request to repeat; "Hm, ja." carries meaning |
/// | `eh`  | real Spanish interjection; "¿Eh?" = "come again?" |
/// | `er`  | "he" in German, and "ER" the emergency room in English |
/// | `err` | "err on the side of caution" |
///
/// What remains are sounds that are not words in any of the three languages.
enum FillerWords {
    /// English and Spanish hesitation sounds.
    private static let foreign: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "uhhm", "erm",
    ]

    /// German hesitation sounds. No "er" ("he"), no "also" ("so"), no "hm"
    /// or "mhm" (agreement), no "mm" (millimetres).
    private static let german: Set<String> = [
        "äh", "ähh", "ähhh", "ähm", "ähmm", "ähem", "öh", "öhm", "öhh",
    ]

    static func list(isGerman: Bool) -> Set<String> {
        isGerman ? german : foreign
    }

    /// Per-language entry point. Only German, English, and Spanish have
    /// studied lists; for every other language nothing is stripped — the
    /// adversarial review of the first list proved that deleting real words
    /// is the expensive failure, and we haven't studied French/Korean/
    /// Chinese hesitation noises against real-word collisions.
    static func strip(_ text: String, for lang: TurnLogic.Lang) -> String {
        switch lang {
        case .de: return strip(text, isGerman: true)
        case .en, .es: return strip(text, isGerman: false)
        // tl/vi join the unstudied set for the same reason (#30): deleting
        // real words is the expensive failure, and nobody has studied their
        // hesitation noises against real-word collisions.
        case .fr, .ko, .zh, .tl, .vi: return text
        }
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]

    /// Remove standalone hesitation tokens.
    ///
    /// Guarantees, each covered by a test:
    /// - Text containing no filler comes back **byte-identical**. Nothing is
    ///   re-capitalised, re-punctuated or otherwise "tidied" — an earlier
    ///   version rewrote "am 3. oder 4. Mai" into "am 3. Oder 4. Mai" and
    ///   "iPhone" into "IPhone".
    /// - A sentence whose opening filler is removed keeps its capital.
    /// - Punctuation orphaned by a removed filler is given back to the
    ///   previous word, replacing a dangling comma rather than following it.
    /// - Returns "" when nothing but hesitation was said, which the caller
    ///   treats as "nothing was said".
    static func strip(_ text: String, isGerman: Bool) -> String {
        let fillers = list(isGerman: isGerman)
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)

        func bareWord(_ token: Substring) -> String {
            token.lowercased()
                .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        }
        // Fast path AND correctness guarantee: with nothing to remove, the
        // input is returned untouched.
        guard tokens.contains(where: { fillers.contains(bareWord($0)) }) else { return text }

        var kept: [String] = []
        var capitalizeNextKept = false
        var pendingTerminator: Character?
        var previousEndedSentence = true   // start of string opens a sentence

        for token in tokens {
            let isFiller = fillers.contains(bareWord(token))
            let endsSentence = token.last.map(terminators.contains) ?? false

            if isFiller {
                // Only inherit a capital if this filler actually opened a
                // sentence — never capitalise mid-sentence words.
                if previousEndedSentence { capitalizeNextKept = true }
                if endsSentence { pendingTerminator = token.last }
                continue
            }

            var word = String(token)
            if capitalizeNextKept, let first = word.first, first.isLowercase {
                word = first.uppercased() + word.dropFirst()
            }
            capitalizeNextKept = false

            if let terminator = pendingTerminator {
                if var previous = kept.popLast() {
                    if previous.last == "," || previous.last == ";" {
                        previous.removeLast()            // "pesos, ¿eh?" not "pesos,?"
                    }
                    if !(previous.last.map(terminators.contains) ?? false) {
                        previous.append(terminator)
                    }
                    kept.append(previous)
                    if let first = word.first, first.isLowercase {
                        word = first.uppercased() + word.dropFirst()
                    }
                }
                pendingTerminator = nil
            }

            kept.append(word)
            previousEndedSentence = endsSentence
        }

        var result = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.first, first == "," || first == "." || first == "…" {
            result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let first = result.first, first.isLowercase {
                result = first.uppercased() + result.dropFirst()
            }
        }
        if let terminator = pendingTerminator, !result.isEmpty {
            if result.last == "," || result.last == ";" { result.removeLast() }
            if !(result.last.map(terminators.contains) ?? false) { result.append(terminator) }
        }
        return result
    }
}
