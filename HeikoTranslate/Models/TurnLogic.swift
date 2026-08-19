import Foundation

/// The turn-taking state machine: was the HOME language spoken or the
/// partner's, which session's translation should play, and when a finished
/// turn may become a transcript bubble. Pure decision-making — no audio, no
/// network, no timers — so the L1 tests exercise the exact code the app runs.
///
/// **The pair is explicit.** Settings select a home language (right side,
/// large type — the phone owner's reader language, German by default) and a
/// partner language (left side, English/🇺🇸 by default). One session per
/// side. The old design inferred the partner from the conversation because
/// there were no settings; with settings, inference — and its whole
/// misdetection surface — is gone.
///
/// **Direction comes from which session translated, not from the language
/// codes.** Measured against the live API (2026-07-27, German hub; the
/// mechanism is symmetric): a session translates substantially if and only
/// if the input was NOT its own target language. One measured exception
/// (#75, 2026-08-07): a session that mis-hears home speech as a
/// neighbouring language "translates" it back into its own target at full
/// length — indistinguishable from a real translation by size, but built
/// from the input's own words, which is what the echo detection below
/// catches. So:
///  - home session produced a real translation ⇒ the speech was foreign
///    (partner or any third language) ⇒ bubble LEFT, translation in the
///    home language — the home reader is always served.
///  - partner session translating while the home session stays quiet for
///    `homeSilenceConfirmDelay` ⇒ the home language was spoken ⇒ RIGHT.
/// Codes lie (measured: "ja" for plain English); they are used only as a
/// veto — never to decide a side.
struct TurnLogic {
    /// Languages offered in settings. Raw value is the BCP-47 code sent to
    /// the API — every one verified against the live model (2026-07-28
    /// target probe: de/en/es/fr/ko/zh all translate).
    enum Lang: String, CaseIterable, Codable {
        case de, en, es, fr, ko, zh
        // Partner-side only (Georg's decision, #30/#28, 2026-08-12): the
        // model translates both (verified live 2026-08-12,
        // Tools/targetprobe.sh tl vi), but neither is an app language — the
        // home wheel never offers them, so no UI set exists for them and
        // #6's review surface does not grow.
        case tl, vi

        /// Flag shown in the picker and on the split button. English uses
        /// the US flag and Spanish the Mexican flag by product decision.
        var flag: String {
            switch self {
            case .de: return "🇩🇪"
            case .en: return "🇺🇸"
            case .es: return "🇲🇽"
            case .fr: return "🇫🇷"
            case .ko: return "🇰🇷"
            case .zh: return "🇨🇳"
            case .tl: return "🇵🇭"
            case .vi: return "🇻🇳"
            }
        }

        /// German display name — the UI's language.
        /// German names, kept for logs and tests. What the USER sees comes
        /// from `UIStrings.of(home).languageNames`, so a Spanish home reader
        /// sees "Inglés" rather than "Englisch".
        var displayName: String {
            switch self {
            case .de: return "Deutsch"
            case .en: return "Englisch"
            case .es: return "Spanisch"
            case .fr: return "Französisch"
            case .ko: return "Koreanisch"
            case .zh: return "Chinesisch"
            case .tl: return "Tagalog"
            case .vi: return "Vietnamesisch"
            }
        }

        /// Whether this language may take the HOME side — the reader's
        /// side, whose language the whole UI renders in. Partner-only
        /// languages have no UI set, so home must never become one; the
        /// wheel filter and the collision swap both consult this. #30.
        var canBeHome: Bool {
            switch self {
            case .tl, .vi: return false
            default: return true
            }
        }

        // `name(in:)` and `endonym` live on this type but are DEFINED in
        // UIStrings.swift. TurnLogic is compiled on its own by the L3 harness
        // (Tools/l3replay.sh), so it must not reference anything above the
        // model layer — putting the lookups here broke that build while every
        // L1 test stayed green.
    }

    // MARK: - Tuning constants (all from live measurement)

    /// Codes for the PREVIOUS turn's language straggle in for ~2s after it
    /// finalizes; codes for a different language are a fast reply and count.
    static let staleCodeGrace: TimeInterval = 2.5
    /// Votes collect this long before the plurality settles the spoken-
    /// language guess — the opening burst can be unanimously wrong.
    static let settleWindow: TimeInterval = 1.5
    /// A tally with no fresh votes for this long belongs to a dead context.
    static let voteExpiry: TimeInterval = 4.0
    /// The output-substance floors, PER HOME LANGUAGE. Character counts
    /// carry different amounts of meaning per script (#29): eight characters
    /// of German is one short word, eight of Chinese a substantial clause —
    /// and `home` is not always German; the settings sheet offers all six on
    /// the home wheel (L1.29e).
    struct OutputFloors {
        /// Absolute floor when the partner session hasn't produced anything
        /// yet — the home output must stand on its own.
        let decisive: Int
        /// Floor once the codes HAVE settled on a non-home language AND the
        /// partner session echoed. Corroboration does the work then; this
        /// only stops a bare false start riding in beside a full echo.
        /// Deliberately NOT applied when nothing echoed — see
        /// `homeIsRealTranslation`; a floor there would swallow "Ja" (2) and
        /// "Nein" (4), L1.41b.
        let corroborated: Int
        /// The home output as a fraction of the partner echo before it
        /// counts as a real translation on length alone.
        let ratio: Double
    }

    /// The measured German values, unchanged: ratio 0.4 (false starts —
    /// "Ich", 3 chars vs 95 — must not decide a turn), decisive 8, and
    /// corroborated 5, bracketed by the measured points "Ich" (3, L1.22)
    /// and "14 Euro" (7, 2026-07-29) — clearing every observed false start
    /// with a character of margin while admitting the short numeric answers
    /// Heiko actually gets at a till. GitHub #23.
    static let germanBaselineFloors = OutputFloors(decisive: 8, corroborated: 5, ratio: 0.4)

