import Foundation
import NaturalLanguage

// L3 replay through INTERPRETER mode (GitHub #135): the same recorded corpus
// L3 uses, but through ONE session that chooses the direction itself, with no
// TurnLogic arbitration underneath it.
//
//   Tools/l3interpreter.sh                 # the default order
//   Tools/l3interpreter.sh de_song_lead    # named cases
//
// WHY THE EXPECTATIONS TRANSLATE DIRECTLY
//
// L3 pins each case as (isHome, translator). `translator` is the session whose
// TARGET language produced the bubble — so the language that session speaks IS
// the expected output language. Interpreter mode has no sessions to choose
// between, but the correct output language is the same one, which makes the
// two harnesses comparable case by case without inventing a second standard.
//
// A pass here is NOT a pass of L3. L3 checks the app's arbitration, release
// timing and truncation rules; this checks one thing — whether a single
// session gets the direction right on the same audio. It is a comparison, not
// a replacement, and the L3 gate is untouched.
//
// Language of the output is judged with NLLanguageRecognizer, which is
// legitimate HERE and was not in #135's referee: the objection there was that
// a text classifier confirms whatever the wrong-language recogniser
// hallucinated. This classifies the model's own clean translation, where the
// language is the answer under test rather than corrupted evidence.

struct Case {
    let name: String
    let home: TurnLogic.Lang
    let partner: TurnLogic.Lang
    /// Expected output language per turn, in order — taken from L3's
    /// `translator` field for the same case.
    let expect: [TurnLogic.Lang]
}

let cases: [Case] = [
    Case(name: "en_short", home: .de, partner: .en, expect: [.de]),
    Case(name: "de_short", home: .de, partner: .en, expect: [.en]),
    Case(name: "es_short", home: .de, partner: .es, expect: [.de]),
    Case(name: "en_entities", home: .de, partner: .en, expect: [.de]),
    Case(name: "en_long", home: .de, partner: .en, expect: [.de]),
    // The #32 population: German that OPENS with an English song title. L3
    // keeps these as regression guards because the device flip does not
    // reproduce through synthesized audio; they are here for the same reason.
    Case(name: "de_song_lead", home: .de, partner: .en, expect: [.en]),
    Case(name: "de_song_lead_long", home: .de, partner: .en, expect: [.en]),
    Case(name: "en_song_cash", home: .de, partner: .en, expect: [.de]),
    Case(name: "en_band_queen", home: .de, partner: .en, expect: [.de]),
    Case(name: "en_apple_google", home: .de, partner: .en, expect: [.de]),
    Case(name: "en_series_ny", home: .de, partner: .en, expect: [.de]),
    // Two utterances, one stream: the direction must change WITHIN a session.
    Case(name: "de_after_en", home: .de, partner: .en, expect: [.de, .en]),
    Case(name: "de_after_es", home: .de, partner: .es, expect: [.de, .es]),
    // One utterance with an internal breath pause: ONE turn, not two.
    Case(name: "de_pause", home: .de, partner: .en, expect: [.en]),
    Case(name: "de_price_short", home: .zh, partner: .de, expect: [.zh]),
    // Nothing said means nothing spoken. A model that fills silence with
    // conversation is disqualified for this product however good its
    // translations are.
    Case(name: "silence", home: .de, partner: .en, expect: []),
    Case(name: "noise", home: .de, partner: .en, expect: []),
]

let defaultOrder = ["en_short", "de_short", "es_short", "en_entities",
                    "en_long", "de_after_en", "de_after_es", "de_pause",
                    "de_price_short", "silence", "noise"]

func detect(_ text: String) -> TurnLogic.Lang? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 1 else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(trimmed)
    guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
    return TurnLogic.Lang(rawValue: String(code.prefix(2)))
}

struct Turn {
    let text: String
    let first: TimeInterval
}

