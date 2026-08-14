import Foundation

// L3 replay runner (TESTING.md §L3): feeds recorded audio through the REAL
// pipeline — the app's own GeminiLiveSession (wire protocol) and TurnLogic
// (turn decisions), compiled straight from the app sources by l3replay.sh.
//
// What this emulates rather than reuses is the service's *glue*: the mic tap
// (a WAV file stands in for the microphone) and the turn-finalization timers
// (same rules, tolerances widened slightly for network jitter). Audio
// hardware behavior — capture, playback, echo — stays an L4 concern.
//
// Run from the repo root (l3replay.sh does): needs
// HeikoTranslate/Resources/Secrets.plist and talks to the live API.

// MARK: - Expectations (TESTING.md §L3)

struct ExpectedBubble {
    let isHome: Bool
    /// Which session must have produced the translation. Checked against
    /// TurnLogic's choice AND against that session actually having output
    /// (a silent-translator fallback is a failure here even though the app
    /// tolerates it).
    let translator: TurnLogic.Lang?
    /// Minimum word count of the original — the R5 truncation check.
    let minOriginalWords: Int

    init(isHome: Bool, translator: TurnLogic.Lang? = nil, minOriginalWords: Int = 1) {
        self.isHome = isHome
        self.translator = translator
        self.minOriginalWords = minOriginalWords
    }
}

/// Which pair each replay runs with (home, partner). Spanish cases run the
/// de↔es pair — the partner is explicit now; there is no auto-follow.
let pairs: [String: (TurnLogic.Lang, TurnLogic.Lang)] = [
    "es_short": (.de, .es),
    "de_after_es": (.de, .es),
    // #29: German spoken under a CHINESE-home pair — the zh session is the
    // home translator, and its few-character output is what the per-script
    // floors exist to admit.
    "de_price_short": (.zh, .de),
]

let expectations: [String: [ExpectedBubble]] = [
    "en_short": [ExpectedBubble(isHome: false, translator: .de)],
    "de_short": [ExpectedBubble(isHome: true, translator: .en)],
    "es_short": [ExpectedBubble(isHome: false, translator: .de)],
    // GitHub #32, from device evidence 2026-08-14. Pure German speech that
    // OPENS with an English song title. The home side is the correct answer
    // in BOTH: the speaker is German throughout, and the title is a name
    // rather than a change of language.
    //
    // Both PASS today, and that is the finding: measured 2026-08-14, the
    // device flip does NOT reproduce through synthesized audio. The
    // transcript here matches the device turn word for word — "We will rock
    // you ist mein Lieblingslied." — and the direction still resolves home,
    // both from a cold turn and after a preceding German one. So whatever
    // flips it on device is not the sentence, and not session warmth; the
    // remaining difference is a human voice.
    //
    // They stay as REGRESSION guards, not as a repro: English-leading German
    // must keep landing home, and a future fix for #32 must not buy the
    // short case by breaking these.
    "de_song_lead": [ExpectedBubble(isHome: true, translator: .en)],
    "de_song_lead_long": [ExpectedBubble(isHome: true, translator: .en)],
    // Entity-preserving translation (#83): the German translation keeps
    // every name, so it must still count as a translation — the shipped
    // token-overlap rule dropped this turn (codes settled) or committed it
    // as a RIGHT/home bubble (codes unsettled).
    "en_entities": [ExpectedBubble(isHome: false, translator: .de)],
    // GitHub #32/#83: genuinely foreign speech carrying proper nouns. All
    // four MUST land foreign — they are the population a #32 fix must not
    // misclassify as an echo, and "A boy named Sue…" is the exact turn the
    // reverted threshold dropped (L1.91). Opt-in, like the de_song_lead
    // pair: they exist to be measured, and L3's default run stays a gate.
    "en_song_cash": [ExpectedBubble(isHome: false, translator: .de)],
    "en_series_ny": [ExpectedBubble(isHome: false, translator: .de)],
    "en_band_queen": [ExpectedBubble(isHome: false, translator: .de)],
    "en_apple_google": [ExpectedBubble(isHome: false, translator: .de)],
    "en_long": [ExpectedBubble(isHome: false, translator: .de, minOriginalWords: 50)],
    "de_after_en": [ExpectedBubble(isHome: false, translator: .de),
                    ExpectedBubble(isHome: true, translator: .en)],
    // With the explicit de↔es pair, German after Spanish comes back Spanish
    // because the partner IS Spanish — no inference involved.
    "de_after_es": [ExpectedBubble(isHome: false, translator: .de),
                    ExpectedBubble(isHome: true, translator: .es)],
    // One German utterance with an internal breath pause (#78): ONE bubble,
    // both halves present (word floor), ONE release.
    "de_pause": [ExpectedBubble(isHome: true, translator: .en, minOriginalWords: 10)],
    // Foreign (German) speech under the zh-home pair: LEFT bubble, the home
    // (zh) session translating. The translation is legitimately only a few
    // characters — the #29 discriminator.
    "de_price_short": [ExpectedBubble(isHome: false, translator: .zh)],
    "silence": [],
    "noise": [],
]