    /// Every language currently carries the German-measured baseline —
    /// behaviour identical to the shared constants this replaces. The rule
    /// for what lands here, stated before any number does: a language's
    /// entry comes from `Tools/floor_measurement.py`'s campaign, and may
    /// only LOOSEN relative to the baseline, never tighten — German is the
    /// calibrated reference, and #29's defect is over-rejection in dense
    /// scripts. GitHub #29.
    static func floors(for home: Lang) -> OutputFloors {
        switch home {
        // Measured 2026-08-11, Tools/floor_measurement.py on the Swift wire
        // path (60 probes; the table is committed beside the tool). Korean
        // short answers ran 2-7 chars ("네."=2) with answer ratios down to
        // 0.5; Chinese 2-4 ("谢谢。"=3, "好的。"=4) with ratios to 0.34 —
        // both sides of the German baseline would reject most of them. The
        // suggested floors take the observed minimum (corroborated), keep
        // the German 8:5 shape above it (decisive), and put the same 0.67
        // safety factor under the observed minimum ratio that 0.4 has
        // against German's measured ~0.6.
        case .ko: return OutputFloors(decisive: 3, corroborated: 2, ratio: 0.34)
        case .zh: return OutputFloors(decisive: 3, corroborated: 2, ratio: 0.23)
        // The Latin homes measured SAFELY ABOVE the baseline (short answers
        // ≥3 chars — "No."=3, "Vale."≈5 — ratios ≥0.84), so they keep the
        // German values: the binding constraint there is the false-start
        // corpus ("Ich"/"Das"/"Und"), which only German has measured, and
        // which the campaign deliberately does not model. Loosening Latin
        // floors to the campaign's naive minimum would readmit exactly
        // those. GitHub #29.
        default: return germanBaselineFloors
        }
    }
    /// How long the partner session must translate alone before home-session
    /// silence proves the home language was spoken.
    static let homeSilenceConfirmDelay: TimeInterval = 1.2
    /// A settled spoken-language can be poisoned (measured 2026-07-29:
    /// stragglers settled "en" during silence, then twelve unanimous "de"
    /// codes during the real German speech couldn't overturn it and the
    /// veto swallowed the turn). This many CONSECUTIVE votes for one other
    /// language re-settle it. Alternating lying codes (en,de,en,de — the
    /// normal noise during speech) never reach the threshold.
    static let overturnVotes = 3

    /// Echo detection (#75, #45). Share of an output's TOKENS already present
    /// in this turn's input transcripts, above which a long output is a
    /// round-trip echo of what was heard rather than a translation of it.
    ///
    /// Measured 2026-08-07 over 20 live replays (39 outputs, de↔es and
    /// de↔en): every genuine translation scored 0.00–0.17 — the hits are
    /// names and cognates — while every echo scored 0.80–1.00, including the
    /// one misattributed turn (0.85: German misheard as Spanish, the pseudo-
    /// Spanish opening translated back into German, the rest repeated
    /// verbatim). 0.6 sat between those two populations with margin both ways.
    ///
    /// **Re-calibrated 2026-08-14 (#32).** That measurement saw two
    /// populations. Device turns on 2.4.52 found a third, sitting in the gap
    /// the threshold had been placed in: a German sentence containing an
    /// English fragment, where the home session translates the fragment and
    /// echoes the rest. Measured shares — 0.429 for
    /// "Wir werden euch rocken ist mein Lieblingslied." against
    /// "We will rock you. ist mein Lieblingslied.", and 0.600 for the same
    /// shape with a different title.
    ///
    /// At 0.6 the first read as a genuine translation and the turn committed
    /// to the FOREIGN side, showing German-into-German nonsense in the
    /// bubble's large line; the second passed by landing exactly ON the
    /// threshold, which is not a margin.
    ///
    /// **0.3 was tried on 2026-08-14 and REVERTED the same hour.** It fixed
    /// #32's half-translation (0.429) and immediately broke a genuine one:
    /// "A boy named Sue is my favorite song by Johnny Cash." → "Ein Junge
    /// namens Sue ist mein Lieblingslied von Johnny Cash." scores **exactly
    /// 0.300** — the proper nouns Sue / Johnny / Cash survive translation, as
    /// proper nouns do. At 0.3 that read as an echo, so the home session was
    /// judged never to have translated, direction never resolved, and the
    /// codes-veto dropped the turn entirely. No bubble at all, which is worse
    /// than #32's wrong-side bubble.
    ///
    /// That is #83's failure with a different sentence, and this file already
    /// named the shape: "Apple Google Netflix and Amazon" → "… und Amazon"
    /// scores 0.80 and is a correct translation.
    ///
    /// The lesson is about the KIND of number this is. A single overlap
    /// scalar cannot separate the two populations, because they interleave:
    /// a half-translation shares the home FUNCTION words it left alone (ist,
    /// mein), while a genuine translation shares the NAMES that survive it
    /// (Sue, Johnny, Cash). 0.429 against 0.300 is not a gap, it is two
    /// points, and any threshold between them is fitted to those two points.
    /// Fixing #32 needs a discriminator over WHICH tokens are shared, not a
    /// better cut-off. Pinned by L1.86/87 (still expected-to-fail) and
    /// L1.91.
    static let echoShareThreshold = 0.6
    /// Echo judgments need at least this many tokens on BOTH sides — a short
    /// identical output is a cognate, number, or name ("Navigator",
    /// "14 Euro"), which legitimately survives translation and must keep
    /// counting as one (#45's table; the swallowed turns of #23).
    ///
    /// TOKENS, not characters — deliberately unlike the floors above (#73):
    /// word counts travel across alphabetic scripts. Chinese does not
    /// whitespace-tokenize, so a zh output is ONE token and the echo
    /// machinery stays inert there — no new behavior for a shipped language
    /// rather than a wrong one. GitHub #38 tracks the calibration debt.
    static let echoMinTokens = 4

    // MARK: - The pair

    let home: Lang
    let partner: Lang

    init(home: Lang = .de, partner: Lang = .en) {
        self.home = home
        self.partner = partner
    }

    // MARK: - Per-turn state

    enum Direction: Equatable {
        /// Not the home language — the home session translated it. LEFT.
        case foreignSpoken
        /// The home language — the partner session translated it. RIGHT.
        case homeSpoken
    }
    private(set) var direction: Direction?
    private var firstPartnerOutputAt: Date?

    /// Which session's output is the real translation this turn (and whose
    /// audio should play).
    var translator: Lang? {
        switch direction {
        case .foreignSpoken: return home
        case .homeSpoken: return partner
        case nil: return nil
        }
    }