func run(_ testCase: Case, apiKey: String) -> (turns: [Turn], error: String?) {
    let pcm = loadWAV("TestAudio/\(testCase.name).wav")

    var turns: [Turn] = []
    var current = ""
    var currentFirst: TimeInterval?
    var errorText: String?
    var ready = false
    var audioEndedAt: Date?

    let q = DispatchQueue(label: "l3interpreter")
    let sem = DispatchSemaphore(value: 0)

    func closeTurn() {
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { turns.append(Turn(text: text, first: currentFirst ?? 0)) }
        current = ""
        currentFirst = nil
    }

    let session = GeminiLiveSession(
        mode: .interpreter(home: testCase.home.rawValue,
                           partner: testCase.partner.rawValue,
                           model: GeminiLiveSession.Mode.defaultInterpreterModel),
        apiKey: apiKey
    ) { event in
        q.async {
            switch event {
            case .setupComplete: ready = true; sem.signal()
            case .outputTranscript(let text):
                if currentFirst == nil, let ended = audioEndedAt {
                    currentFirst = Date().timeIntervalSince(ended)
                }
                current += text
            case .turnComplete: closeTurn()
            case .error(let message): errorText = message; sem.signal()
            default: break
            }
        }
    }
    session.connect()
    guard sem.wait(timeout: .now() + 20) == .success, q.sync(execute: { ready }) else {
        session.close()
        return ([], q.sync { errorText } ?? "no setupComplete in 20s")
    }

    var offset = 0
    while offset < pcm.count {
        let end = min(offset + 2048, pcm.count)
        session.sendAudio(pcm.subdata(in: offset..<end))
        offset = end
        Thread.sleep(forTimeInterval: 0.064)
    }
    q.sync { audioEndedAt = Date() }

    // Silence until the output has been stable for a beat, exactly as the app
    // keeps the socket fed between utterances. The deadline is generous
    // because `en_long` is a long sentence and a clipped tail would be scored
    // as a wrong answer.
    // A multi-utterance case has a real gap between its answers, and a 3s
    // window closed the socket inside that gap — scoring `de_after_en` and
    // `de_after_es` as one-turn FAILURES when the model had in fact answered
    // both. The harness was wrong, not the model: at 10s both come back
    // [de,en] and [de,es]. 8s is the default because it clears the measured
    // gap with margin; the env var stays so the threshold can be probed
    // rather than trusted.
    let stableWindow = ProcessInfo.processInfo.environment["STABLE_WINDOW"]
        .flatMap(Double.init) ?? 8.0
    // A case that produces NOTHING (silence, noise) never satisfies the
    // stable-output rule, so without this it waits out the whole deadline.
    // Correct answer, absurd cost — and it is the pair of cases most likely
    // to be run repeatedly.
    // 6s cut `en_long` off before it answered — a long English sentence that
    // had returned at 4.07s on one run and nothing at all on the next, which
    // is a real observation about the general model rather than a threshold to
    // tune away: its time-to-first-token on long input is variable in a way
    // the translate model's is not (that one begins emitting BEFORE the
    // utterance ends). 12s so a failure here means silence rather than
    // impatience.
    let noOutputGrace = ProcessInfo.processInfo.environment["NO_OUTPUT_GRACE"]
        .flatMap(Double.init) ?? 12.0
    let silence = Data(count: 2048)
    let deadline = Date().addingTimeInterval(45)
    let silenceStartedAt = Date()
    var lastLength = 0
    var quietSince = Date()
    while Date() < deadline {
        session.sendAudio(silence)
        Thread.sleep(forTimeInterval: 0.064)
        if let message = q.sync(execute: { errorText }) {
            session.close()
            return (q.sync { turns }, message)
        }
        let length = q.sync { current.count + turns.reduce(0) { $0 + $1.text.count } }
        if length != lastLength {
            lastLength = length
            quietSince = Date()
        } else if length > 0, Date().timeIntervalSince(quietSince) > stableWindow {
            break
        } else if length == 0, Date().timeIntervalSince(silenceStartedAt) > noOutputGrace {
            break
        }
    }
    session.close()
    q.sync { closeTurn() }
    return (q.sync { turns }, nil)
}

let requested = Array(CommandLine.arguments.dropFirst())
let names = requested.isEmpty ? defaultOrder : requested
let apiKey = loadAPIKey()

print("\nL3 replay through INTERPRETER mode — one session, no arbitration")
print("model: \(GeminiLiveSession.Mode.defaultInterpreterModel)\n")

var passes = 0
var failures = 0
for name in names {
    guard let testCase = cases.first(where: { $0.name == name }) else {
        print("  ?  \(name) — no such case")
        continue
    }
    let (turns, error) = run(testCase, apiKey: apiKey)
    if let error {
        print("  ERR \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(error)")
        failures += 1
        continue
    }

    let got = turns.map { detect($0.text) }
    let want = testCase.expect
    let ok = got.count == want.count
        && zip(got, want).allSatisfy { $0 != nil && $0! == $1 }
    let shown = got.map { $0?.rawValue ?? "?" }.joined(separator: ",")
    let expected = want.map(\.rawValue).joined(separator: ",")
    let timing = turns.first.map { String(format: "%.2fs", $0.first) } ?? "  --"
    let sample = turns.first?.text.prefix(38) ?? ""

    print("  \(ok ? "PASS" : "FAIL") \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) "
        + "got[\(shown)] want[\(expected)] \(timing)  \(sample)")
    ok ? (passes += 1) : (failures += 1)
}

print("\n==> interpreter replay: \(passes) passed, \(failures) failed, of \(passes + failures)")
print("    Not an L3 result. L3 gates the app's arbitration, release timing and")
print("    truncation rules; this asks only whether one session gets the")
print("    direction right on the same audio.\n")
exit(failures == 0 ? 0 : 1)