let defaultOrder = ["en_short", "de_short", "es_short", "en_entities",
                    "en_long", "de_after_en", "de_after_es", "de_pause",
                    "de_price_short", "silence", "noise"]

/// #78: expected count of "speaker stopped" releases, for cases that pin
/// the release timing. `de_pause` holds one utterance with an internal
/// breath pause — the pre-#78 rule released mid-pause (transcript-idle
/// alone) and again after the second half: 2 releases, the app talking
/// over the speaker. The mic-aware policy defers through the pause: 1.
let expectedReleaseCounts: [String: Int] = ["de_pause": 1]

// Plumbing (loadAPIKey, loadWAV, rms) lives in common.swift, shared with
// the L2.6 expiry probe.

// MARK: - Replay runner

final class ReplayRunner {
    struct CommittedBubble {
        let bubble: TurnLogic.Bubble
        let translator: TurnLogic.Lang?
        /// True when the committed translation came from the fallback path
        /// (the chosen translator session had no output).
        let usedFallback: Bool
    }

    private let q = DispatchQueue(label: "l3replay")
    private let apiKey: String
    private let home: TurnLogic.Lang
    private let partner: TurnLogic.Lang

    private var sessions: [TurnLogic.Lang: GeminiLiveSession] = [:]
    private var ready: Set<TurnLogic.Lang> = []

    // Mirrors GeminiLiveTranslationService's per-utterance state.
    private var turn: TurnLogic
    private var inputs: [TurnLogic.Lang: String] = [:]
    private var outputs: [TurnLogic.Lang: String] = [:]

    private(set) var bubbles: [CommittedBubble] = []
    private(set) var errors: [String] = []
    // L3_INJECT_RAW=1 seeds one synthetic frame, so the drift gate's teeth
    // can be demonstrated on demand instead of waiting for real drift — the
    // gate is only trustworthy if a raw frame provably fails a run. GitHub #19.
    private(set) var rawMessages: [String] =
        ProcessInfo.processInfo.environment["L3_INJECT_RAW"] == "1"
            ? ["[synthetic] seeded by L3_INJECT_RAW — a run seeing this must fail"] : []
    private(set) var inputLanguageCodes: [String] = []

    /// What the sessions produced but the turn never committed — printed
    /// when a case fails, to tell "no transcripts at all" from "transcripts
    /// but the commit gate said no".
    var leftoversDescription: String {
        q.sync {
            "inputs=\(inputs.mapValues { String($0.prefix(80)) }) outputs=\(outputs.mapValues { String($0.prefix(80)) }) " +
            "inputLanguages=\(inputLanguageCodes)"
        }
    }

