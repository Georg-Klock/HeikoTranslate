import Foundation

/// A second witness to "which language was just spoken", independent of
/// Gemini (GitHub #135).
///
/// Every open turn-routing failure shares one root: the app's only witness is
/// Gemini, and all Gemini sessions run one model, so they mis-hear *together*.
/// #125 has both sessions of a de↔es pair settling on English — a language in
/// neither side of the pair. The ten labelled turns in TESTING.md have ten
/// English utterances transcribed AS GERMAN by the `de` session, both sessions
/// voting `de`. A third Gemini session was measured against exactly this and
/// did not help (6/10 vs a 5/10 baseline, branch
/// `feat/de-es-referee-session`): correlated errors cannot be outvoted by
/// more of the same voter.
///
/// The referee is two on-device speech recognizers, one per side of the pair,
/// reading the same microphone audio. They cannot jointly drift to a third
/// language because neither has a model for one loaded.
///
/// This type is the PURE half — no `Speech` import, no I/O — for the reason
/// `TurnLogic`, `SpeechEndPolicy` and `FinalizePolicy` are pure: the decision
/// runs at L1 and in the offline harness, on the same code the app runs.
/// `Tools/lidprobe.sh` drives it over the `TestAudio/` corpus.
///
/// **Phase 0 status: the discriminator is NOT calibrated yet, on purpose.**
/// `verdict(...)` decides only the structural case (one recognizer produced
/// words, the other produced nothing) and reports `.inconclusive` for
/// everything else. It does not threshold `Score`. That is the #32 lesson
/// applied before the fact: `echoShare` failed because two turns scored 0.429
/// with opposite correct answers, and the fix that worked
/// (`sharesHomeFunctionWords`) measured 0 against 2 — a gap with nothing in
/// it. Until `lidprobe` produces a table showing which of these scores has a
/// gap, any cut-off here would be fitted to the first two points somebody
/// looked at.
struct RefereeEvidence {
    typealias Lang = TurnLogic.Lang

    /// Whether a recognizer can testify at all. Anything other than `.ready`
    /// makes the referee inert for that side — the app must behave exactly as
    /// it does today when the referee cannot speak, never worse (R8). The
    /// same doctrine as `homeFunctionWords` returning an empty set for the
    /// languages it has no corpus for.
    enum Availability: Equatable {
        case ready
        /// No on-device model for this locale. Never a reason to fall back to
        /// network recognition — see `requiresOnDeviceRecognition` in
        /// `Tools/lidprobe/main.swift` and §6 of #135.
        case noOnDeviceModel
        case unauthorized
        case failed(String)
    }

    /// One recognizer's reading of one turn.
    struct Reading: Equatable {
        let lang: Lang
        let availability: Availability
        let text: String
        /// Mean confidence over the final transcript's segments, 0...1.
        ///
        /// Recorded but deliberately not trusted yet: partial results are
        /// widely reported to carry 0.0, so a confidence-difference rule may
        /// have no signal to work with. Establishing that is Phase 0's job,
        /// which is why this is measured rather than assumed.
        let confidence: Double

        init(lang: Lang, availability: Availability = .ready,
             text: String = "", confidence: Double = 0) {
            self.lang = lang
            self.availability = availability
            self.text = text
            self.confidence = confidence
        }

        var trimmed: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// A reading counts as testimony only if the recognizer was actually
        /// able to run AND produced words. Whitespace is not words.
        var isSubstantive: Bool {
            availability == .ready && !trimmed.isEmpty
        }
    }

    enum Verdict: Equatable {
        case spoke(Lang)
        /// Carries why, so a device log line distinguishes "the referee was
        /// not available" from "the referee heard both sides" — those want
        /// opposite follow-ups, the same reason `decisionSummary` exists.
        case inconclusive(String)
    }

    /// The candidate discriminators, computed and REPORTED rather than
    /// thresholded. `Tools/lidprobe.sh` prints these per fixture so Phase 0
    /// can pick on data.
    ///
    /// Character counts are raw and comparable only within one script. #29
    /// measured that a German-calibrated character floor is wrong for zh/ko;
    /// nothing here may become a threshold without that same per-script
    /// measurement.
    struct Score: Equatable {
        let homeChars: Int
        let partnerChars: Int
        /// home − partner. Positive favours home.
        let confidenceDelta: Double
        /// Shorter ÷ longer, 0...1. 0 when either side is empty; 1 when both
        /// produced the same amount. Low means one recognizer gave up, which
        /// is the shape the structural rule below acts on.
        let lengthRatio: Double
        /// Exactly one side produced words.
        let onlyOneSubstantive: Bool
    }

    static func score(home: Reading, partner: Reading) -> Score {
        let h = home.isSubstantive ? home.trimmed.count : 0
        let p = partner.isSubstantive ? partner.trimmed.count : 0
        let ratio: Double
        if h == 0 || p == 0 {
            ratio = 0
        } else {
            ratio = Double(min(h, p)) / Double(max(h, p))
        }
        return Score(homeChars: h,
                     partnerChars: p,
                     confidenceDelta: home.confidence - partner.confidence,
                     lengthRatio: ratio,
                     onlyOneSubstantive: home.isSubstantive != partner.isSubstantive)
    }

    /// The Phase 0 verdict: structural only.
    ///
    /// One recognizer produced words and the other produced none is not a
    /// threshold — it is a categorical difference, and it is the only claim
    /// this type is entitled to make before `lidprobe` has measured the rest.
    /// Everything else is `.inconclusive`, which the caller must treat as "no
    /// information", never as "the other side".
    static func verdict(home: Reading, partner: Reading) -> Verdict {
        guard home.availability == .ready, partner.availability == .ready else {
            return .inconclusive("referee unavailable")
        }
        switch (home.isSubstantive, partner.isSubstantive) {
        case (true, false): return .spoke(home.lang)
        case (false, true): return .spoke(partner.lang)
        case (false, false): return .inconclusive("neither recognizer produced words")
        case (true, true): return .inconclusive("both recognizers produced words")
        }
    }

    /// The speech-recognition locale for each app language.
    ///
    /// Exhaustive on purpose: adding a `Lang` must break the build here
    /// rather than silently leave the new language without a referee. The
    /// regional choices follow the app's existing product decisions — en is
    /// US and es is Mexican, the same pairing the flags encode.
    ///
    /// Whether an on-device model actually exists for each of these is a
    /// device fact, not a code fact: `supportsOnDeviceRecognition` is checked
    /// at run time and a missing model yields `.noOnDeviceModel`. tl/vi are
    /// partner-only (#30) and are expected to be the first to come back
    /// unsupported.
    static func speechLocaleIdentifier(for lang: Lang) -> String {
        switch lang {
        case .de: return "de-DE"
        case .en: return "en-US"
        case .es: return "es-MX"
        case .fr: return "fr-FR"
        case .ko: return "ko-KR"
        case .zh: return "zh-CN"
        case .tl: return "fil-PH"
        case .vi: return "vi-VN"
        }
    }
}
