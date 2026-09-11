import XCTest
@testable import HeikoTranslate

/// L1.27 — **Everything Heiko can see is German.**
///
/// Found the hard way (2026-07-30): the one action he would ever be asked to
/// perform from Germany — sending the diagnostic log — sat three taps deep
/// behind a button reading "Share diagnostic log", in an app whose entire
/// point is that its user speaks no English. Nothing caught it, because a
/// wrong-language string compiles perfectly.
///
/// This test reads the actual source of the Heiko-facing views and asserts
/// that the set of user-visible string literals is exactly the reviewed set
/// below. It is deliberately a **golden inventory** rather than a
/// German-vs-English heuristic: German and English share too many short words
/// ("in", "was", "war", "also") for a word-list check to be trustworthy, and a
/// check you cannot trust gets muted. Any new or edited string fails here
/// until a human looks at it and decides — which is the whole point.
///
/// (The old CostSheet — developer cost detail in English — was deleted by
/// decision on 2026-08-12, GitHub #7: costs are checked in the provider's
/// console. CostTracker still counts, invisibly. The one
/// thing in it that Heiko might need is surfaced one level up, in German.
final class GermanUITests: XCTestCase {

    /// Every user-visible literal in the views Heiko actually uses.
    /// Sorted. If this list changes, say why in the commit.
    private let reviewedStrings: Set<String> = [
        // ContentView
        // The gear is gone: the top pill is the two flags of the current
        // language pair, with an `ellipsis` SF Symbol between them. No user
        // -visible literal at all now — only the German accessibility label.
        "Einstellungen",                          // accessibility label
        // LanguageSettingsSheet. The redesign dropped four of these: the sheet
        // title "Sprachen", the search field "Sprache suchen …", and the two
        // wheel labels "Gesprächspartner" / "Zuhause" — the selected language
        // now sits in a chat bubble on the side it will occupy, which says the
        // same thing without a word of German-as-instructions.
        "Fertig",
        "Nutzung",
        // The two ends of the text-size slider. A letterform, not a word —
        // same standing as the flags: it means the same thing in every
        // language, which is exactly why the design uses it instead of a label.
        "A",
        // Reached the screen without ever passing this review, because it is
        // wrapped in String(format:) and the old pattern could not see past
        // the wrapper. Checked now: German, and the interpolation is a number.
        // GitHub #5. Shortened with the redesign (approved by Georg
        // 2026-08-06) from "%.0f Min gehört · %.0f Min gesprochen" — one
        // number instead of two, and the word spelled out.
        "%.0f Minuten gesprochen",
        "Protokoll an Georg senden",
        // ConversationViewModel — status line, hints and warnings
        "Verbinde…",
        "Verstehe",
        "Übersetze",
        "Mikrofon pausiert",
        "Zum Sprechen antippen",
        // Reworded with GitHub #25: the one button now opens Settings in this
        // state, so the copy says what tapping does instead of sending Heiko to
        // hunt through a Settings app he cannot read.
        "Kein Mikrofonzugriff. Zum Öffnen der Einstellungen antippen.",
        "Mikrofon konnte nicht gestartet werden.",
        "Mikrofon ist aus — bitte antippen.",
        "Verbindungsfehler. Bitte nochmal versuchen.",
        "Schlechte Verbindung — die Übersetzung kann darunter leiden.",
        "Keine Antwort vom Server — bitte Internetverbindung prüfen.",
        "Keine Internetverbindung.",
        // Added with GitHub #28. The app now resumes on its own after an
        // interruption iOS declined to mark resumable — an alarm or a timer —
        // rather than sitting silently muted, so it has to SAY that the
        // microphone reopened without a tap. Wording approved by Georg
        // 2026-08-05.
        "Mikrofon wieder aktiv — die Übersetzung läuft weiter.",
        // The revoked-key sentence (GitHub #9): only shown once a REST probe
        // has confirmed API_KEY_INVALID, at which point updating is the only
        // action that can ever work — the button opens the update page, and
        // the copy follows the micDenied pattern of saying what the tap does.
        // CANDIDATE: written 2026-08-12, Georg's on-device check pending.
        "Diese Version der App funktioniert nicht mehr. Zum Aktualisieren antippen.",
    ]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/GermanUITests.swift
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // repo root
    }

    /// Literals that reach the screen. Dynamic interpolations are skipped —
    /// what they interpolate (language display names) is covered by TurnLogic.
    private func userFacingStrings(in file: String) throws -> Set<String> {
        let url = repoRoot.appendingPathComponent("HeikoTranslate/\(file)")
        let source = try String(contentsOf: url, encoding: .utf8)
        let calls = "Text|Label|Button|TextField|navigationTitle|accessibilityLabel"
        // The literal does NOT have to sit immediately after the opening
        // paren. `Text(String(format: "…", x))` and `Text(verbatim: "…")` both
        // reach the screen, and the original pattern — call, `(`, quote — saw
        // neither, because what follows `Text(` there is an identifier or a
        // label. That is how "%.0f Min gehört · %.0f Min gesprochen" shipped
        // without ever passing through this review. So allow one optional
        // wrapping call and one optional argument label in between.
        //
        // This is the guardrail that is supposed to make it impossible to add
        // English text Heiko cannot read; a hole in it is worse than no
        // guardrail, because it reads as coverage. GitHub #5.
        let wrapper = #"(?:[A-Za-z_][A-Za-z0-9_]*\s*\(\s*)?"#
        let label = #"(?:[a-z][A-Za-z0-9_]*\s*:\s*)?"#
        let literal = #""((?:[^"\\]|\\.)*)""#
        let regex = try NSRegularExpression(
            pattern: "(?:\(calls))\\(\\s*\(wrapper)\(label)\(literal)"
        )
        let range = NSRange(source.startIndex..., in: source)
        var found: Set<String> = []
        for match in regex.matches(in: source, range: range) {
            guard let r = Range(match.range(at: 1), in: source) else { continue }
            let text = String(source[r])
            // Skip pure interpolations and SF Symbol names.
            if text.hasPrefix("\\(") || text.isEmpty { continue }
            found.insert(text)
        }
        return found
    }

    /// Strips `#if DEBUG` … `#endif` so simulator-only scaffolding — the
    /// seeded sample conversation and the demo replay used to film the case
    /// study — is not mistaken for shipping UI text.
    private func withoutDebugBlocks(_ source: String) -> String {
        var out: [Substring] = []
        var depth = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if DEBUG") { depth += 1; continue }
            if depth > 0 {
                if t.hasPrefix("#if") { depth += 1 }
                else if t.hasPrefix("#endif") { depth -= 1 }
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// ConversationViewModel hands its strings back from computed properties,
    /// so they are assigned or returned rather than passed to a view.
    private func viewModelStrings() throws -> Set<String> {
        let url = repoRoot.appendingPathComponent("HeikoTranslate/ConversationViewModel.swift")
        let source = withoutDebugBlocks(try String(contentsOf: url, encoding: .utf8))
        // No newlines inside the literal — otherwise the match runs away
        // across lines and swallows whole argument lists.
        let regex = try NSRegularExpression(pattern: #"(?:return|=|\?\?|:)\s*"((?:[^"\\\n]|\\.){4,})""#)
        let range = NSRange(source.startIndex..., in: source)
        var found: Set<String> = []
        for match in regex.matches(in: source, range: range) {
            guard let r = Range(match.range(at: 1), in: source) else { continue }
            let text = String(source[r])
            // Keys and identifiers are not user-facing.
            if text.hasPrefix("\\(") || text.contains(".") && !text.contains(" ") { continue }
            if text.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil { continue }
            found.insert(text)
        }
        return found
    }

    /// L1.43 — the GERMAN set is exactly what was reviewed.
    ///
    /// The strings live in `UIStrings` now rather than inline in the views, so
    /// this asserts against the real values instead of scanning source for
    /// them. That is strictly stronger: a scan can only see literals it knows
    /// how to find, and moving a string one level of indirection away used to
    /// make it invisible to the guardrail entirely.
    func testL1_43_theGermanSetIsTheReviewedSet() {
        let g = UIStrings.german
        XCTAssertEqual(g.connecting, "Verbinde…")
        XCTAssertEqual(g.hearing, "Verstehe")
        XCTAssertEqual(g.translating, "Übersetze")
        XCTAssertEqual(g.micPaused, "Mikrofon pausiert")
        XCTAssertEqual(g.tapToSpeak, "Zum Sprechen antippen")
        XCTAssertEqual(g.micDenied, "Kein Mikrofonzugriff. Zum Öffnen der Einstellungen antippen.")
        XCTAssertEqual(g.micFailed, "Mikrofon konnte nicht gestartet werden.")
        XCTAssertEqual(g.connectionError, "Verbindungsfehler. Bitte nochmal versuchen.")
        XCTAssertEqual(g.poorConnection, "Schlechte Verbindung — die Übersetzung kann darunter leiden.")
        XCTAssertEqual(g.noServerResponse, "Keine Antwort vom Server — bitte Internetverbindung prüfen.")
        XCTAssertEqual(g.offline, "Keine Internetverbindung.")
        XCTAssertEqual(g.micResumed, "Mikrofon wieder aktiv — die Übersetzung läuft weiter.")
        XCTAssertEqual(g.othersSpeak, "Andere sprechen")
        XCTAssertEqual(g.iSpeak, "Ich spreche")
        XCTAssertEqual(g.textSize, "Textgröße")
        XCTAssertEqual(g.done, "Fertig")
        XCTAssertEqual(g.usage, "Nutzung")
        XCTAssertEqual(g.minutesSpokenFormat, "%.0f Minuten gesprochen")
        XCTAssertEqual(g.sendLog, "Protokoll an Georg senden")
        XCTAssertEqual(g.sendLogSubtitleFormat, "Falls etwas nicht klappt · %@")
        // The privacy-policy row (#91). Approved by Georg 2026-08-13.
        // "Datenschutz" is the word German sites put on exactly this link.
        XCTAssertEqual(g.privacyPolicy, "Datenschutz")
        XCTAssertEqual(g.settingsLabel, "Einstellungen")
    }

    /// L1.44 — every language is complete, and none of them is secretly German.
    ///
    /// The struct's named fields mean the COMPILER already guarantees no
    /// missing field. What it cannot catch is a field filled in by copying the
    /// German line and forgetting to translate it, which is the realistic way
    /// a set goes wrong.
    func testL1_44_everyLanguageIsCompleteAndNotGerman() {
        let de = UIStrings.german
        // Endonyms must be distinct, or the home wheel shows two rows a native
        // cannot tell apart.
        XCTAssertEqual(Set(TurnLogic.Lang.allCases.map(\.endonym)).count,
                       TurnLogic.Lang.allCases.count, "two languages share an endonym")
        for lang in TurnLogic.Lang.allCases {
            let s = UIStrings.of(lang)
            let fields: [(String, String)] = [
                ("connecting", s.connecting), ("hearing", s.hearing),
                ("translating", s.translating), ("micPaused", s.micPaused),
                ("tapToSpeak", s.tapToSpeak), ("micDenied", s.micDenied),
                ("micFailed", s.micFailed), ("connectionError", s.connectionError),
                ("poorConnection", s.poorConnection), ("noServerResponse", s.noServerResponse),
                ("offline", s.offline), ("micResumed", s.micResumed),
                ("othersSpeak", s.othersSpeak), ("iSpeak", s.iSpeak),
                ("textSize", s.textSize),
                ("done", s.done), ("usage", s.usage),
                ("minutesSpokenFormat", s.minutesSpokenFormat), ("sendLog", s.sendLog),
                ("sendLogSubtitleFormat", s.sendLogSubtitleFormat),
                ("privacyPolicy", s.privacyPolicy), ("settingsLabel", s.settingsLabel),
                ("startListeningLabel", s.startListeningLabel),
                ("stopListeningLabel", s.stopListeningLabel),
            ]
            for (name, value) in fields {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(lang.rawValue).\(name) is empty")
            }
            XCTAssertTrue(s.minutesSpokenFormat.contains("%.0f"),
                          "\(lang.rawValue) lost its number placeholder")
            // Without the placeholder the row silently drops the build number
            // — and the number under the share button is how Georg knows
            // which code produced the log he is about to be sent.
            XCTAssertTrue(s.sendLogSubtitleFormat.contains("%@"),
                          "\(lang.rawValue) lost its version placeholder")
            XCTAssertEqual(Set(s.languageNames.keys), Set(TurnLogic.Lang.allCases),
                           "\(lang.rawValue) does not name every language")

            // The endonym is what the HOME wheel shows — it must be this
            // language's own name, the thing a native scans for.
            XCTAssertEqual(lang.endonym, s.languageNames[lang],
                           "\(lang.rawValue) endonym must come from its own set")

            // Every language in the v1 set is a reader language (SPEC §3.0),
            // so every one of them owns a full set. The partner-only fallback
            // branch that used to sit here went with #30's Tagalog and
            // Vietnamese: there is no longer a language that reaches `of(_:)`
            // without a set of its own.
            guard lang != .de else { continue }
            // A handful of markers: if these still read German, the set was
            // copied rather than translated.
            XCTAssertNotEqual(s.micPaused, de.micPaused, "\(lang.rawValue) micPaused is still German")
            XCTAssertNotEqual(s.tapToSpeak, de.tapToSpeak, "\(lang.rawValue) tapToSpeak is still German")
            XCTAssertNotEqual(s.done, de.done, "\(lang.rawValue) done is still German")
        }
    }

    func testL1_27_noViewHardcodesUserFacingText() throws {
        var onScreen = try userFacingStrings(in: "ContentView.swift")
        onScreen.formUnion(try userFacingStrings(in: "LanguageSettingsSheet.swift"))
        onScreen.formUnion(try viewModelStrings())

        let unreviewed = onScreen.subtracting(reviewedStrings)
        XCTAssertTrue(unreviewed.isEmpty, """
            New or changed user-facing text found. Heiko speaks no English —
            check each of these is German, then add it to `reviewedStrings`:
            \(unreviewed.sorted().map { "  • \($0)" }.joined(separator: "\n"))
            """)
    }

    /// The log-sharing action is the one thing the user may be asked to do
    /// remotely. It must stay one tap from the language pill (which replaced
    /// the gear), and in German.
    func testL1_28_logSharingIsReachableAndGerman() throws {
        let sheet = try String(
            contentsOf: repoRoot.appendingPathComponent("HeikoTranslate/LanguageSettingsSheet.swift"),
            encoding: .utf8)
        XCTAssertTrue(sheet.contains("ShareLink"),
                      "the settings sheet must offer the log directly")
        // The literal moved into `UIStrings`; the sheet reads it from there.
        // Both halves still have to hold: the sheet must use the log string,
        // and that string must still be the reviewed German (L1.43 pins the
        // wording itself).
        XCTAssertTrue(sheet.contains("strings.sendLog"),
                      "the settings sheet must label the share action from UIStrings")
        XCTAssertEqual(UIStrings.german.sendLog, "Protokoll an Georg senden")
    }

    /// L1.79 — the privacy-policy row (#91). App Review 5.1.1(i) requires the
    /// policy link "within the app in an easily accessible manner"; the app's
    /// answer is a row on the language sheet, one tap from the pill, beside
    /// the log row and under the same reader-language rule. Same shape as
    /// L1.28: the sheet must offer the link, label it from UIStrings, and the
    /// destination must be the ONE canonical URL — the `www.` form the policy
    /// is published under (docs/privacy-policy.md) — so the row and App Store
    /// Connect can never point at different pages.
    func testL1_79_privacyPolicyRowIsReachableAndCanonical() throws {
        let sheet = try String(
            contentsOf: repoRoot.appendingPathComponent("HeikoTranslate/LanguageSettingsSheet.swift"),
            encoding: .utf8)
        XCTAssertTrue(sheet.contains("https://www.georgklock.com/heiko-translate-privacy"),
                      "the settings sheet must link the published policy, www. form")
        XCTAssertTrue(sheet.contains("strings.privacyPolicy"),
                      "the settings sheet must label the policy row from UIStrings")
        XCTAssertEqual(UIStrings.german.privacyPolicy, "Datenschutz")
    }
}