    /// The only translator whose PCM may be played. Pre-commit direction is
    /// deliberately reversible: later codes or transcripts can still
    /// invalidate it. Keeping this gate in pure turn state makes the
    /// irreversible audio decision testable and prevents the service from
    /// speaking a provisional translator.
    var committedTranslator: Lang? {
        hasCommitted ? translator : nil
    }

    /// Best guess at the spoken language from the codes — used for the veto
    /// and the straggler filter only, never for the bubble side.
    private(set) var spokenLang: Lang?

    /// R1 guard: set the moment a turn is committed to a bubble.
    private(set) var hasCommitted = false

    /// Why the last `commit` returned nil — diagnostics for the device log.
    private(set) var lastRejectReason: String?

    private var votes: [Lang: Int] = [:]
    private var firstVoteAt: Date?
    private var lastVoteAt: Date?
    /// Consecutive post-settle votes for one language ≠ the settled one.
    private var contradiction: (lang: Lang, count: Int)?
    private(set) var lastTurnEnd: Date?
    private var previousSpokenLang: Lang?
    /// Each session's OWN votes this turn, straggler-filtered and expired
    /// like the global tally, never settled — evidence, not a verdict. Kept
    /// per reporting session because WHO mis-hears is the signal (#83): in
    /// every measured mis-hearing turn the sessions disagree in a fixed
    /// pattern, and collapsing the votes into one pool is what hid it.
    ///
    /// Keyed by the NORMALIZED code, not by `Lang`: unmapped codes ("ja",
    /// "pt" — the measured self-target lie) are competing testimony from
    /// the same witness and must weigh against a home plurality (#84
    /// review; L1.54b). Expiring together with `votes` is not optional —
    /// the review reproduced stale partner-home votes from a dead context
    /// lifting a fresh foreign settle's veto (L1.55).
    private var sessionVotes: [Lang: [String: Int]] = [:]
    /// Whether the partner session had already reported HOME before the
    /// current global verdict first settled on the partner language. Two
    /// mapped partner-home strays that arrive after a real foreign settle are
    /// not the #75 crossed pattern and must never create a veto override.
    private var partnerHadHomeEvidenceAtPartnerSettle = false

    // MARK: - Echo detection (#75)

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Fraction of `output`'s tokens already present in this turn's input
    /// transcripts (both sessions' — either may hold the cleaner reading of
    /// the same speech). 0 when the output is empty.
    static func echoShare(of output: String, inputs: [Lang: String]) -> Double {
        let out = tokens(output)
        guard !out.isEmpty else { return 0 }
        var heard = Set<String>()
        for text in inputs.values { heard.formUnion(tokens(text)) }
        let hits = out.filter { heard.contains($0) }.count
        return Double(hits) / Double(out.count)
    }

    /// A long output that mostly repeats what was heard: the #45 tell,
    /// measured in the de↔es replays of #75. The model mis-hears home
    /// speech as a neighbouring language, "translates" that misreading back
    /// into the home language, and lands on the words it started from. A
    /// genuine translation does not come back as the input's own words.
    ///
    /// The token floor applies to BOTH sides, as documented since #75 but
    /// enforced only on the output side until the #77 review caught the gap:
    /// four output tokens judged against one heard token is a ratio built
    /// on nothing, not an echo.
    /// Function words of the HOME language that cannot be mistaken for the
    /// same word in English. Deliberately small, and admitted under
    /// `FillerWords`' rule: a token belongs here only if it is unambiguously
    /// a function word of this language AND not an English word AND not a
    /// name. `in`, `an`, `am`, `so`, `man`, `will`, `was`, `hat`, `die` are
    /// all excluded for exactly that reason — every one of them is also
    /// English, and `in` in particular is shared by two of the measured
    /// FOREIGN turns ("Apple and Google are both **in** California").
    ///
    /// German only. The other home languages return an empty set, so the
    /// rule below is inert for them — no new behaviour for a shipped
    /// language rather than untested behaviour. Populating them needs the
    /// same kind of measured corpus German now has (#32).
    static func homeFunctionWords(for home: Lang) -> Set<String> {
        switch home {
        case .de:
            return ["ist", "sind", "war", "waren", "mein", "meine", "meinen",
                    "meinem", "und", "nicht", "ich", "wir", "ihr", "der",
                    "das", "den", "dem", "des", "ein", "eine", "einen",
                    "einem", "kein", "keine", "für", "über", "auch", "noch",
                    "schon", "sehr", "mit", "von", "zum", "zur", "aus",
                    "nach", "bei", "vom", "beim", "dass", "weil", "aber",
                    "oder", "wenn"]
        default:
            return []
        }
    }

    /// Whether the home output reuses the home language's own function words
    /// from the input — the tell that the input contained home speech.
    ///
    /// **Why this is a separate signal and not a lower echo threshold.**
    /// `echoShare` provably cannot separate these populations: measured
    /// 2026-08-14, "Apple and Google are both in California." → "Apple und
    /// Google sind beide in Kalifornien." scores **0.429** and is genuinely
    /// FOREIGN, while "We will rock you. ist mein Lieblingslied." → "Wir
    /// werden euch rocken ist mein Lieblingslied." scores **0.429** and is
    /// genuinely HOME. Identical score, opposite truth, so no cut-off can be
    /// right about both — L1.92 pins that, and a threshold attempt that
    /// ignored it dropped a real turn on device the same day.
    ///
    /// WHICH tokens overlap separates them cleanly, because the two reuse
    /// different things. A genuine translation reuses names that survive
    /// translation — Apple, Google, Sue, Johnny, Queen — and cannot reuse
    /// German function words, since the input had none. A partial
    /// translation reuses exactly those, because it left the German alone.
    /// Measured over the ten labelled turns: **0 for every foreign turn, 2
    /// for every home turn.** Not a threshold on a continuum — a gap with
    /// nothing in it.
    ///
    /// The floor is two rather than one so a single cognate or transcription
    /// slip cannot flip a turn on its own.
    static func sharesHomeFunctionWords(_ output: String, inputs: [Lang: String],
                                        home: Lang) -> Bool {
        let function = homeFunctionWords(for: home)
        guard !function.isEmpty else { return false }
        var heard = Set<String>()
        for text in inputs.values { heard.formUnion(tokens(text)) }
        let sharedFunction = Set(tokens(output).filter { heard.contains($0) && function.contains($0) })
        return sharedFunction.count >= 2
    }

