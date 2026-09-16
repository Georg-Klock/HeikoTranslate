import Foundation

/// A second witness to "which language was just spoken", independent of
/// Gemini (GitHub #135).
///
/// Every Gemini session runs one model, so the sessions mis-hear *together*:
/// #125 had both sides of a pair settle on a language neither side speaks, and
/// a third Gemini session measured 6/10 against a 5/10 baseline because
/// correlated errors cannot be outvoted by more of the same voter. The referee
/// is two on-device `SpeechTranscriber`s, one per side of the pair, reading the
/// same microphone audio. Their errors are not Gemini's.
///
/// This is the PURE half — no `Speech` import, no I/O, no clock — for the
/// reason `TurnLogic` is pure: the rule runs at L1 and inside
/// `Tools/lidprobe.sh` on the same code the app runs. `LanguageReferee.swift`
/// holds the I/O half and produces the two `Reading`s this type judges.
///
/// **What the rule is entitled to claim is set by measurement, not taste.**
/// #32's lesson: `echoShare` failed because two turns scored 0.429 with
/// opposite correct answers, and the rule that worked measured 0 against 2 — a
/// gap with nothing in it. Every candidate score below is computed and
/// REPORTED; only the one `Tools/lidprobe.sh` showed a gap for decides, and its
/// number is in `Thresholds` beside the measurement
/// (docs/experiments/lid-referee.md, 2026-09-16).
///
/// **Observe-only.** Nothing in the app may act on `verdict` until device logs
/// (#135 Phase 1) have re-measured the gap on a human voice and the phone's own
/// models. The corpus that found it is text-to-speech read on a Mac.
struct RefereeEvidence: Equatable {
    typealias Lang = TurnLogic.Lang

    /// Whether a recognizer can testify at all. Anything but `.ready` makes the
    /// whole referee inert for the turn — the app must behave exactly as it
    /// does without it, never worse (R8).
    enum Availability: Equatable {
        case ready
        /// The OS predates `SpeechTranscriber` (iOS 26).
        case unsupportedOS
        /// The OS has the framework but this hardware cannot run the
        /// transcriber (`SpeechTranscriber.isAvailable` is false).
        case unavailableOnDevice
        /// The OS has no on-device transcription model for this locale at all.
        /// Never a reason to reach for network recognition (#135 §6).
        case unsupportedLocale
        /// Supported, but the model is not on the device yet; a background
        /// install may be under way.
        case assetsNotInstalled
        case failed(String)
    }

    /// One recognizer's reading of one turn: the observation, not a judgement.
    struct Reading: Equatable {
        let lang: Lang
        let availability: Availability
        let text: String
        /// Mean `transcriptionConfidence` over the transcript, weighted by
        /// characters, 0...1. `nil` when the recognizer reported none — which
        /// is different from reporting zero, and must not be averaged as zero.
        let confidence: Double?
        /// Alternative transcriptions, when the recognizer offered any.
        let alternatives: [String]

        init(lang: Lang, availability: Availability = .ready, text: String = "",
             confidence: Double? = nil, alternatives: [String] = []) {
            self.lang = lang
            self.availability = availability
            self.text = text
            self.confidence = confidence
            self.alternatives = alternatives
        }

        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// Letters and digits only. Punctuation is not speech, and a
        /// recognizer that returns "." has heard nothing.
        var speechCharacters: Int {
            trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        }

        /// Testimony requires a recognizer that ran AND produced words.
        var isSubstantive: Bool { availability == .ready && speechCharacters > 0 }
    }

    enum Verdict: Equatable {
        case home
        case partner
        case inconclusive
    }

    /// The candidate discriminators from #135 §3, each signed so that a
    /// POSITIVE value favours home. Reported, not thresholded, except where
    /// `Thresholds` says otherwise.
    ///
    /// Character counts are comparable only within one script: a Korean
    /// transcript is a fraction of the characters of the same sentence in
    /// German (#29 measured the same for floors). A length score on a pair
    /// with `ko` in it is therefore not the same instrument as on de↔en.
    struct Score: Equatable {
        let homeCharacters: Int
        let partnerCharacters: Int
        /// home − partner mean confidence; `nil` unless both sides reported one.
        let confidenceDelta: Double?
        /// (home − partner) ÷ (home + partner) characters, −1...1; 0 when both
        /// are empty.
        let lengthBalance: Double
        /// As `lengthBalance`, but each side's characters weighted by its
        /// confidence — "confidence together with length", the hypothesis the
        /// 2026-08-17 device run left open at n=2. `nil` without confidences.
        let weightedBalance: Double?
        /// Exactly one side produced words.
        let onlyOneSubstantive: Bool
    }

