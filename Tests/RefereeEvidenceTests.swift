import XCTest
import AVFoundation
@testable import HeikoTranslate

/// GitHub #135: the on-device language referee.
///
/// `RefereeEvidence` is the pure rule — the same code `Tools/lidprobe.sh` ran
/// over the TestAudio corpus on 2026-09-16 — and these cases pin what it is
/// entitled to claim: a side only when its transcriber was clearly more
/// confident AND heard words, and nothing whenever either side could not
/// testify. The measured shapes are used as inputs where they exist.
///
/// The I/O half is covered where L1 can reach it without loading a speech
/// model: the inert referee every pre-iOS 26 phone gets, and a source scan
/// that holds the on-device invariant (#135 §6).
final class RefereeEvidenceTests: XCTestCase {

    private typealias R = RefereeEvidence
    private typealias Reading = RefereeEvidence.Reading

    private func de(_ text: String, _ confidence: Double?, _ availability: R.Availability = .ready) -> Reading {
        Reading(lang: .de, availability: availability, text: text, confidence: confidence)
    }

    private func es(_ text: String, _ confidence: Double?, _ availability: R.Availability = .ready) -> Reading {
        Reading(lang: .es, availability: availability, text: text, confidence: confidence)
    }

    private let everyUnavailability: [R.Availability] = [
        .unsupportedOS, .unavailableOnDevice, .unsupportedLocale, .assetsNotInstalled, .failed("boom"),
    ]

    // MARK: - Verdict

    /// L1.116 — the measured home shape: German spoken, the German transcriber
    /// clearly more confident (de_short.wav on de↔es: 0.957 against 0.586).
    func testL1_116_clearlyMoreConfidentHomeNamesHome() {
        let e = R(home: de("Mir geht es gut, danke", 0.957), partner: es("Mirgit es gut, Danke", 0.586))
        XCTAssertEqual(e.verdict, .home)
    }

    /// L1.116b — and the mirror: es_short.wav, the Spanish transcriber at 0.849
    /// against the German one's 0.734. The rule does not privilege home.
    func testL1_116b_clearlyMoreConfidentPartnerNamesPartner() {
        let e = R(home: de("Donde está la estación de trren por favor.", 0.734),
                  partner: es("¿Dónde está la estación de tren? Por favor.", 0.849))
        XCTAssertEqual(e.verdict, .partner)
    }

    /// L1.116c — inside the margin, no side. en_entities.wav is the measured
    /// case: brand names are nobody's language, and the German transcriber was
    /// the MORE confident one (+0.035) on English speech. "Whichever is more
    /// confident" would have named the wrong side.
    func testL1_116c_withinTheMarginIsInconclusive() {
        let e = R(home: de("Apple, Google, Netflix and Amazon.", 0.880),
                  partner: es("Apple, Google, Netflix, and Amazon.", 0.845))
        XCTAssertEqual(e.verdict, .inconclusive)
        XCTAssertEqual(e.score.confidenceDelta!, 0.035, accuracy: 0.0001)
    }

    /// L1.116d — a silent side is not evidence for the other one. noise.wav:
    /// the German transcriber heard "you" at 0.744 and every partner produced
    /// nothing; the 2026-08-17 device run found the same "one side silent"
    /// rule wrong on 4 turns of 6.
    func testL1_116d_oneSilentSideIsInconclusive() {
        XCTAssertEqual(R(home: de("you", 0.744), partner: es("", nil)).verdict, .inconclusive)
        XCTAssertEqual(R(home: de("", nil), partner: es("hola", 0.99)).verdict, .inconclusive)
    }

    /// L1.116e — silence names nobody.
    func testL1_116e_neitherHeardWordsIsInconclusive() {
        XCTAssertEqual(R(home: de("", nil), partner: es("", nil)).verdict, .inconclusive)
        XCTAssertEqual(R(home: de(" .\n", 0.9), partner: es("", 0.1)).verdict, .inconclusive)
    }

    /// L1.116f — a side that could not run cannot testify, even with text and
    /// a confidence attached. Inert, never decisive (R8).
    func testL1_116f_anUnavailableSideMakesTheTurnInconclusive() {
        for unavailable in everyUnavailability {
            XCTAssertEqual(R(home: de("Mir geht es gut", 0.99),
                             partner: es("x", 0.01, unavailable)).verdict,
                           .inconclusive, "\(unavailable) must not leave the other side decisive")
            XCTAssertEqual(R(home: de("x", 0.01, unavailable),
                             partner: es("Estoy bien", 0.99)).verdict,
                           .inconclusive, "\(unavailable) must not leave the other side decisive")
        }
    }