    static func isRoundTripEcho(_ output: String, inputs: [Lang: String]) -> Bool {
        var heard = Set<String>()
        for text in inputs.values { heard.formUnion(tokens(text)) }
        return tokens(output).count >= echoMinTokens
            && heard.count >= echoMinTokens
            && echoShare(of: output, inputs: inputs) >= echoShareThreshold
    }

    /// The partner session's own reading of this turn favors the HOME
    /// language — positive evidence that home speech was spoken, from the
    /// one witness with no stake in the mistake.
    ///
    /// This is the discriminator token overlap turned out not to be (#83:
    /// the tokeniser's handling of plurals and apostrophes was deciding who
    /// spoke). Measured across all 50 kept L3 replay logs (2026-08-07/08,
    /// de↔es and de↔en, 70 scored turns):
    ///
    ///  - Every mis-hearing round-trip turn — 8 of 8 — shows the CROSSED
    ///    pattern: the home session votes the partner language unanimously
    ///    (es×10) while the partner session, which heard the same German
    ///    correctly, votes HOME (de×8 against 1–2 strays).
    ///  - In all 50 genuinely-foreign turns the partner session NEVER reads
    ///    home: real Spanish → the es session votes es (30/30); real English
    ///    → the en session votes "ja", the measured self-target lie (20/20),
    ///    which maps to no pair language at all.
    ///
    /// So "the partner heard home" separates the shapes with nothing in the
    /// measured data on the wrong side of the line. The bar is a strict
    /// plurality among that session's own straggler-filtered votes —
    /// unmapped codes included as competitors — AND a quorum: one vote is
    /// not testimony. The #84 review then reproduced TWO current mapped
    /// partner-home strays committing an English echo RIGHT. The measured
    /// crossed pattern reaches three partner-home votes (eight in the kept
    /// full runs), while the reviewed failure has only two, so the floor is
    /// three. This property is still not enough to yield the foreign-vote
    /// veto by itself: the partner must already have reported home before
    /// that veto settled, and the home session must have the corroborated
    /// round-trip echo. No votes, no evidence — the veto then stands and the
    /// turn drops rather than guesses (#45's neither-side settles keep
    /// vetoing unconditionally for the same reason).
    static let partnerCorroborationQuorum = 3
    var partnerHeardHome: Bool {
        guard let tally = sessionVotes[partner],
              let homeCount = tally[home.rawValue],
              homeCount >= Self.partnerCorroborationQuorum else { return false }
        return tally.allSatisfy { $0.key == home.rawValue || $0.value < homeCount }
    }