    /// Every number this type acts on, in one place.
    enum Thresholds {
        /// The verdict names a side only when that side's transcriber was at
        /// least this much more confident than the other's.
        ///
        /// Measured 2026-09-16 (`Tools/lidprobe.sh`, TestAudio, macOS 26.5
        /// models, de-DE against en-US / es-MX / ko-KR): over 35 single-
        /// utterance readings, `confidenceDelta` was +0.201 … +0.764 when German
        /// was spoken and −0.177 … +0.035 when the partner was — a gap of 0.166
        /// with nothing in it. The next best, the partner's confidence alone,
        /// cleared by 0.039; length scores overlapped.
        ///
        /// 0.10 is a round number inside that gap, symmetric about zero, and
        /// deliberately NOT either edge of it: the partner population's top
        /// (+0.035, a list of brand names) sits on the home side of zero, so
        /// "whichever is more confident" is already wrong about one measured
        /// file, and a cut at an edge would be fitted to the eight partner
        /// files this corpus has. It was chosen after reading the table, so
        /// this corpus cannot also validate it; Phase 1's device logs are
        /// where it is tested.
        static let confidenceMargin = 0.10
    }

    let home: Reading
    let partner: Reading
    let score: Score
    let verdict: Verdict
    /// Why, in a few words, so a log line distinguishes "could not testify"
    /// from "testified and could not tell" — they want opposite follow-ups.
    let reason: String

    init(home: Reading, partner: Reading) {
        self.home = home
        self.partner = partner
        self.score = Self.score(home: home, partner: partner)
        (self.verdict, self.reason) = Self.judge(home: home, partner: partner)
    }

    static func score(home: Reading, partner: Reading) -> Score {
        let h = home.isSubstantive ? home.speechCharacters : 0
        let p = partner.isSubstantive ? partner.speechCharacters : 0
        let balance = (h + p) == 0 ? 0 : Double(h - p) / Double(h + p)

        var delta: Double?
        var weighted: Double?
        if let hc = home.confidence, let pc = partner.confidence {
            delta = hc - pc
            let hw = Double(h) * hc
            let pw = Double(p) * pc
            weighted = (hw + pw) == 0 ? 0 : (hw - pw) / (hw + pw)
        }
        return Score(homeCharacters: h, partnerCharacters: p,
                     confidenceDelta: delta, lengthBalance: balance,
                     weightedBalance: weighted,
                     onlyOneSubstantive: home.isSubstantive != partner.isSubstantive)
    }

    private static func judge(home: Reading, partner: Reading) -> (Verdict, String) {
        guard home.availability == .ready, partner.availability == .ready else {
            return (.inconclusive, "unavailable")
        }
        guard home.isSubstantive || partner.isSubstantive else {
            return (.inconclusive, "neither side heard words")
        }
        // A side with no confidence produced no transcript at all. That is not
        // evidence for the other side: the 2026-08-17 device run found the
        // "one side silent" rule wrong on 4 of 6 turns, and the 2026-09-16
        // corpus run found the German transcriber hearing "you" in noise.wav
        // while the partner stayed silent.
        guard let hc = home.confidence, let pc = partner.confidence else {
            return (.inconclusive, "one side silent")
        }
        let delta = hc - pc
        if delta >= Thresholds.confidenceMargin, home.isSubstantive {
            return (.home, "home more confident")
        }
        if -delta >= Thresholds.confidenceMargin, partner.isSubstantive {
            return (.partner, "partner more confident")
        }
        return (.inconclusive, "within margin")
    }

    /// The `SpeechTranscriber` locale for each app language.
    ///
    /// Exhaustive on purpose: adding a `Lang` breaks the build here rather
    /// than shipping a language without a referee locale. Regions follow the
    /// app's product decisions, which the flags encode: US English, Mexican
    /// Spanish. Whether the OS has a model for each is a run-time fact, and the
    /// OS's equivalent locale is what is actually used.
    static func localeIdentifier(for lang: Lang) -> String {
        switch lang {
        case .de: return "de-DE"
        case .en: return "en-US"
        case .es: return "es-MX"
        case .ko: return "ko-KR"
        }
    }
}