    /// L1.116g — confidence without words does not win. de_loanwords.wav on
    /// de↔ko: the Korean transcriber returned "." with a confidence attached.
    func testL1_116g_aConfidentSideWithNoWordsCannotWin() {
        XCTAssertEqual(R(home: de(".", 0.95), partner: es("pero", 0.20)).verdict, .inconclusive)
    }

    /// L1.116h — the margin sits inside the gap the corpus measured, not at
    /// an edge of it: partner-spoken readings topped out at +0.035, home-spoken
    /// ones started at +0.201. Moving it outside that range needs a new
    /// measurement, which is the point of failing here.
    func testL1_116h_theMarginSitsInsideTheMeasuredGap() {
        XCTAssertGreaterThan(R.Thresholds.confidenceMargin, 0.035)
        XCTAssertLessThan(R.Thresholds.confidenceMargin, 0.201)
    }

    // MARK: - Scores

    /// L1.117 — the reported candidates, signed so positive favours home.
    func testL1_117_scoresAreSignedTowardsHome() {
        let s = R.score(home: de("abcdef", 0.9), partner: es("ab", 0.5))
        XCTAssertEqual(s.homeCharacters, 6)
        XCTAssertEqual(s.partnerCharacters, 2)
        XCTAssertEqual(s.confidenceDelta!, 0.4, accuracy: 0.0001)
        XCTAssertEqual(s.lengthBalance, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s.weightedBalance!, (5.4 - 1.0) / (5.4 + 1.0), accuracy: 0.0001)
        XCTAssertFalse(s.onlyOneSubstantive)
    }

    /// L1.117b — swapping the sides negates every signed score.
    func testL1_117b_scoresAreSymmetric() {
        let a = R.score(home: de("abcdef", 0.9), partner: es("ab", 0.5))
        let b = R.score(home: Reading(lang: .es, text: "ab", confidence: 0.5),
                        partner: Reading(lang: .de, text: "abcdef", confidence: 0.9))
        XCTAssertEqual(a.confidenceDelta!, -b.confidenceDelta!, accuracy: 0.0001)
        XCTAssertEqual(a.lengthBalance, -b.lengthBalance, accuracy: 0.0001)
        XCTAssertEqual(a.weightedBalance!, -b.weightedBalance!, accuracy: 0.0001)
    }

    /// L1.117c — a missing confidence is missing, not zero: the scores that
    /// need one are absent, and empty sides divide by nothing.
    func testL1_117c_missingConfidenceIsNotZero() {
        let s = R.score(home: de("abc", 0.9), partner: es("", nil))
        XCTAssertNil(s.confidenceDelta)
        XCTAssertNil(s.weightedBalance)
        XCTAssertEqual(s.lengthBalance, 1)
        XCTAssertTrue(s.onlyOneSubstantive)
        XCTAssertEqual(R.score(home: de("", nil), partner: es("", nil)).lengthBalance, 0)
    }

    /// L1.117d — only letters and digits are speech; "14 Euro" counts its
    /// digits, "." and whitespace count nothing.
    func testL1_117d_speechCharactersIgnorePunctuation() {
        XCTAssertEqual(de("Das kostet 14 Euro.", 0.9).speechCharacters, 15)
        XCTAssertEqual(de(" .\n", 0.9).speechCharacters, 0)
        XCTAssertFalse(de(" .\n", 0.9).isSubstantive)
        XCTAssertEqual(Reading(lang: .ko, text: "안녕하세요.").speechCharacters, 5)
    }

    // MARK: - Locales

    /// L1.118 — every app language has its own language-REGION locale, and
    /// the regions are the product's: US English, Mexican Spanish. The switch
    /// is exhaustive, so a fifth language breaks the build before this runs.
    func testL1_118_everyLanguageHasItsProductLocale() {
        let expected: [TurnLogic.Lang: String] = [.de: "de-DE", .en: "en-US", .es: "es-MX", .ko: "ko-KR"]
        XCTAssertEqual(Set(TurnLogic.Lang.allCases), Set(expected.keys))
        for lang in TurnLogic.Lang.allCases {
            XCTAssertEqual(R.localeIdentifier(for: lang), expected[lang])
        }
    }