    /// Why direction is what it is, in one line, for a device log (#32).
    ///
    /// The log says `direction → home` or nothing at all; it never says
    /// which of several mutually exclusive reasons produced that. On device
    /// (2026-08-14) a short German sentence opening with an English song
    /// title committed to the FOREIGN side twice, and the log could not
    /// distinguish "the codes settled on the partner, so the veto barred
    /// home" from "the home session produced a real translation, which is
    /// read as proof of foreign speech" from "no plurality inside the
    /// settle window". Those want opposite fixes.
    ///
    /// State lives here, so the summary is built here rather than
    /// reconstructed by a caller that would have to be given access to
    /// everything. Read-only and allocation-light; nothing decides on it.
    var decisionSummary: String {
        let global = votes
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)×\($0.value)" }
            .joined(separator: ",")
        let perSession = sessionVotes
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { session, tally in
                let inner = tally.sorted { $0.key < $1.key }
                    .map { "\($0.key)×\($0.value)" }.joined(separator: "/")
                return "\(session.rawValue)[\(inner)]"
            }
            .joined(separator: " ")
        return "settled=\(spokenLang?.rawValue ?? "none") "
            + "direction=\(direction.map { $0 == .homeSpoken ? "home" : "foreign" } ?? "nil") "
            + "votes=\(global.isEmpty ? "-" : global) "
            + "sessions=\(perSession.isEmpty ? "-" : perSession) "
            + "partnerHeardHome=\(partnerHeardHome) "
            + "crossed=\(homeSettleWithCrossedEvidence)"
    }

    /// The code-only half of the crossed pattern. This is deliberately
    /// stronger than `partnerHeardHome`: late partner-session noise cannot
    /// rewrite a foreign verdict it never helped form.
    private var partnerHasCurrentCrossedEvidence: Bool {
        spokenLang == partner
            && partnerHadHomeEvidenceAtPartnerSettle
            && partnerHeardHome
    }

    /// The mirror of `partnerHeardHome`: the HOME session's own votes favour
    /// the partner language, by the same strict-plurality-plus-quorum bar.
    /// This is the mis-hearing half of #75 — the session that reads German as
    /// Spanish and settles the codes on it.
    var homeHeardPartner: Bool {
        guard let tally = sessionVotes[home],
              let partnerCount = tally[partner.rawValue],
              partnerCount >= Self.partnerCorroborationQuorum else { return false }
        return tally.allSatisfy { $0.key == partner.rawValue || $0.value < partnerCount }
    }

    /// Two independent witnesses agree the HOME language was spoken: the
    /// pooled codes settled on home, and the partner session's own votes say
    /// home too, by the same quorum that governs every other use of that
    /// evidence.
    ///
    /// Measured on device 2026-08-10, build 2.3.48, one German turn. The
    /// codes settled on `de` 2.0s in and never moved; the partner session
    /// reported home nine times; the home session reported the partner
    /// language nine times — its own mis-hearing, the #75 shape. Yet
    /// `noteOutputs` consults `homeIsRealTranslation` FIRST, and that
    /// size-ratio judgement kept declaring the home session's echo a real
    /// translation as it streamed. Direction flipped six times in four
    /// seconds — foreign, home, foreign, home, foreign, home — before commit
    /// landed it correctly. The bubble was right and no audio played early
    /// (the committed-audio gate held), but the live line changed sides six
    /// times while the speaker was still talking.
    ///
    /// So the home session's output cannot outrank this. What it may not do
    /// is mistake ONE witness for two. The pooled settle is not independent
    /// of `partnerHeardHome`: `spokenLang` is derived from a tally that
    /// already contains the partner session's votes, so a partner session
    /// emitting a quorum of stray home codes and nothing else satisfies both
    /// halves by itself — it carries the pooled tally to home AND clears the
    /// quorum, with the same three votes. Requiring only those two committed
    /// an ordinary foreign turn as Heiko's own bubble (L1.64e, caught in
    /// review of #47).
    ///
    /// Independence comes from the HOME session's own reading, which no
    /// amount of partner noise can forge: the full crossed shape, each
    /// session reporting the other's language by its own strict plurality
    /// and quorum. That is what the device turn had, and it is the #75
    /// pattern this evidence was gathered for.
    ///
    /// Deliberately NOT "a home settle wins": L1.20 is a measured case where
    /// the codes lie about home and the home session's substantial
    /// translation is right to beat them. There the home session is reading
    /// HOME, not the partner language, so the crossed shape never forms and
    /// that path is untouched (L1.64c).
    private var homeSettleWithCrossedEvidence: Bool {
        spokenLang == home && homeHeardPartner && partnerHeardHome
    }

    /// The crossed mis-hearing shape itself: each session's own votes name the
    /// OTHER side's language. Both witnesses, no claim about where the settle
    /// landed.
    ///
    /// `homeSettleWithCrossedEvidence` is this same pair of witnesses narrowed
    /// to a home settle, because its job is to rescue a home commit from a
    /// foreign veto — one direction only. Naming the shape separately is what
    /// lets the other direction be reasoned about at all: measured on device
    /// 2026-08-18 (#125), both witnesses fired, the settle landed on the
    /// partner, and every guard that consumes them sat out because each is
    /// gated on a home settle.
    var crossedEvidence: Bool { homeHeardPartner && partnerHeardHome }

    /// Set by `commit` when it refused to pick a side because the evidence
    /// contradicted itself, rather than because something was missing.
    ///
    /// Typed, and deliberately not read off `lastRejectReason`: that string is
    /// for the log, and #28 established that copy must never be a control
    /// channel — the view picked a colour by spelling once and rewording the
    /// text silently changed behaviour. A caller deciding whether to ask the
    /// speaker to repeat needs a fact, not a phrase.
    private(set) var abstained = false

    /// A foreign-language veto may yield only for the full measured crossed
    /// shape. A high-overlap home output is not used to guess a side; here it
    /// verifies the specific mis-hearing mechanism that makes the global
    /// foreign verdict suspect. Partner codes or overlap alone were both
    /// proven unsafe by #83.
    private func partnerEvidenceOverridesForeignVeto(outputs: [Lang: String],
                                                      inputs: [Lang: String]) -> Bool {
        guard partnerHasCurrentCrossedEvidence else { return false }
        let homeText = (outputs[home] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isRoundTripEcho(homeText, inputs: inputs)
    }

    // MARK: - Direction (the authoritative signal)

    /// Did the home session really translate, or is this a false start?
    /// Judged by substance against the partner session — shared by the live
    /// path and commit so they can never disagree about the side.
    ///
    /// The absolute floor exists to stop false starts ("Ich") from deciding
    /// a turn. But when the codes have settled on a NON-home language, a
    /// home translation is exactly what's expected, and even a tiny one is
    /// real — measured 2026-07-29: a spoken number's translation "14 Euro"
    /// (7 chars) fell under the 8-char floor and the turn was swallowed.
    /// The floor applies only while the codes don't corroborate.
    ///
    /// Corroborated, there are two cases, and they are deliberately NOT
    /// symmetric:
    ///
    /// - **Nothing echoed** — nothing to weigh the home output against, and
    ///   the codes are the only evidence there is. Any non-empty output is
    ///   accepted, as it always has been. A floor here would swallow `"Ja"`
    ///   (2) and `"Nein"` (4) — real answers, and the swallowed-turn failure
    ///   this whole area exists to prevent.
    /// - **The partner echoed** — there IS something to weigh against, so a
    ///   false start can be told from a translation, and
    ///   `minCorroboratedHomeOutput` (5) does that. It replaces
    ///   `minDecisiveHomeOutput` (8) here: 8 left "14 Euro" (7) — the measured
    ///   case #23 was filed for — still swallowed whenever the partner
    ///   echoed, and an echo is the common case for foreign speech.
    ///
    /// The asymmetry is the point. It is not an oversight to tidy up: a floor
    /// buys false-start rejection only where there is an echo to compare
    /// against, and costs real short answers where there is not. GitHub #23.
    static func homeIsRealTranslation(_ outputs: [Lang: String], inputs: [Lang: String],
                                      home: Lang, partner: Lang,
                                      spokenLang: Lang?, partnerHomeEvidence: Bool) -> Bool {
        func text(_ lang: Lang) -> String {
            (outputs[lang] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let homeText = text(home)
        guard !homeText.isEmpty else { return false }
        // The #75 failure: home speech misheard as a neighbouring language,
        // round-tripped back into the home words. Full-length, so every
        // size-based floor below reads it as a real translation (measured
        // ratio 1.1 in the failing replay). What no real translation shares
        // with it: the output IS the input, token for token.
        //
        // But overlap alone cannot carry that verdict (#83): a genuine
        // translation that preserves names, numbers, and cognates scores in
        // the same band — "Apple Google Netflix and Amazon" → "… und Amazon"
        // is 0.80 overlap and is exactly what a correct translation looks
        // like. The #77 review's measured consequence: with codes settled the
        // turn was dropped; with codes UNSETTLED it committed the foreign
        // sentence as Heiko's own bubble. High overlap counts as an echo only
        // when the mis-hearing it implies is corroborated by the partner
        // session's own reading of the turn (`partnerHomeEvidence`): an echo of
        // home speech requires home speech, and the 8 measured round-trip
        // turns all show the partner session hearing exactly that, while the
        // 50 genuinely-foreign turns never do.
        if partnerHomeEvidence, isRoundTripEcho(homeText, inputs: inputs) { return false }
        // #32: the home output reused the home language's own function words,
        // so the input contained home speech and this is at most a PARTIAL
        // translation — the model rendering a foreign fragment while leaving
        // the German alone. Same verdict as an echo: not evidence that the
        // speech was foreign. See `sharesHomeFunctionWords` for why this is a
        // separate signal rather than a lower echo threshold.
        if partnerHomeEvidence, sharesHomeFunctionWords(homeText, inputs: inputs, home: home) {
            return false
        }
        let partnerCount = text(partner).count
        if partnerCount > 0 {
            // Plenty long relative to the echo — decisive on its own.
            if Double(homeText.count) / Double(partnerCount) >= Self.floors(for: home).ratio { return true }
            // The ratio failed, but settled non-home codes can still rescue a
            // SHORT genuine translation. This branch used to be unreachable
            // whenever the partner session echoed — and an echo is the common
            // case for foreign speech — so "14 Euro bitte" (13 chars) against a
            // 40-char echo scored 0.33 and was swallowed even with the codes
            // unanimously settled foreign. Same failure L1.26 was filed for,
            // just the half of the space the fix could not reach. GitHub #23.
            //
            // A floor still applies here, and that is the point: corroboration
            // must not readmit a false start ("Ich", 3 chars) sitting next to a
            // full partner echo — L1.22.
            //
            // But it is the CORROBORATED floor. Using the uncorroborated
            // 8-char one left "14 Euro" (7) — the measured case #23 was filed
            // for — still swallowed whenever the partner echoed. L1.31 passed
            // only because its example ("14 Euro bitte") is 13. GitHub #23.
            if let spoken = spokenLang, spoken != home {
                return homeText.count >= Self.floors(for: home).corroborated
            }
            return false
        }
        // No echo: no floor. Deliberate, and not an oversight — see the
        // asymmetry note above. There is nothing to weigh a false start
        // against here, and a floor would swallow "Ja" (2) and "Nein" (4).
        // L1.41b pins it.
        if let spoken = spokenLang, spoken != home { return true }
        return homeText.count >= Self.floors(for: home).decisive
    }

    /// Re-evaluate the turn's direction from everything the sessions have
    /// produced so far. Called as output streams in. `inputs` — the turn's
    /// input transcripts so far — feed the echo detection; commit receives
    /// the same pair, so the two judge the side from the same evidence.
    mutating func noteOutputs(_ outputs: [Lang: String], inputs: [Lang: String],
                              at now: Date = Date()) {
        // R1: a turn commits once, and its side is decided with it. Without
        // this, a late home-session transcript for the same turn could flip
        // `direction` — and therefore `translator` — after the bubble had been
        // emitted, while the service was flushing held audio for the session
        // that actually translated. GitHub #26.
        guard !hasCommitted else { return }
        // A home settle backed by the full crossed shape outranks the home
        // session's own output (see `homeSettleWithCrossedEvidence`). Without
        // it the size ratio re-decides on every streamed chunk and the
        // direction oscillates against two agreeing witnesses. L1.64.
        if !homeSettleWithCrossedEvidence,
           Self.homeIsRealTranslation(outputs, inputs: inputs, home: home, partner: partner,
                                      spokenLang: spokenLang,
                                      partnerHomeEvidence: partnerHeardHome) {
            direction = .foreignSpoken
            return
        }
        // The evidence no longer supports a provisional foreign direction —
        // clear it rather than latch it. The #77 review reproduced the latch
        // with run-6's own event order: the home session's first output
        // chunks arrive before the votes that expose them as an echo, so
        // streaming set `.foreignSpoken` and never revisited it; commit later
        // corrected the bubble, but the service had already flushed — and
        // wiped — held audio for the wrong session, so Heiko heard his own
        // German read back and the Spanish translation was discarded.
        // Pre-commit a direction is provisional by definition (the guard
        // above is what makes a COMMITTED one immutable, R1/#26); in the
        // measured run-6 timeline the crossed votes land ~5s before the
        // speaker stops, so the re-derive settles the true direction well
        // before any audio is released.
        if direction == .foreignSpoken { direction = nil }
        let partnerText = (outputs[partner] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partnerText.isEmpty else { return }
        if firstPartnerOutputAt == nil { firstPartnerOutputAt = now }
        // Same veto as commit: codes settled on a non-home language mean the
        // partner session's output is an echo of foreign speech, not a
        // translation of home speech (measured: English input → the en
        // session echoes the English back while de stays silent). Resolving
        // homeSpoken here would play that echo aloud as if it translated.
        //
        // The veto rests on that echo premise, so it yields when the premise
        // measurably fails: codes settled on the PARTNER language while the
        // complete crossed evidence says the turn was HOME speech — the
        // settle then came from the mis-hearing home session, not from the
        // speech (#75). The previous tell — partner output sharing few
        // tokens with what it heard — was #83: near-restatements of foreign
        // speech cleared it, and the partner's words landed in Heiko's
        // bubble on the say-so of plurals and apostrophes. Settles on a
        // language that is NEITHER side still veto unconditionally —
        // nothing on screen could be trusted there.
        let partnerVouches = partnerEvidenceOverridesForeignVeto(outputs: outputs, inputs: inputs)
        let vetoBarsHome = !(spokenLang == nil || spokenLang == home || partnerVouches)
        // BOTH provisional directions re-derive, not just foreign (#84
        // review): a homeSpoken resolved before the codes arrived must
        // clear when a late foreign settle arms the veto — otherwise
        // `translator` keeps naming the partner session, and the service
        // flushes (and deletes) held audio for an echo that commit is
        // about to reject. L1.56.
        if direction == .homeSpoken, vetoBarsHome { direction = nil }
        if direction == nil, !vetoBarsHome,
           let since = firstPartnerOutputAt,
           now.timeIntervalSince(since) >= Self.homeSilenceConfirmDelay {
            direction = .homeSpoken
        }
    }

    // MARK: - Language codes (veto and straggler filter only)

    /// `from` names the SESSION that reported the code, not the language it
    /// reported — the pairing is the evidence (#83). The global tally below
    /// still pools every vote for the settle; the per-session record feeds
    /// the crossed-evidence gate, and stragglers are filtered out of both by
    /// the same rule.
    ///
    /// A settled guess expires too. The previous implementation ran expiry
    /// only while `spokenLang` was nil, leaving a settled old turn's
    /// partner-home evidence available to override a later foreign veto.
    private mutating func expireVoteContextIfNeeded(at now: Date) {
        guard let last = lastVoteAt,
              now.timeIntervalSince(last) > Self.voteExpiry else { return }
        votes = [:]
        sessionVotes = [:]
        firstVoteAt = nil
        lastVoteAt = nil
        spokenLang = nil
        contradiction = nil
        partnerHadHomeEvidenceAtPartnerSettle = false
    }

    @discardableResult
    mutating func noteInputLanguage(_ code: String, from session: Lang,
                                    at now: Date = Date()) -> Lang? {
        let c = code.lowercased()
        let spoken = Lang.allCases.first { c.hasPrefix($0.rawValue) }
        if let spoken,
           let ended = lastTurnEnd, now.timeIntervalSince(ended) < Self.staleCodeGrace,
           spoken == previousSpokenLang {
            return nil
        }
        // Any nonempty language code is context traffic. Unmapped codes are
        // still testimony, so they must not keep a dead context alive, nor
        // should fresh ones inherit an old tally.
        expireVoteContextIfNeeded(at: now)
        guard let spoken else {
            // Unmapped codes ("ja"/"pt", the self-target lie) cast no global
            // vote, but they ARE testimony from this session and compete in
            // its tally (L1.54b) — a home plurality must beat them.
            let key = String(c.prefix { $0.isLetter })
            if !key.isEmpty {
                sessionVotes[session, default: [:]][key, default: 0] += 1
                lastVoteAt = now
            }
            return nil
        }
        let partnerHadHomeBeforeThisVote =
            (sessionVotes[partner]?[home.rawValue] ?? 0) > 0
        // Tallied before the settle logic, not after: post-settle votes keep
        // accumulating here. The crossed pattern spans the whole turn
        // (measured: es×10 against de×8 in run 6), and the settle happens
        // ~1.5s in — cutting the record off there would leave the partner's
        // testimony mostly unheard.
        sessionVotes[session, default: [:]][spoken.rawValue, default: 0] += 1
        lastVoteAt = now
        if let settled = spokenLang {
            if spoken == settled {
                contradiction = nil
                return settled
            }
            // A partner-session report of HOME cannot, by itself, overturn a
            // global PARTNER settle. That is the exact shape of the #83
            // failure: the partner can read its own translated/home text
            // back as HOME after the home session has already (incorrectly)
            // settled the turn on the partner language. Keep it as
            // session-local evidence for the independently guarded crossed
            // pattern, but never let that same late evidence rewrite the
            // global verdict. A HOME-session contradiction is still allowed
            // to overturn this settle (L1.25), because it is an independent
            // witness rather than the potentially echoed partner stream.
            if settled == partner, spoken == home, session == partner {
                // Decline to COUNT it — but leave the counter alone. Clearing
                // it here erased the HOME session's own accumulated
                // contradiction, and the two streams interleave, so a home
                // vote followed by a partner vote reset the tally on every
                // other event and it could never reach `overturnVotes`.
                //
                // Measured on device 2026-08-14: pure German, transcribed
                // correctly and identically by both sessions, translated
                // correctly by the partner session — and thrown away, because
                // the codes had settled `en` on the opening three votes and
                // nine home `de` votes could never overturn it
                // (`sessions=de[de×9/en×3] en[de×9/en×3]`, four rejections, no
                // bubble at all). Reproduced in pure logic: six home votes
                // alone overturn; the same six interleaved with partner votes
                // do not.
                //
                // #83's rule is preserved exactly — a partner-only stream of
                // home reports still never overturns, because it still never
                // increments. Only the erasure goes.
                return nil
            }
            // The settle is not immutable: a run of unanimous disagreement
            // means the settle itself was wrong (stragglers), not the codes.
            if contradiction?.lang == spoken {
                contradiction = (spoken, contradiction!.count + 1)
            } else {
                contradiction = (spoken, 1)
            }
            if contradiction!.count >= Self.overturnVotes {
                spokenLang = spoken
                contradiction = nil
                partnerHadHomeEvidenceAtPartnerSettle =
                    spoken == partner && partnerHadHomeBeforeThisVote
                return spoken
            }
            return nil
        }
        votes[spoken, default: 0] += 1
        if firstVoteAt == nil { firstVoteAt = now }
        if now.timeIntervalSince(firstVoteAt ?? now) >= Self.settleWindow,
           let winner = pluralityVote() {
            spokenLang = winner
            partnerHadHomeEvidenceAtPartnerSettle =
                winner == partner && partnerHadHomeBeforeThisVote
            return winner == spoken ? winner : nil
        }
        return nil
    }

    /// The leading language, or nil when there isn't one.
    ///
    /// A tie has no winner. The old `count > best` while iterating
    /// `Lang.allCases` silently broke ties by declaration order, so a 2-2 vote
    /// settled on whichever language happens to come first in the enum — and a
    /// settle arms the commit veto, so an arbitrary one can swallow a turn.
    /// "The codes don't agree yet" is exactly what `spokenLang == nil` means,
    /// so a tie simply doesn't settle; the next vote breaks it. GitHub #26.
    ///
    /// (Both callers reach this only while `spokenLang` is nil — the settled
    /// branch of `noteInputLanguage` returns before it, and `endTurn` uses
    /// `spokenLang ?? pluralityVote()` — so there is no incumbent to prefer.)
    private func pluralityVote() -> Lang? {
        var best: (lang: Lang, count: Int)?
        var tied = false
        for lang in Lang.allCases {
            let count = votes[lang, default: 0]
            guard count > 0 else { continue }
            if count > (best?.count ?? 0) {
                best = (lang, count)
                tied = false
            } else if count == best?.count {
                tied = true
            }
        }
        return tied ? nil : best?.lang
    }

    // MARK: - Transcript

    /// The transcript to trust: the translator session's (its target never
    /// equals the spoken language, so it avoids the garbage-transcript
    /// quirk — measured: katakana for plain English), else the longest.
    func bestTranscript(from inputs: [Lang: String]) -> String {
        if let t = translator, let text = inputs[t],
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        var best = ""
        for lang in Lang.allCases {
            let text = inputs[lang] ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count
                > best.trimmingCharacters(in: .whitespacesAndNewlines).count {
                best = text
            }
        }
        return best
    }

    // MARK: - Commit

    struct Bubble: Equatable {
        let original: String
        let translation: String
        /// Home language spoken → right side; anything else → left.
        let isHome: Bool
    }

    /// The SPEC §5.1 commit gate. A bubble always carries a home-language
    /// line: foreign speech pairs its transcript with the home translation;
    /// home speech pairs its transcript with the partner translation. A turn
    /// whose codes settled on something that was never translated commits
    /// nothing rather than guessing a side.
    mutating func commit(inputs: [Lang: String], outputs: [Lang: String]) -> Bubble? {
        lastRejectReason = nil
        abstained = false
        guard !hasCommitted else { lastRejectReason = "already committed (R1)"; return nil }

        func text(_ lang: Lang) -> String {
            (outputs[lang] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // #125: the full crossed shape, with the settle on the PARTNER.
        //
        // Both witnesses say the sessions swapped languages, so nothing this
        // turn produced identifies who spoke: the transcript attributed to the
        // speaker is the other language, and committing it puts words on
        // screen that nobody said. Measured on device 2026-08-18, three
        // identical turns, every individual signal reporting correctly.
        //
        // This is a refusal, not a rejection. The other `return nil` paths
        // mean something is MISSING and may still arrive, which is why the
        // deferral machinery retries them. Here the evidence is present and
        // contradicts itself; waiting cannot improve it, and the honest
        // outcome is to say so and let the speaker repeat (#152).
        //
        // Deliberately not applied when `partnerEvidenceOverridesForeignVeto`
        // holds: that is the measured #75/#83 case where this same evidence
        // plus a round-trip echo resolves HOME correctly, and the home branch
        // below already handles it. Abstaining first would trade a working
        // rescue for a shrug.
        // Crossed codes and a partner settle are NOT enough on their own to
        // call a turn untrustworthy: L1.51 is exactly that shape and commits
        // foreign correctly (a Spanish speaker saying a name, the home session
        // echoing it). What separates the two is whether the home session
        // produced an input transcript at all.
        //
        // When it did, both sessions have described the SAME audio and
        // labelled it as each other's language — two contradictory accounts of
        // one utterance, which is the #125 swap. When it did not, there is only
        // one account and nothing contradicts it.
        let homeHeardSomething = !(inputs[home] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let partnerHeardSomething = !(inputs[partner] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if crossedEvidence, spokenLang == partner,
           homeHeardSomething, partnerHeardSomething,
           !partnerEvidenceOverridesForeignVeto(outputs: outputs, inputs: inputs) {
            direction = nil
            abstained = true
            lastRejectReason = "abstained: sessions transcribed each other's languages (#125)"
            return nil
        }

        // Same gate as `noteOutputs`, and here for the same reason the two
        // share `homeIsRealTranslation` at all: the live line and the
        // committed bubble must not be able to disagree about the side
        // (L1.47g's doctrine). L1.64b.
        if !homeSettleWithCrossedEvidence,
           Self.homeIsRealTranslation(outputs, inputs: inputs, home: home, partner: partner,
                                      spokenLang: spokenLang,
                                      partnerHomeEvidence: partnerHeardHome) {
            // Set before reading the transcript — `bestTranscript` follows
            // `translator`, which follows `direction` — and CLEARED, not
            // restored, if this commit ends up rejecting. A nil bubble decided
            // nothing, and leaving a direction behind reports a side for a turn
            // that produced none, which `translator` then hands the service as
            // the session whose held audio to play.
            //
            // Restoring the previous value was not enough: by the time
            // `commit` runs, streaming `noteOutputs` has usually already set a
            // provisional direction, so "put it back" put the ghost back. The
            // first version of this fix passed its own test only because the
            // test called `commit` on a fresh turn. Caught in review of #26.
            //
            // Safe to clear outright: no *recoverable* rejection reaches here
            // (codes-veto and "no session produced any translation" both return
            // above, untouched), so every rejection that clears is terminal and
            // followed by `endTurn`. And a direction that streaming evidence
            // really supports is re-derived by the next `noteOutputs`.
            direction = .foreignSpoken
            let original = FillerWords.strip(bestTranscript(from: inputs), for: partner)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = FillerWords.strip(text(home), for: home)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, !translation.isEmpty else {
                direction = nil
                lastRejectReason = "foreign branch: empty \(original.isEmpty ? "original" : "translation")"
                return nil
            }
            hasCommitted = true
            return Bubble(original: original, translation: translation, isHome: false)
        }

        // Home session quiet ⇒ home language spoken — unless the codes say
        // otherwise, in which case the home translation we'd need never
        // arrived and there is nothing legal to show. Same yield as
        // `noteOutputs`: codes settled on the PARTNER language while the
        // complete crossed evidence says HOME means the settle came from
        // the mis-hearing home session, not from the speech (#75).
        if let guess = spokenLang, guess != home,
           !partnerEvidenceOverridesForeignVeto(outputs: outputs, inputs: inputs) {
            // A veto rejection decided nothing — clear any provisional
            // direction so `translator` names no session while the deferral
            // machinery waits (the #84 review's audio-flush sequence; same
            // doctrine as the branch-internal clears, L1.36 family).
            direction = nil
            lastRejectReason = "codes-veto: settled \(guess.rawValue), home session never translated"
            return nil
        }
        let partnerText = text(partner)
        guard !partnerText.isEmpty else {
            lastRejectReason = "no session produced any translation"
            return nil
        }
        direction = .homeSpoken
        let original = FillerWords.strip(bestTranscript(from: inputs), for: home)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = FillerWords.strip(partnerText, for: partner)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !translation.isEmpty else {
            direction = nil
            lastRejectReason = "home branch: empty \(original.isEmpty ? "original" : "translation")"
            return nil
        }
        hasCommitted = true
        return Bubble(original: original, translation: translation, isHome: true)
    }

    /// Reset per-utterance state. If this turn contained anything, start the
    /// straggler grace window against its language.
    mutating func endTurn(at now: Date = Date()) {
        // `firstPartnerOutputAt` belongs in this list: it is reset below, so
        // leaving it out meant an echo-only turn (partner session echoes
        // foreign speech; no codes, no direction, no commit) counted as an
        // empty turn. `lastTurnEnd` was never stamped, the next turn's
        // straggler grace was never armed, and that echo's late codes arrived
        // as fresh votes for the following turn. GitHub #26.
        if spokenLang != nil || direction != nil || hasCommitted
            || !votes.isEmpty || firstPartnerOutputAt != nil {
            lastTurnEnd = now
            previousSpokenLang = spokenLang ?? pluralityVote()
        }
        spokenLang = nil
        direction = nil
        firstPartnerOutputAt = nil
        hasCommitted = false
        votes = [:]
        sessionVotes = [:]
        partnerHadHomeEvidenceAtPartnerSettle = false
        firstVoteAt = nil
        lastVoteAt = nil
        contradiction = nil
    }
}
