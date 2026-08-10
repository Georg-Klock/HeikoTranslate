import AVFoundation
import SwiftUI

@MainActor
final class ConversationViewModel: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        /// What was said, in the language it was spoken (shown first).
        let original: String
        /// The spoken-aloud translation (shown below).
        let translation: String
        /// True if the HOME language was spoken — shown on the right.
        let fromHome: Bool
    }

    /// The selected language pair, persisted across launches. Home is the
    /// right side (large type — the phone owner's reader language); partner
    /// is the left. Choosing one equal to the other swaps them, so the pair
    /// is always two distinct languages.
    // The guard below wraps only the *nested* swap assignment, and that
    // placement is the whole point. It used to live inside
    // persistAndApplyLanguages() behind a `defer`, which released it the
    // moment the inner call returned — so the outer observer's own trailing
    // call ran unguarded and one user gesture applied the pair twice. Two
    // applies meant two stop()/beginListening() cycles racing each other:
    // a second installTap on bus 0 (documented to trap) and a second set of
    // sessions overwriting the first without closing them — orphaned sockets
    // still streaming Heiko's audio to Google, still billed, with no
    // reference left that could ever close them. GitHub #1.
    @Published var homeLang: TurnLogic.Lang {
        didSet {
            guard !isAdjustingPair else { return }
            if homeLang == partnerLang { withPairAdjustment { partnerLang = oldValue } }
            persistAndApplyLanguages()
        }
    }
    @Published var partnerLang: TurnLogic.Lang {
        didSet {
            guard !isAdjustingPair else { return }
            if partnerLang == homeLang { withPairAdjustment { homeLang = oldValue } }
            persistAndApplyLanguages()
        }
    }

    /// True only while one observer is assigning the *other* language to keep
    /// the pair distinct. Silences that assignment's observer so the swap
    /// cannot trigger a second apply.
    private var isAdjustingPair = false
    private func withPairAdjustment(_ body: () -> Void) {
        isAdjustingPair = true
        body()
        isAdjustingPair = false
    }

    /// Counts completed applications of the language pair. Exists so a test
    /// can prove one gesture produces exactly one apply — the property that
    /// broke in #1 and cannot be observed from the pure logic layer, because
    /// the bug lived in the observer wiring rather than in any function.
    private(set) var languageApplyCount = 0

    /// What a fresh install opens on: **German as HOME, English as partner.**
    ///
    /// German is home because home is the large line and the right-hand
    /// bubble — the text Heiko actually reads. Shipping this the other way up
    /// gives him an app whose main line is in a language he does not read, and
    /// he cannot be talked through fixing it down a phone line, which is the
    /// whole reason the `-ResetLanguagePair` hatch below exists.
    ///
    /// Named constants rather than literals at the call site so L1.47 can pin
    /// them without reaching into `UserDefaults`. Pinned by product decision,
    /// 2026-08-07.
    static let defaultHomeLang: TurnLogic.Lang = .de
    static let defaultPartnerLang: TurnLogic.Lang = .en

    static func loadLang(_ key: String, default def: TurnLogic.Lang) -> TurnLogic.Lang {
        UserDefaults.standard.string(forKey: key).flatMap(TurnLogic.Lang.init(rawValue:)) ?? def
    }

    /// How long the wheel must sit still before the pair reaches the sessions.
    ///
    /// The settings wheels are rotaries: one flick crosses several notches and
    /// each notch is a language change. Measured on the device 2026-08-07 —
    /// five changes in 240ms — and before this, every one of them tore both
    /// WebSocket sessions down and rebuilt them. That is the GitHub #1 churn
    /// arriving by a new route: the picker that made it impossible was
    /// replaced by a control that makes it easy.
    static let languageSettleDelay: TimeInterval = 0.4

    private var languageRestartTask: Task<Void, Never>?

    /// Counts language changes that actually REACHED the sessions, after
    /// coalescing. Exists so a test can prove one spin restarts once — the
    /// coalescing is the whole point and is otherwise invisible.
    private(set) var languageRestartCount = 0

    private func persistAndApplyLanguages() {
        languageApplyCount += 1
        UserDefaults.standard.set(homeLang.rawValue, forKey: "settings.homeLang")
        UserDefaults.standard.set(partnerLang.rawValue, forKey: "settings.partnerLang")
        diag("app", "language pair set to \(homeLang.rawValue)↔\(partnerLang.rawValue)")
        // Persisting is cheap and happens per change, so the stored pair is
        // always the truth. Only the SESSION RESTART is debounced.
        languageRestartTask?.cancel()
        languageRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.languageSettleDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.languageRestartCount += 1
            guard self.isListening else { return }
            diag("app", "language pair settled — restarting sessions")
            self.stop()
            await self.beginListening()
        }
    }
    @Published private(set) var isListening = false
    @Published private(set) var messages: [Message] = []
    @Published private(set) var activity: GeminiLiveTranslationService.Activity = .idle
    /// Live, word-by-word transcript of what's being said right now, in the
    /// language it's spoken. Cleared when the turn finalizes into a message.
    @Published private(set) var liveTranscript = ""
    /// Which side the in-progress line belongs on: `true` German (right),
    /// `false` foreign (left), `nil` not known yet. While it's nil the line
    /// stays centred and unaligned — guessing produced text that started on
    /// the right and jumped left when the turn finished.
    @Published private(set) var liveIsHome: Bool?
    @Published var errorMessage: String?

    /// Something to say in the slot under the button, and how loudly.
    ///
    /// Severity is DATA. It used to be spelling: the view picked its colour
    /// with `warning.hasPrefix("Schlechte")`, which made the German copy a
    /// control channel — reword the degraded warning and it silently turns
    /// red, with nothing failing and nothing warning. Text and severity are
    /// set together here so they cannot disagree. GitHub #28.
    ///
    /// Named for the slot rather than for connections because two different
    /// things share it now: a connection warning and the microphone notice
    /// below. A mic notice is not a `ConnectionWarning`, and `.info` is not a
    /// severity a connection warning ever has.
    struct StatusNotice: Equatable {
        enum Severity { case info, degraded, lost }
        let text: String
        let severity: Severity
    }

    /// Persistent connection banner (German — Heiko reads it). A CONDITION:
    /// set and cleared by `onConnectionQuality` as the network changes, and it
    /// stays up while the condition holds. Distinct from `errorMessage`, which
    /// is for one-off failures.
    @Published private(set) var connectionWarning: StatusNotice?

    /// Transient notice that the microphone came back on by itself after an
    /// interruption. An EVENT, which is why it is a second property rather
    /// than another value of `connectionWarning`: one is a condition with a
    /// lifetime of its own, and merging them means whichever is set last
    /// clobbers the other. They share the single bottom overlay instead, with
    /// the precedence in `bottomNotice(muted:warning:micNotice:)`.
    ///
    /// Set only after a resume has actually SUCCEEDED — see
    /// `resumeAfterInterruption()`. "The microphone is on again" over a start
    /// that did not happen is worse than saying nothing. GitHub #28.
    @Published private(set) var micNotice: StatusNotice?

    /// How long the mic notice stays up. Generous: Heiko has to notice it and
    /// read it, and it must not become wallpaper.
    static let micNoticeDuration: TimeInterval = 5

    private var micNoticeDismissal: Task<Void, Never>?

    /// Which occupant of the slot under the button wins, in one place.
    ///
    /// The slot can only ever say one thing, and three things want it. Pure so
    /// L1 pins the precedence rather than the view implying it:
    ///
    /// 1. **Muted** — "Mikrofon pausiert" outranks everything; nothing else
    ///    matters while the app is not listening.
    /// 2. **Connection warning** — a condition, up while it holds.
    /// 3. **Mic notice** — a transient event, and the newest arrival, so it
    ///    yields to a standing warning rather than displacing it.
    ///
    /// A second overlay on the same slot, instead of a case here, is how two
    /// messages end up drawn on top of each other. GitHub #28.
    static func bottomNotice(muted: Bool,
                             warning: StatusNotice?,
                             micNotice: StatusNotice?) -> StatusNotice? {
        guard !muted else { return nil }
        return warning ?? micNotice
    }

    /// The whole mapping from connection quality to what the user sees, pure so
    /// L1 can check that severity tracks quality rather than spelling.
    static func warning(for quality: GeminiLiveTranslationService.ConnectionQuality,
                        in lang: TurnLogic.Lang = .de) -> StatusNotice? {
        let s = UIStrings.of(lang)
        switch quality {
        case .good:
            return nil
        case .degraded:
            return StatusNotice(text: s.poorConnection, severity: .degraded)
        case .silent:
            return StatusNotice(text: s.noServerResponse, severity: .lost)
        case .offline:
            return StatusNotice(text: s.offline, severity: .lost)
        }
    }

    /// Whether an `AVAudioSession` interruption-ended notification says iOS
    /// considers resuming appropriate.
    ///
    /// **Diagnostic, not a gate.** An earlier draft of #28 used this to stay
    /// paused whenever iOS withheld `.shouldResume`. That was reversed on a
    /// product decision: iOS almost always attaches an options value, so the
    /// real effect was that any interruption it did not mark resumable — an
    /// alarm or a timer, the common case — left Heiko permanently muted until
    /// he noticed and tapped. For this user a silent stop he does not notice
    /// is worse than an unexpected start he can see. So the app resumes
    /// anyway, tells him it did, and records what iOS thought in the device
    /// log. Pure, so L1 covers it without an audio session. GitHub #28.
    static func mayResume(afterInterruptionOptions raw: UInt?) -> Bool {
        guard let raw else { return true }
        return AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
    }

    /// False until the user has started listening at least once. The app
    /// deliberately opens muted (see `ContentView.task`) while the
    /// speak-immediately-at-launch bug is outstanding, so this distinguishes
    /// "waiting to be started" from "the user muted it".
    @Published private(set) var hasEverStarted = false

    /// True while a start attempt is in flight (permission prompt, connect).
    @Published private(set) var isLaunching = false

    /// Set when listening was stopped by the system (backgrounding, a phone
    /// call, Siri) rather than by the user — so the app resumes by itself
    /// when it becomes active again instead of sitting muted (R8).
    ///
    /// Set ONLY by the two automatic pause paths — backgrounding, and an audio
    /// interruption — and cleared by exactly two things: consuming it, and a
    /// manual tap in either direction.
    ///
    /// The bug that made this an invariant worth writing down: an interruption
    /// armed it, the user started listening again by hand, and the flag was
    /// still set — so the next resume trigger fired a SECOND `beginListening()`
    /// the user never asked for, mid-conversation. Whoever changes the session
    /// state by hand owns the flag. `private(set)` so a test can see it.
    /// GitHub #28.
    private(set) var resumeWhenActive = false

    /// Counts automatic resumes this view model has decided to perform — the
    /// ones no tap asked for. Exists so a test can prove the ownership rule
    /// yields *exactly one* start across an interruption, the property that
    /// broke in #28; same reason `languageApplyCount` exists for #1.
    private(set) var automaticResumeCount = 0

    /// Shown under the button before the very first tap — Heiko reads German.
    ///
    /// Suppressed while an error is showing. On a denied microphone permission
    /// `hasEverStarted` stays false, so this hint used to sit on screen next to
    /// "Bitte erlaube Mikrofonzugriff…" — one line saying tap to speak, the
    /// other saying tapping will not work, permanently, since iOS only prompts
    /// once. That is the app's most likely first-run failure and its target
    /// user is the least able to recover from it. GitHub #25.
    var startHint: String? {
        guard errorMessage == nil else { return nil }
        return (!isListening && !hasEverStarted && !isLaunching) ? strings.tapToSpeak : nil
    }

    /// True once the microphone has been refused. iOS only ever prompts once,
    /// so this is terminal until the user changes it in Settings — which makes
    /// the one button's job "take me there" rather than "try again". SPEC R8:
    /// never sit in a state where the obvious action does nothing.
    ///
    /// Cleared on the way back from Settings — see `noteMicPermission(granted:)`.
    /// Nothing cleared it before, so recovery depended entirely on iOS
    /// terminating the app when the microphone switch is toggled. It usually
    /// does; the case it does not cover is Heiko opening Settings, not
    /// understanding it, and backing out — after which the one button was
    /// permanently a Settings shortcut and could never start listening again.
    /// GitHub #25.
    @Published private(set) var micPermissionDenied = false

    #if DEBUG
    /// Reaching the denied state for real needs a permission prompt, which a
    /// test cannot answer. DEBUG-only so it cannot be called from shipping code.
    func forceMicPermissionDeniedForTesting() { micPermissionDenied = true }
    #endif

    /// Fold a fresh reading of the microphone permission into the denial state.
    /// Split from the scene-phase handler so L1 can exercise it without an
    /// audio session — the branch is otherwise unreachable from a test, which
    /// is how it shipped unexercised in the first place.
    func noteMicPermission(granted: Bool) {
        guard micPermissionDenied, granted else { return }
        diag("app", "microphone permission granted while we were away — recovering")
        micPermissionDenied = false
        errorMessage = nil
    }

    /// Everything the user reads, in the HOME language — the right-hand
    /// bubble, which is the phone owner's own. Not the system locale: the app
    /// already asked which language is theirs, on the home wheel.
    var strings: UIStrings { UIStrings.of(homeLang) }

    /// Status line under the mic.
    var statusText: String {
        if !isListening {
            if isLaunching { return strings.connecting }
            return hasEverStarted ? strings.micPaused : ""
        }
        switch activity {
        case .connecting: return strings.connecting
        case .understanding: return strings.hearing
        case .translating: return strings.translating
        case .idle: return ""
        }
    }

    var statusIsPaused: Bool { !isListening && !isLaunching }

    /// True only while the "Mikrofon pausiert" NOTICE is actually on screen —
    /// the one status that outranks the connection warning in the slot
    /// above the button. (statusIsPaused alone is also true before the very
    /// first tap, when the slot is blank.)
    ///
    /// Scope note: this is the NOTICE only. The mic glyph's amber-and-struck
    /// -through appearance is a separate rule — see `micReadsAsMuted` — and
    /// the two deliberately disagree on a cold launch. They were briefly one
    /// property; Georg's decision on 2026-08-07 split them again.
    var statusShowsMuted: Bool {
        Self.readsAsMuted(isListening: isListening,
                          isLaunching: isLaunching,
                          hasEverStarted: hasEverStarted)
    }

    /// Whether the app should present itself as MUTED, as a pure function of
    /// the three flags that decide it.
    ///
    /// Extracted for the reason `bottomNotice` and `mayResume` were: the rule
    /// is then a thing a test can hold, over states an instance cannot easily
    /// be put into (mid-launch, listening) without audio hardware. The
    /// distinction it draws is invisible in every state but one — a cold
    /// launch — which is how three call sites read `statusIsPaused` for six
    /// review rounds without anything failing.
    ///
    /// **Muted means the user turned it off**, so it requires a session the
    /// user actually started. Never started, or still starting, is not muted.
    /// GitHub #43.
    static func readsAsMuted(isListening: Bool, isLaunching: Bool, hasEverStarted: Bool) -> Bool {
        guard !isListening, !isLaunching else { return false }
        return hasEverStarted
    }

    /// Whether the MIC GLYPH draws itself muted — amber, struck through.
    ///
    /// **This is true on a cold launch, and that is deliberate.** It is the
    /// app's resting face: a microphone that is plainly off, with "Zum
    /// Sprechen antippen" beside it saying how to turn it on. Product decision,
    /// 2026-08-07, after seeing the alternative on his phone.
    ///
    /// It was briefly keyed to `statusShowsMuted`, on the reasoning that a
    /// struck-through mic above an invitation to speak is a contradiction.
    /// The founder's read is the opposite: the slash is what MAKES the
    /// invitation legible — it shows the state the tap is going to change.
    /// A plain white mic before the first tap looks like a mic that is
    /// already listening, which is the more expensive misreading of the two.
    ///
    /// Recorded at this length because the last two sessions each treated
    /// this as a defect. It is a decision.
    ///
    /// Note it does NOT depend on `hasEverStarted` — that is the whole
    /// difference from `readsAsMuted`, and the only state where they differ.
    static func glyphReadsAsMuted(isListening: Bool, isLaunching: Bool) -> Bool {
        !isListening && !isLaunching
    }

    /// The mic glyph's muted appearance. See `glyphReadsAsMuted`.
    var micReadsAsMuted: Bool {
        Self.glyphReadsAsMuted(isListening: isListening, isLaunching: isLaunching)
    }

    /// True while the sessions are still connecting — show a loading spinner.
    var isConnecting: Bool { isListening && activity == .connecting }

    /// True while the translation is being spoken aloud — drives the
    /// outward ripples, visually distinct from the voice-driven listening
    /// rings so "hearing you" and "talking to you" read differently at a
    /// glance across a table.
    var isSpeaking: Bool { isListening && activity == .translating }

    /// Live microphone loudness, 0...1. Drives the flag directly so the app
    /// reacts the instant someone speaks, without waiting for the API.
    @Published private(set) var micLevel: Double = 0

    private let translator = GeminiLiveTranslationService()

    /// The single control: tap to start listening, tap again to mute.
    /// Starting always goes through the permission gate — after a denial,
    /// tapping the one button must re-explain the Settings fix instead of
    /// silently doing nothing forever (R8).
    func toggleButton() {
        diag("ui", "button tapped (listening=\(isListening))")
        // Denied permission is terminal until Settings changes it, so the one
        // control opens Settings instead of re-running a request iOS will
        // never show again. Deliberately still ONE button doing one thing at a
        // time — the alternative was adding a second control to a single-button
        // app, or leaving Heiko tapping something that cannot work. GitHub #25.
        if micPermissionDenied {
            diag("ui", "opening Settings for the denied microphone permission")
            openSettings()
            return
        }
        noteManualToggle()
        if isListening {
            stop()
        } else {
            Task { await self.beginListening() }
        }
    }

    /// A tap in either direction takes ownership of the session: a pending
    /// automatic resume from an earlier interruption is consumed here rather
    /// than left armed to fire a second start later, and a mic notice from a
    /// previous resume goes with it — it must never linger over a state the
    /// user has since changed by hand. GitHub #28.
    func noteManualToggle() {
        resumeWhenActive = false
        clearMicNotice()
        // A tap owns the session, so a language restart still waiting to fire
        // must not arrive afterwards and start something the user just stopped.
        languageRestartTask?.cancel()
    }

    /// Opens this app's page in iOS Settings, where the microphone switch is.
    /// UIApplication.openSettingsURLString lands directly on the app's own
    /// pane — Heiko never has to find it by name in a list he cannot read.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Ensures mic permission, then starts listening. Called on every unmute
    /// and when resuming after an interruption.
    func beginListening() async {
        isLaunching = true
        let granted = await translator.requestPermissions()
        isLaunching = false
        guard granted else {
            diag("app", "microphone permission DENIED")
            micPermissionDenied = true
            errorMessage = strings.micDenied
            return
        }
        hasEverStarted = true
        start()
    }

    /// Ask for the microphone at launch so the first tap goes straight into
    /// listening rather than stopping for a system prompt.
    func prepareAtLaunch() async {
        _ = await translator.requestPermissions()
    }

    /// System took the audio away (backgrounded, phone call, Siri) or gave
    /// it back. User intent is unchanged, so listening resumes by itself.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            diag("app", "backgrounded (listening=\(isListening))")
            DiagnosticLog.shared.flush()
            if isListening {
                resumeWhenActive = true
                stop()
            }
            // Flush first, then send: the last lines written are usually the
            // ones that explain whatever just went wrong. No-op unless an
            // upload URL is configured.
            DiagnosticLog.shared.flush()
            LogUploader.uploadCurrentLog(reason: hasEverStarted ? "session" : "launch")
        case .active:
            diag("app", "foregrounded (resume=\(resumeWhenActive))")
            // Coming back from Settings is the one moment the answer can have
            // changed without us asking. Reading it is free and does not
            // prompt. GitHub #25.
            noteMicPermission(granted: AVAudioApplication.shared.recordPermission == .granted)
            if noteBecameActive() {
                Task { await self.beginListening() }
            }
        default:
            break
        }
    }

    /// Foreground resume. Deliberately shows **no** notice: backgrounding is
    /// frequent and self-inflicted — Heiko put the app away himself — and a
    /// banner on every app switch becomes wallpaper he stops reading. If it
    /// should appear here too, this is the one line to change. GitHub #28.
    @discardableResult
    func noteBecameActive() -> Bool { claimPendingResume() }

    private func handleAudioInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        // Thin caller: every decision below is in the seam, so the whole
        // ownership sequence is reachable from a test. GitHub #28.
        switch type {
        case .began:
            if noteInterruptionBegan() { stop() }
        case .ended:
            if noteInterruptionEnded(options: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) {
                Task { await self.resumeAfterInterruption() }
            }
        @unknown default:
            break
        }
    }

    /// iOS took the audio away mid-conversation. Returns whether it armed an
    /// automatic resume; the caller tears the session down. Split that way so
    /// the arming is reachable from a test without an audio session.
    @discardableResult
    func noteInterruptionBegan() -> Bool {
        diag("app", "audio interrupted (call/Siri/alarm)")
        guard isListening else { return false }
        resumeWhenActive = true
        return true
    }

    #if DEBUG
    /// Test seam for the interruption sequence. Arming requires a live
    /// session, and starting one needs audio hardware a unit test cannot
    /// have — so this forces that single precondition and then runs the REAL
    /// arming path. It touches no audio session: the app's own handler is
    /// what calls `stop()`.
    func simulateInterruptionBeganForTesting() {
        isListening = true
        noteInterruptionBegan()
        isListening = false
    }

    /// Test seam: stand in for a live session so `toggleButton()` takes its
    /// stop branch, which is the one that needs no network. Sets the published
    /// flag only.
    func forceListeningForTesting() { isListening = true }
    #endif

    /// iOS gave the audio back. Returns whether an automatic resume is owed —
    /// the CALLER performs it. Keeping the decision free of the audio session
    /// is what makes the arm → manual start → resume-trigger sequence testable
    /// at all; it was unreachable before, and the failure mode it guards is
    /// the microphone opening without the user asking. GitHub #28.
    @discardableResult
    func noteInterruptionEnded(options raw: UInt?) -> Bool {
        // Recorded, not obeyed — see `mayResume(afterInterruptionOptions:)`
        // for why this stopped being a gate. The device log still says what
        // iOS thought, so the decision stays reviewable against real traffic.
        diag("app", "interruption ended (iOS shouldResume=\(Self.mayResume(afterInterruptionOptions: raw)))")
        return claimPendingResume()
    }

    /// Consume the armed flag, counting the resume. The single place the flag
    /// is spent, so "exactly one start" is a property of one function.
    private func claimPendingResume() -> Bool {
        guard resumeWhenActive else { return false }
        resumeWhenActive = false
        automaticResumeCount += 1
        return true
    }

    /// Resume after an interruption, and say so — but only if it worked.
    ///
    /// `beginListening()` can fail on permission or an audio session that
    /// genuinely cannot activate, which is the case iOS was hinting at when it
    /// withheld `.shouldResume`. Honouring the product decision to resume
    /// anyway makes that path reachable, so the notice waits for the outcome
    /// rather than announcing an intention. GitHub #28.
    private func resumeAfterInterruption() async {
        await beginListening()
        noteAutomaticResumeFinished(started: isListening)
    }

    /// The outcome half of an automatic resume, split out so the rule "notice
    /// only if it actually started" is a function with a test rather than an
    /// ordering inside an async body. `showMicNotice()`'s only caller in the
    /// app is behind this guard. GitHub #28.
    func noteAutomaticResumeFinished(started: Bool) {
        guard started else {
            diag("app", "automatic resume after interruption did NOT start — no notice shown")
            return
        }
        diag("app", "resumed automatically after an interruption")
        showMicNotice()
    }

    /// Raise the notice and start its dismissal clock. Internal rather than
    /// private so L1 can check what it puts on screen; the only caller in the
    /// app is `resumeAfterInterruption()`, after a start has succeeded.
    func showMicNotice() {
        micNoticeDismissal?.cancel()
        micNotice = StatusNotice(text: strings.micResumed, severity: .info)
        micNoticeDismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.micNoticeDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clearMicNotice()
        }
    }

    /// Take the notice down and cancel its timer. Idempotent, so every path
    /// that ends the resumed state can call it without checking first.
    func clearMicNotice() {
        micNoticeDismissal?.cancel()
        micNoticeDismissal = nil
        micNotice = nil
    }

    /// Fills the transcript with a sample conversation so layout work can be
    /// checked in the Simulator without anyone talking. DEBUG only, opt-in:
    ///   xcrun simctl launch booted com.klock.heikotranslate -UITestSeed YES
    private func seedSampleConversationIfRequested() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "UITestBanner") {
            connectionWarning = Self.warning(for: .degraded, in: homeLang)
        }
        guard UserDefaults.standard.bool(forKey: "UITestSeed") else { return }
        messages = [
            Message(original: "Hallo, ich hätte gerne einen großen Hamburger mit extra Salat.",
                    translation: "Hi, I'd like a large hamburger with extra lettuce.", fromHome: true),
            Message(original: "That will cost you about 14 euros.",
                    translation: "Das kostet Sie ungefähr 14 Euro.", fromHome: false),
            Message(original: "Super, can I have that with more onions as well, please?",
                    translation: "Super, kann ich das mit mehr Zwiebeln haben, bitte?", fromHome: false),
            Message(original: "Ich hätte gerne ein großes Kölsch Bier.",
                    translation: "I'd like a large Kölsch beer.", fromHome: true),
            Message(original: "und einen Eimer voller Pommes.",
                    translation: "and a bucket full of fries.", fromHome: true),
        ]
        #endif
    }

    /// Drives the ring animations with synthetic data so they can be SEEN in
    /// the Simulator (which has no usable mic): 4s of voice-like levels,
    /// then 4s of "speaking", repeating. DEBUG only, opt-in:
    ///   xcrun simctl launch booted com.klock.heikotranslate -UITestRings YES
    private func startRingDemoIfRequested() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "UITestRings") else { return }
        isListening = true
        hasEverStarted = true
        var tick = 0.0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                tick += 1.0 / 30.0
                let phase = tick.truncatingRemainder(dividingBy: 8)
                if phase < 4 {
                    self.activity = .understanding
                    // Voice-ish: syllable wobble on a loudness envelope.
                    let envelope = (sin(phase * 1.6) + 1) / 2
                    let syllables = (sin(phase * 11) + 1) / 2
                    self.micLevel = min(1, envelope * (0.35 + 0.65 * syllables))
                } else {
                    self.activity = .translating
                    self.micLevel = 0
                }
            }
        }
        #endif
    }

    // MARK: - Demo replay (DEBUG, for recording the case-study videos)

    #if DEBUG
    /// One spoken turn in a scripted demo conversation.
    private struct DemoTurn {
        let spoken: String
        let translation: String
        /// true → the home language was spoken (bubble lands right).
        let isHome: Bool
        /// How long the person takes to say it.
        let speaking: TimeInterval
    }

    /// Replays a conversation through the REAL UI — live partial text, the
    /// ring animations, the direction flip, the committed bubbles — with
    /// realistic timing and no network. The Simulator has no usable mic, so
    /// this is the only way to film the thing actually working.
    ///
    ///   xcrun simctl launch booted com.klock.heikotranslate -UITestDemo order
    ///
    /// Scripts: `order` (de↔en at a counter), `california` (three languages).
    private func startDemoIfRequested() {
        guard let name = UserDefaults.standard.string(forKey: "UITestDemo") else { return }
        let script: [DemoTurn]
        switch name {
        case "california":
            script = [
                DemoTurn(spoken: "Entschuldigung, wo finde ich hier den Bahnhof?",
                         translation: "Excuse me, where do I find the train station?",
                         isHome: true, speaking: 3.0),
                DemoTurn(spoken: "Two blocks down, then left at the lights.",
                         translation: "Zwei Blocks weiter, dann links an der Ampel.",
                         isHome: false, speaking: 2.6),
                DemoTurn(spoken: "Vielen Dank, das ist sehr nett!",
                         translation: "Thank you, that is very kind!",
                         isHome: true, speaking: 2.2),
            ]
        default:
            script = [
                DemoTurn(spoken: "Guten Tag, ich hätte gerne einen Kaffee.",
                         translation: "Good afternoon, I'd like a coffee.",
                         isHome: true, speaking: 2.8),
                DemoTurn(spoken: "Sure. For here or to go?",
                         translation: "Gerne. Zum Hiertrinken oder zum Mitnehmen?",
                         isHome: false, speaking: 2.0),
                DemoTurn(spoken: "Zum Mitnehmen, bitte. Was kostet das?",
                         translation: "To go, please. What does that cost?",
                         isHome: true, speaking: 2.6),
                DemoTurn(spoken: "Three fifty. Cash or card is fine.",
                         translation: "Drei fünfzig. Bar oder Karte, beides geht.",
                         isHome: false, speaking: 2.4),
            ]
        }

        isListening = true
        hasEverStarted = true
        messages = []
        Task { @MainActor in
            // Settle on the resting screen first so the loop has a clean seam.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            for turn in script {
                await self.playDemoTurn(turn)
            }
            self.activity = .idle
            self.micLevel = 0
        }
    }

    private func playDemoTurn(_ turn: DemoTurn) async {
        liveIsHome = turn.isHome
        activity = .understanding
        let words = turn.spoken.split(separator: " ").map(String.init)
        let perWord = turn.speaking / Double(max(1, words.count))
        var shown: [String] = []
        for word in words {
            shown.append(word)
            liveTranscript = shown.joined(separator: " ")
            // Voice-like level so the listening rings breathe with the speech.
            let steps = max(1, Int(perWord / 0.04))
            for i in 0..<steps {
                let t = Double(i) / Double(steps)
                micLevel = min(1, 0.30 + 0.70 * abs(sin(t * .pi)) * Double.random(in: 0.6...1.0))
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        micLevel = 0
        // The speaker stops; the translation is spoken back.
        try? await Task.sleep(nanoseconds: 500_000_000)
        activity = .translating
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        messages.append(Message(original: turn.spoken,
                                translation: turn.translation,
                                fromHome: turn.isHome))
        liveTranscript = ""
        liveIsHome = nil
        activity = .idle
        try? await Task.sleep(nanoseconds: 700_000_000)
    }
    #endif

    init() {
        // Remote-support hatch. Picking German on the PARTNER wheel swaps the
        // sides, which is the correct gesture in general but leaves this app
        // showing English as the large line — wrong for the one person it is
        // for, and not obvious to undo if you do not read English. Launch with
        //   xcrun devicectl device process launch --device <id> \
        //     com.klock.heikotranslate -ResetLanguagePair YES
        // to put German back on the home side.
        let resetPair = UserDefaults.standard.bool(forKey: "ResetLanguagePair")
        homeLang = resetPair ? Self.defaultHomeLang
                             : Self.loadLang("settings.homeLang", default: Self.defaultHomeLang)
        partnerLang = resetPair ? Self.defaultPartnerLang
                                : Self.loadLang("settings.partnerLang", default: Self.defaultPartnerLang)
        if homeLang == partnerLang { partnerLang = homeLang == .en ? .de : .en }
        if resetPair {
            // Property observers do not fire during init, so write it through
            // by hand — otherwise the reset lasts only for this launch.
            UserDefaults.standard.set(homeLang.rawValue, forKey: "settings.homeLang")
            UserDefaults.standard.set(partnerLang.rawValue, forKey: "settings.partnerLang")
            diag("app", "language pair RESET to \(homeLang.rawValue)↔\(partnerLang.rawValue)")
        }
        seedSampleConversationIfRequested()
        startRingDemoIfRequested()
        #if DEBUG
        startDemoIfRequested()
        #endif
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleAudioInterruption(note) }
        }
    }

    private func start() {
        errorMessage = nil
        // A fresh start re-judges the connection — never resurrect a warning
        // frozen at mute time (nothing publishes quality while muted), or
        // "Keine Internetverbindung." sits over "Verbinde…" on a healthy
        // network. The service resets its quality state to match.
        connectionWarning = nil
        do {
            try translator.start(
                home: homeLang,
                partner: partnerLang,
                onPartialInput: { [weak self] text in
                    self?.liveTranscript = text
                },
                onUtterance: { [weak self] original, translation, wasHome in
                    guard let self, !original.isEmpty else { return }
                    self.messages.append(Message(original: original, translation: translation, fromHome: wasHome))
                    self.liveTranscript = ""
                    // Translation is flowing, so the connection evidently
                    // works — don't leave a stale error banner up.
                    self.errorMessage = nil
                },
                onActivity: { [weak self] activity in
                    self?.activity = activity
                },
                onError: { [weak self] message in
                    self?.errorMessage = self?.strings.connectionError
                    print("GeminiLiveTranslationService error: \(message)")
                },
                onInputLevel: { [weak self] level in
                    // Smooth the jitter out, but let a rise through fast so
                    // the flag moves the moment someone starts talking.
                    guard let self else { return }
                    self.micLevel = level > self.micLevel
                        ? level
                        : self.micLevel * 0.8 + level * 0.2
                },
                onDirection: { [weak self] isHome in
                    self?.liveIsHome = isHome
                },
                onServerRecovered: { [weak self] in
                    self?.errorMessage = nil
                },
                onSessionsExhausted: { [weak self] in
                    // Both sides failed for good. Drop to the muted state so
                    // the button reads "Mikrofon pausiert" and tapping it is
                    // the obvious next move — the existing error line already
                    // says "bitte nochmal versuchen". Leaving the spinner up
                    // beside that error was two contradictory claims at once.
                    // GitHub #4, SPEC R8.
                    self?.stop()
                },
                onConnectionQuality: { [weak self] quality in
                    guard let self else { return }
                    self.connectionWarning = Self.warning(for: quality, in: self.homeLang)
                }
            )
            isListening = true
        } catch {
            diag("app", "start FAILED: \(error.localizedDescription)")
            errorMessage = strings.micFailed
        }
    }

    private func stop() {
        translator.stopSession()
        // The notice describes a listening state that is now over — it must
        // never linger over "Mikrofon pausiert". GitHub #28.
        clearMicNotice()
        isListening = false
        activity = .idle
        liveTranscript = ""
        liveIsHome = nil
        micLevel = 0
    }
}