    // MARK: - The inert referee

    /// L1.119 — what every phone without iOS 26 gets: no evidence before a
    /// pair starts, then every turn inconclusive with the reason on both sides
    /// of the right pair, and nothing after `stop`.
    func testL1_119_theInertRefereeIsAlwaysInconclusive() {
        let referee = InertLanguageReferee(reason: .unsupportedOS)
        XCTAssertNil(referee.turnEnded(), "no pair, no turn")

        referee.start(home: .de, partner: .ko)
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
                                      frameCapacity: 4800)!
        buffer.frameLength = 4800
        referee.append(buffer)

        for _ in 0..<2 {
            guard let e = referee.turnEnded() else { return XCTFail("a started referee reports every turn") }
            XCTAssertEqual(e.verdict, .inconclusive)
            XCTAssertEqual(e.reason, "unavailable")
            XCTAssertEqual(e.home.lang, .de)
            XCTAssertEqual(e.partner.lang, .ko)
            XCTAssertEqual(e.home.availability, .unsupportedOS)
            XCTAssertEqual(e.partner.availability, .unsupportedOS)
        }

        referee.stop()
        XCTAssertNil(referee.turnEnded())
    }

    /// L1.119b — the factory's referee is safe to hold and to tear down before
    /// it ever started: the service owns one from init, and its shared
    /// teardown runs on paths where audio never began.
    func testL1_119b_theFactoryRefereeIsSafeBeforeStart() {
        let referee = LanguageRefereeFactory.make(downloadsAllowed: { false })
        XCTAssertNil(referee.turnEnded())
        referee.stop()
        XCTAssertNil(referee.turnEnded())
        if #available(iOS 26.0, *) {
            XCTAssertTrue(referee is TranscriberReferee)
        } else {
            XCTAssertTrue(referee is InertLanguageReferee)
        }
    }

    // MARK: - On device only (#135 §6)

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/RefereeEvidenceTests.swift
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // repo root
    }

    /// Source with `//` comments removed, so documentation may name what the
    /// code must not use.
    private func code(_ path: String) throws -> String {
        try code(at: repoRoot.appendingPathComponent(path))
    }

    private func code(at url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let r = line.range(of: "//") else { return line }
            return line[..<r.lowerBound]
        }.joined(separator: "\n")
    }

    /// L1.120 — the referee cannot send audio off the phone. Its transcriber
    /// has no server mode; the Speech API that does — the recognizer whose
    /// on-device flag defaults to off — and any networking API are absent from
    /// the file. With either present, audio could reach Apple and the privacy
    /// policy, which names Google as the only recipient, would be untrue.
    func testL1_120_theRefereeUsesNoServerRecognitionPath() throws {
        let source = try code("HeikoTranslate/Services/LanguageReferee.swift")
        XCTAssertTrue(source.contains("SpeechTranscriber("), "sanity: the scan reads the referee's code")
        let forbidden = [
            "SFSpeechRecognizer", "SFSpeechRecognitionRequest", "SFSpeechAudioBufferRecognitionRequest",
            "SFSpeechURLRecognitionRequest", "recognitionTask", "requiresOnDeviceRecognition",
            "URLSession", "URLRequest", "NWConnection", "import Network", "WebSocket",
        ]
        for token in forbidden {
            XCTAssertFalse(source.contains(token), "LanguageReferee.swift must not use `\(token)` (#135 §6)")
        }
    }

    /// L1.120b — and nowhere else in the app either: the server-capable
    /// recognizer is not reintroduced beside the referee, and its on-device
    /// flag is never switched off anywhere.
    func testL1_120b_noServerCapableRecognizerAnywhereInTheApp() throws {
        let root = repoRoot.appendingPathComponent("HeikoTranslate")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "sanity: the scan found the app's sources")
        for file in files {
            let source = try code(at: file)
            for token in ["SFSpeechRecognizer", "SFSpeechAudioBufferRecognitionRequest",
                          "SFSpeechURLRecognitionRequest", "requiresOnDeviceRecognition = false"] {
                XCTAssertFalse(source.contains(token), "\(file.lastPathComponent) uses `\(token)` (#135 §6)")
            }
        }
    }
}