    private let startedAt = Date()
    private func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(startedAt)) }
    private let verbose = ProcessInfo.processInfo.environment["L3_VERBOSE"] != nil
    /// One timestamped line per transcript EVENT, not per turn — the
    /// aggregated per-turn dumps below can't say when the home session's
    /// output arrived relative to the turn boundary, which is the question
    /// direction bugs turn on (#75: straggling previous-turn translation vs
    /// misheard echo imply different fixes).
    private func trace(_ tag: String, _ lang: TurnLogic.Lang, _ text: String) {
        guard verbose else { return }
        let flat = text.replacingOccurrences(of: "\n", with: "\\n")
        print("      \(tag)[\(lang.rawValue)]@\(elapsed()): \(flat)")
    }

    private var lastContentAt = Date.distantPast
    /// The last time the USER was heard, as distinct from the last time
    /// anything happened. The service's deferral guard reads this clock (its
    /// `lastInputAt`, set only from `.inputTranscript`); comparing against
    /// `lastContentAt` instead meant the model's own translation — the thing
    /// the deferral is waiting for — reset the guard and the retry was skipped.
    /// GitHub #21.
    private var lastInputAt = Date.distantPast
    private var lastOutputAt = Date.distantPast
    private let outputQuietPause = 1.1   // service uses 0.9; widened for jitter

    // #78: the release simulation. Same decision the service makes, through
    // the same SpeechEndPolicy — the WAV chunks stand in for the mic, so
    // `lastLoudMicAt` here is the harness's exact equivalent of the app's.
    // 400 is the service's `micSpeechRMSFloor` (calibrated: speech 991–5263,
    // silence 0–12).
    private var lastLoudMicAt: Date?
    private var speakerReleased = false
    /// Armed only by a transcript event, exactly like the service's
    /// `noteInputActivity` timer — a wiped turn must NOT re-attempt a
    /// release off the previous turn's stale `lastInputAt`.
    private var releaseArmed = false
    private var releaseDeferredSince: Date?
    private(set) var releaseCount = 0
    /// How many times the server abandoned a response mid-stream (#112).
    private(set) var interruptedEvents = 0
    private var lastTranslatorAudioAt: Date?
    private var streamEndedAt: Date?
    /// Set while a finalize is waiting for a late translation — see
    /// `FinalizePolicy`, shared with the app.
    private var deferUntil: Date?
    private var finalizePolicy = FinalizePolicy()
    private var finished = false
    private let readySem = DispatchSemaphore(value: 0)
    private let doneSem = DispatchSemaphore(value: 0)

    // The service finalizes 0.45s after translated audio stops, or 1.6s
    // after input transcription stops when no translation ever played.
    // Slightly wider here to absorb network jitter.
    private let outputTailTimeout = 0.8
    private let inputIdleTimeout = 2.0
    private let endOfStreamQuiet = 3.0

    init(apiKey: String, home: TurnLogic.Lang = .de, partner: TurnLogic.Lang = .en) {
        self.apiKey = apiKey
        self.home = home
        self.partner = partner
        self.turn = TurnLogic(home: home, partner: partner)
    }

    func run(pcm: Data) {
        for lang in [home, partner] {
            let session = GeminiLiveSession(targetLanguageCode: lang.rawValue, apiKey: apiKey) { [weak self] event in
                guard let self else { return }
                self.q.async { self.handle(lang, event) }
            }
            sessions[lang] = session
            session.connect()
        }
        if readySem.wait(timeout: .now() + 20) != .success {
            q.sync { errors.append("sessions not all ready within 20s (got \(ready.map(\.rawValue).sorted()))") }
            cleanup(); return
        }

        q.async { self.tick() }

        let audioSeconds = Double(pcm.count) / 2.0 / 16000.0
        Thread { self.stream(pcm) }.start()

        if doneSem.wait(timeout: .now() + audioSeconds + 45) != .success {
            q.sync { errors.append("replay timed out"); finished = true }
        }
        cleanup()
    }

    private func cleanup() {
        q.sync {
            finished = true
            for s in sessions.values { s.close() }
        }
    }

    /// The stand-in for the mic tap: same 64ms chunking, real-time pacing,
    /// every session gets every chunk (silence included). After the file
    /// ends we keep streaming silence — a real microphone never stops, and
    /// the model's voice-activity detection needs trailing silence to close
    /// the final utterance.
    private func stream(_ pcm: Data) {
        let chunkBytes = 2048 // 64ms of 16kHz 16-bit mono
        var offset = 0
        let sessionList = Array(sessions.values)
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            let chunk = pcm.subdata(in: offset..<end)
            if rms(chunk) > 400 {
                let now = Date()
                q.async { self.lastLoudMicAt = now }
            }
            for s in sessionList { s.sendAudio(chunk) }
            offset = end
            Thread.sleep(forTimeInterval: 0.064)
        }
        q.async { self.streamEndedAt = Date() }
        let silence = Data(count: chunkBytes)
        while !(q.sync { finished }) {
            for s in sessionList { s.sendAudio(silence) }
            Thread.sleep(forTimeInterval: 0.064)
        }
    }

    /// Mirrors GeminiLiveTranslationService.handle — the decisions all go
    /// through the real TurnLogic.
    private func handle(_ lang: TurnLogic.Lang, _ event: GeminiLiveSession.Event) {
        guard !finished else { return }
        switch event {
        case .opened:
            break
        case .setupComplete:
            ready.insert(lang)
            if ready.count == sessions.count { readySem.signal() }
        case .audioChunk(let data):
            if rms(data) > 220, let t = turn.translator, lang == t {
                lastTranslatorAudioAt = Date()
                lastContentAt = Date()
            }
        case .inputLanguage(let code):
            inputLanguageCodes.append("\(lang.rawValue):\(code)@\(elapsed())")
            turn.noteInputLanguage(code, from: lang)
            // The service re-derives direction after every code event —
            // mirrored here so replays exercise the same streaming path
            // (#84 review: the harness previously never called noteOutputs
            // at all, so its results could not witness re-derivation).
            turn.noteOutputs(outputs, inputs: inputs)
        case .inputTranscript(let text):
            trace("IN ", lang, text)
            inputs[lang, default: ""] += text
            lastContentAt = Date()
            lastInputAt = Date()
            // Mirrors noteInputActivity: a fresh transcript re-arms the
            // release (#78).
            speakerReleased = false
            releaseArmed = true
            releaseDeferredSince = nil
        case .outputLanguage:
            break
        case .outputTranscript(let text):
            trace("OUT", lang, text)
            outputs[lang, default: ""] += text
            // Mirrors the service's streaming call at its outputTranscript
            // site — direction resolves as output arrives, exactly as in
            // production, rather than only at commit.
            turn.noteOutputs(outputs, inputs: inputs)
            lastContentAt = Date()
            lastOutputAt = Date()
        case .turnComplete:
            break
        case .interrupted:
            // #112: the server abandoned the response it was streaming, so
            // the audio already sent for it is superseded. The service holds
            // every chunk until commit and plays all of them, which is the
            // stutter. Printed here because L3 drives the real session
            // against the live API — so a replay answers whether this model
            // sends the signal at all, without needing a device.
            interruptedEvents += 1
            print("    (interrupted) [\(lang.rawValue)] server abandoned its response at \(elapsed())")
        case .usage(let usage):
            if ProcessInfo.processInfo.environment["L3_USAGE"] != nil {
                let json = (try? JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "\(usage)"
                print("    USAGE[\(lang.rawValue)] \(json)")
            }
        case .raw(let text):
            rawMessages.append("[\(lang.rawValue)] \(text)")
        case .closed:
            errors.append("[\(lang.rawValue)] session closed mid-replay")
        case .error(let message):
            errors.append("[\(lang.rawValue)] \(message)")
        case .debug:
            break
        }
    }

    /// The finalization watchdog — same rules as the service's two timers.
    private func tick() {
        guard !finished else { return }
        let now = Date()
        let quiet = now.timeIntervalSince(lastContentAt)

        // A deferred finalize owns the turn until its interval elapses; then
        // it retries, exactly as the service's deferral timer does.
        if let until = deferUntil {
            if now < until {
                q.asyncAfter(deadline: .now() + 0.1) { self.tick() }
                return
            }
            deferUntil = nil
            // THE guard, not a copy of it — FinalizePolicy owns both the
            // threshold and which clock it is measured against. Written out
            // here, against lastContentAt, it silently diverged: the arriving
            // translation reset the clock and the retry never fired. GitHub #21.
            if FinalizePolicy.deferredRetryIsDue(now: now, lastInputAt: lastInputAt) {
                finalizeTurn()
            }
            q.asyncAfter(deadline: .now() + 0.1) { self.tick() }
            return
        }

        // #78: the service's audio-release decision, through the same
        // SpeechEndPolicy — armed by transcript idleness, vetoed by a loud
        // "mic" (the WAV chunks). Recorded so pause cases can assert the
        // app never starts talking over a speaker who is mid-breath.
        if releaseArmed, !speakerReleased, lastInputAt != .distantPast,
           now.timeIntervalSince(lastInputAt) >= SpeechEndPolicy.transcriptIdleThreshold {
            if SpeechEndPolicy.mayRelease(now: now, lastLoudMicAt: lastLoudMicAt,
                                          deferredSince: releaseDeferredSince) {
                speakerReleased = true
                releaseDeferredSince = nil
                releaseCount += 1
                print("    release \(releaseCount) (speaker stopped) at \(elapsed())")
            } else if releaseDeferredSince == nil {
                releaseDeferredSince = now
                print("    (release deferred — mic still hears speech) at \(elapsed())")
            }
        }

        let outputQuiet = now.timeIntervalSince(lastOutputAt) > outputQuietPause
        if let lastAudio = lastTranslatorAudioAt,
           now.timeIntervalSince(lastAudio) > outputTailTimeout, quiet > outputTailTimeout, outputQuiet {
            finalizeTurn()
        } else if lastTranslatorAudioAt == nil, !inputs.isEmpty, quiet > inputIdleTimeout, outputQuiet {
            finalizeTurn()
        }

        if let ended = streamEndedAt {
            let sinceEnd = now.timeIntervalSince(ended)
            let contentQuiet = lastContentAt == .distantPast ? sinceEnd : quiet
            if sinceEnd > endOfStreamQuiet, contentQuiet > endOfStreamQuiet {
                finalizeTurn()
                finished = true
                doneSem.signal()
                return
            }
        }
        q.asyncAfter(deadline: .now() + 0.1) { self.tick() }
    }

    /// Mirrors finalizeTurn + resetForNextUtterance: commit through the real
    /// TurnLogic gate, then clear per-utterance state.
    private func finalizeTurn() {
        // Commit FIRST: a short turn may only lock via commit's plurality
        // fallback, so reading turn.translator before committing would
        // record nil for it.
        let committed = turn.commit(inputs: inputs, outputs: outputs)
        let translator = turn.translator
        let translatorOutput = translator.flatMap { outputs[$0] }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let bubble = committed {
            bubbles.append(CommittedBubble(
                bubble: bubble,
                translator: translator,
                usedFallback: translatorOutput.isEmpty
            ))
            let side = bubble.isHome ? "RIGHT (home)" : "LEFT (foreign)"
            print("    bubble \(bubbles.count): \(side) via \(translator?.rawValue ?? "?") [finalized \(elapsed())]")
            print("      original:    \(bubble.original)")
            print("      translation: \(bubble.translation)")
        }
        if ProcessInfo.processInfo.environment["L3_VERBOSE"] != nil {
            print("      (verbose) codes so far: \(inputLanguageCodes.joined(separator: " "))")
            for (lang, text) in inputs.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("      (verbose) input[\(lang.rawValue)]: \(text)")
            }
            // Which sessions actually produced a translation. A session whose
            // target equals the spoken language should stay silent — if that
            // holds reliably, it's a stronger direction signal than the
            // language codes (which are known to lie).
            for lang in TurnLogic.Lang.allCases {
                let text = (outputs[lang] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                print("      (verbose) OUTPUT[\(lang.rawValue)]: \(text.isEmpty ? "<silent>" : text)")
            }
        }
        // Ask the SAME policy the app uses. This harness previously had no
        // deferral at all: a turn whose translation was still in flight was
        // committed-or-wiped on the spot, so the release gate reported
        // swallowed turns the shipping app would have recovered. Measured
        // 2026-08-04: 58% of de_after_es failures had exactly that shape.
        // GitHub #21.
        let outcome = finalizePolicy.decide(committed: committed != nil,
                                            rejectReason: turn.lastRejectReason)
        if outcome == .waitForTranslation {
            let reason = turn.lastRejectReason ?? "?"
            print("    (defer) \(reason) — waiting \(FinalizePolicy.deferralInterval)s "
                  + "[\(finalizePolicy.deferrals)/\(FinalizePolicy.maxDeferrals)] at \(elapsed())")
            // Hold the turn open: keep inputs/outputs so a late translation can
            // still complete it, and let tick() come back after the interval.
            deferUntil = Date().addingTimeInterval(FinalizePolicy.deferralInterval)
            return
        }
        deferUntil = nil
        turn.endTurn()
        if verbose { print("      --- turn ended @\(elapsed()) — state wiped ---") }
        inputs = [:]
        outputs = [:]
        lastOutputAt = .distantPast
        lastTranslatorAudioAt = nil
        speakerReleased = false
        releaseArmed = false
        releaseDeferredSince = nil
    }
}

// MARK: - Assertions

var totalPassed = 0, totalFailed = 0

func check(_ ok: Bool, _ label: String) {
    if ok { totalPassed += 1; print("  ✅ \(label)") }
    else { totalFailed += 1; print("  ❌ \(label)") }
}

func runCase(name: String, apiKey: String) {
    guard let expected = expectations[name] else {
        fputs("error: no expectations defined for '\(name)'\n", stderr)
        totalFailed += 1
        return
    }
    let path = "TestAudio/\(name).wav"
    print("\n▶ \(name) (\(path))")
    let pair = pairs[name] ?? (.de, .en)
    print("  pair \(pair.0.rawValue)↔\(pair.1.rawValue)")
    let runner = ReplayRunner(apiKey: apiKey, home: pair.0, partner: pair.1)
    runner.run(pcm: loadWAV(path))

    check(runner.errors.isEmpty, "no session errors" + (runner.errors.isEmpty ? "" : ": \(runner.errors.joined(separator: "; "))"))
    check(runner.bubbles.count == expected.count,
          "exactly \(expected.count) bubble(s) — got \(runner.bubbles.count) (R1)")
    if let wantReleases = expectedReleaseCounts[name] {
        check(runner.releaseCount == wantReleases,
              "exactly \(wantReleases) speaker-stop release(s) — got \(runner.releaseCount) (#78)")
    }
    if runner.bubbles.count != expected.count {
        print("    (debug) uncommitted leftovers: \(runner.leftoversDescription)")
    }

    for (i, exp) in expected.enumerated() where i < runner.bubbles.count {
        let got = runner.bubbles[i]
        let side = exp.isHome ? "RIGHT/home" : "LEFT/foreign"
        check(got.bubble.isHome == exp.isHome, "bubble \(i + 1) on the \(side) side (R2)")
        check(!got.bubble.translation.isEmpty, "bubble \(i + 1) has a translation (R3)")
        if let want = exp.translator {
            check(got.translator == want, "bubble \(i + 1) translated by the '\(want.rawValue)' session — got '\(got.translator?.rawValue ?? "none")' (§3.1)")
            check(!got.usedFallback, "bubble \(i + 1) translation came from that session, not the fallback")
        }
        let words = got.bubble.original.split(whereSeparator: \.isWhitespace).count
        check(words >= exp.minOriginalWords, "bubble \(i + 1) original has ≥\(exp.minOriginalWords) words — got \(words) (R5)")
    }

    // Protocol drift is a FAILURE, not a footnote. `.raw` exists so a new
    // server shape is visible the day it appears; recording it and then
    // exiting 0 let the release gate pass while the production parser was
    // discarding frames (GitHub #19). L3_ALLOW_RAW=1 downgrades it back to
    // the old warning — for investigating a drift, never for a release run.
    if ProcessInfo.processInfo.environment["L3_ALLOW_RAW"] == "1" {
        if !runner.rawMessages.isEmpty {
            print("  ⚠️ \(runner.rawMessages.count) unrecognized server message(s) ALLOWED by L3_ALLOW_RAW. First: \(runner.rawMessages[0].prefix(200))")
        }
    } else {
        check(runner.rawMessages.isEmpty,
              "no unrecognized server messages (protocol drift)"
              + (runner.rawMessages.isEmpty ? "" :
                 " — \(runner.rawMessages.count) frame(s), first: \(runner.rawMessages[0].prefix(200))"))
    }
}

// MARK: - Main

let apiKey = loadAPIKey()
let args = Array(CommandLine.arguments.dropFirst())
let names = args.isEmpty
    ? defaultOrder
    : args.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".wav", with: "") }

print("L3 — Replay tests (real GeminiLiveSession + real TurnLogic, live API)")
for name in names {
    runCase(name: name, apiKey: apiKey)
}
print("\n\(totalPassed) passed, \(totalFailed) failed")
exit(totalFailed == 0 ? 0 : 1)
