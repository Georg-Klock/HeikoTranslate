import AVFoundation
import XCTest
@testable import HeikoTranslate

/// L1 tests for the language-pair observers on the REAL `ConversationViewModel`.
///
/// These live outside `TurnLogicTests` on purpose. The bug they exist for
/// (GitHub #1) was not in any function — it was in the wiring between two
/// `@Published` property observers, where a `defer`-released re-entrancy flag
/// let one user gesture apply the pair twice. A pure-logic test could not have
/// seen it; only driving the actual observed properties can. Test IDs match
/// TESTING.md §L1.
@MainActor
final class LanguagePairTests: XCTestCase {

    /// Puts the pair in a known state and returns the view model plus the
    /// apply-count baseline, so each test measures only its own gesture.
    /// Property observers do not fire during `init`, so the count starts at 0
    /// and these two assignments are what move it.
    private func makeViewModel() -> (ConversationViewModel, Int) {
        let vm = ConversationViewModel()
        vm.homeLang = .de
        vm.partnerLang = .en
        return (vm, vm.languageApplyCount)
    }

    /// L1.47 — a fresh install opens on ME: German, YOU: English.
    ///
    /// The pair Heiko needs, on the sides he needs it. Home is the large line
    /// and the right-hand bubble, so home must be German; getting it backwards
    /// ships an app whose main text is in a language he cannot read, and he
    /// cannot be talked through fixing it over the phone.
    ///
    /// Pins the CONSTANTS and the fallback path, deliberately not a
    /// `ConversationViewModel()` with the stored keys cleared. That was the
    /// first attempt and it is not reliable: the test host carries its own
    /// `UserDefaults`, and a `removeObject` immediately followed by a read
    /// still returned a previous run's value, so the test failed while the app
    /// was correct. Verified separately against a wiped simulator container —
    /// a genuine first launch opens Englisch / Deutsch.
    ///
    /// Pinned by product decision, 2026-08-07.
    func testL1_47_freshInstallOpensGermanHomeEnglishPartner() {
        XCTAssertEqual(ConversationViewModel.defaultHomeLang, .de,
                       "ME must default to German — it is the large line Heiko reads")
        XCTAssertEqual(ConversationViewModel.defaultPartnerLang, .en,
                       "YOU must default to English")

        // And the loader really does fall back when nothing is stored — a key
        // that cannot exist, so this holds whatever this machine has persisted.
        let absent = "settings.homeLang.\(UUID().uuidString)"
        XCTAssertEqual(ConversationViewModel.loadLang(absent, default: ConversationViewModel.defaultHomeLang), .de)
        XCTAssertEqual(ConversationViewModel.loadLang(absent, default: ConversationViewModel.defaultPartnerLang), .en)
    }

    /// L1.29 — picking the home language on the PARTNER wheel swaps the sides
    /// and applies the pair exactly once.
    ///
    /// Before the fix this ran twice: the partner observer's nested
    /// `homeLang = oldValue` fired the home observer, which applied and, via
    /// `defer`, released the guard before the partner observer's own trailing
    /// apply. Two applies mid-conversation meant two `stop()`/`beginListening()`
    /// cycles racing — a duplicate `installTap` (which traps) and a set of
    /// orphaned, still-billed WebSocket sessions.
    func testL1_29_collidingPartnerPickAppliesPairExactlyOnce() {
        let (vm, baseline) = makeViewModel()

        vm.partnerLang = .de  // collides with home

        XCTAssertEqual(vm.languageApplyCount - baseline, 1,
                       "one settings gesture must apply the pair exactly once")
        XCTAssertEqual(vm.partnerLang, .de, "the picked language takes the partner side")
        XCTAssertEqual(vm.homeLang, .en, "home takes the partner's previous language (SPEC §4.4 swap)")
    }

    /// L1.29b — the same gesture on the HOME wheel. Symmetric observer, same
    /// re-entrancy shape, so it needs its own coverage.
    func testL1_29b_collidingHomePickAppliesPairExactlyOnce() {
        let (vm, baseline) = makeViewModel()

        vm.homeLang = .en  // collides with partner

        XCTAssertEqual(vm.languageApplyCount - baseline, 1,
                       "one settings gesture must apply the pair exactly once")
        XCTAssertEqual(vm.homeLang, .en)
        XCTAssertEqual(vm.partnerLang, .de)
    }

    /// L1.29c — an ordinary non-colliding pick still applies, exactly once.
    /// Guards against "fix" the other direction: silencing the observer so
    /// thoroughly that a normal language change stops taking effect.
    func testL1_29d_nonCollidingPickStillAppliesOnce() {
        let (vm, baseline) = makeViewModel()

        vm.partnerLang = .es

        XCTAssertEqual(vm.languageApplyCount - baseline, 1)
        XCTAssertEqual(vm.partnerLang, .es)
        XCTAssertEqual(vm.homeLang, .de, "an unrelated side must not move")
    }

    /// L1.32 — an error suppresses the "tap to speak" hint.
    ///
    /// On a denied microphone permission `hasEverStarted` stays false, so the
    /// hint's other conditions all still hold and it sat on screen next to
    /// "Kein Mikrofonzugriff…" — one line saying tap to speak, the other saying
    /// tapping will not work. Permanently, because iOS only prompts once.
    /// GitHub #25.
    func testL1_32_errorSuppressesTheStartHint() {
        let vm = ConversationViewModel()
        XCTAssertNotNil(vm.startHint, "before any error the hint is the whole point")

        vm.errorMessage = "Kein Mikrofonzugriff. Zum Öffnen der Einstellungen antippen."
        XCTAssertNil(vm.startHint,
                     "the hint must not contradict an error telling the user tapping cannot work")

        vm.errorMessage = nil
        XCTAssertNotNil(vm.startHint, "and it comes back once the error clears")
    }

    /// L1.42 — a denied microphone recovers when the user grants it in Settings.
    ///
    /// Nothing used to clear `micPermissionDenied`, so recovery relied entirely
    /// on iOS killing the app when the switch is toggled. The case that leaves
    /// behind: Heiko opens Settings, does not understand it, backs out — and
    /// the one button is a Settings shortcut forever, unable to start listening
    /// again. GitHub #25.
    func testL1_42_grantingInSettingsClearsTheDenial() {
        let vm = ConversationViewModel()
        vm.errorMessage = "Kein Mikrofonzugriff. Zum Öffnen der Einstellungen antippen."
        vm.forceMicPermissionDeniedForTesting()
        XCTAssertTrue(vm.micPermissionDenied)

        // Back from Settings, still denied: nothing changes.
        vm.noteMicPermission(granted: false)
        XCTAssertTrue(vm.micPermissionDenied, "still refused — the button still opens Settings")
        XCTAssertNotNil(vm.errorMessage)

        // Back from Settings, now granted: the app is usable again.
        vm.noteMicPermission(granted: true)
        XCTAssertFalse(vm.micPermissionDenied)
        XCTAssertNil(vm.errorMessage, "the error must go with it, or the hint stays suppressed")
        XCTAssertNotNil(vm.startHint, "and 'tap to speak' comes back")
    }

    // MARK: - GitHub #28

    /// L1.39 — the warning's severity comes from the connection quality, not
    /// from how the German copy happens to start.
    ///
    /// The view used to pick its colour with `warning.hasPrefix("Schlechte")`,
    /// so rewording the degraded warning would have silently turned it red with
    /// nothing failing. Copy is not a control channel.
    func testL1_39_warningSeverityTracksQualityNotSpelling() {
        typealias VM = ConversationViewModel
        XCTAssertNil(VM.warning(for: .good))

        XCTAssertEqual(VM.warning(for: .degraded)?.severity, .degraded)
        XCTAssertEqual(VM.warning(for: .silent)?.severity, .lost)
        XCTAssertEqual(VM.warning(for: .offline)?.severity, .lost)

        // The specific thing that used to be load-bearing: only ONE of the
        // three warnings starts with "Schlechte", and the other two were
        // therefore red by accident rather than by decision.
        let warnings = [VM.warning(for: .degraded), VM.warning(for: .silent), VM.warning(for: .offline)]
            .compactMap { $0 }
        XCTAssertEqual(warnings.count, 3)
        XCTAssertEqual(warnings.filter { $0.text.hasPrefix("Schlechte") }.count, 1,
                       "if a reword makes this 0 or 2, the old prefix rule would have mispainted")
        // No connection warning is ever informational — that severity belongs
        // to the mic notice, and sharing the type must not blur the two.
        XCTAssertFalse(warnings.contains { $0.severity == .info })
    }

    /// L1.40 — what iOS says about resuming is RECORDED, not obeyed.
    ///
    /// The parser stays exact so the device log can be trusted, but it no
    /// longer gates the resume: a product decision (2026-08-05) that a silent
    /// stop Heiko does not notice is worse than an unexpected start he can
    /// see. L1.41c is the half that proves it is no longer a gate.
    func testL1_40_interruptionOptionsAreParsedExactly() {
        typealias VM = ConversationViewModel
        XCTAssertTrue(VM.mayResume(afterInterruptionOptions: nil),
                      "no options key at all reads as no objection")
        XCTAssertTrue(VM.mayResume(
            afterInterruptionOptions: AVAudioSession.InterruptionOptions.shouldResume.rawValue))
        XCTAssertFalse(VM.mayResume(afterInterruptionOptions: 0),
                       "options present without .shouldResume is an explicit no")
    }

    /// L1.41c — THE OWNERSHIP SEQUENCE: interruption arms a resume, the user
    /// starts by hand, the interruption ends — and that must produce exactly
    /// ONE start, not two.
    ///
    /// This is the sequence #28 was filed for and that the first attempt could
    /// not test at all: arming needs `isListening`, and the notification
    /// handler was private, so the fix rested entirely on a doc comment. It
    /// matters more than usual because the failure mode is the microphone
    /// opening without the user asking for it. The decision is now split out
    /// of the handler — the handler performs what the seam decides — so the
    /// whole sequence is reachable without an audio session.
    func testL1_41c_aManualStartTakesOwnershipOfAPendingResume() {
        let vm = ConversationViewModel()
        XCTAssertEqual(vm.automaticResumeCount, 0)

        // 1. Phone call: the interruption arms an automatic resume.
        vm.simulateInterruptionBeganForTesting()
        XCTAssertTrue(vm.resumeWhenActive)

        // 2. The user taps and starts listening again by hand.
        vm.noteManualToggle()
        XCTAssertFalse(vm.resumeWhenActive, "a manual tap owns the session")

        // 3. The call ends. Nothing may start — the user already did.
        XCTAssertFalse(vm.noteInterruptionEnded(options: nil))
        // Nor at the next foreground, which used to be the second trigger.
        XCTAssertFalse(vm.noteBecameActive())
        XCTAssertEqual(vm.automaticResumeCount, 0, "exactly zero starts the user did not ask for")

        // And the tap handler really is what takes ownership — asserting only
        // on the seam would leave the same unreachable branch #28 shipped with.
        // Driven in the STOP direction because it needs no session to start;
        // `noteManualToggle()` runs before the branch either way.
        let tapped = ConversationViewModel()
        tapped.simulateInterruptionBeganForTesting()
        tapped.forceListeningForTesting()
        tapped.showMicNotice()
        tapped.toggleButton()
        XCTAssertFalse(tapped.resumeWhenActive, "toggleButton must consume the pending resume")
        XCTAssertFalse(tapped.isListening)
        XCTAssertNil(tapped.micNotice, "and the notice cannot outlive the listening state")
    }

    /// L1.41d — the flag is spent exactly once, and iOS's hint no longer gates
    /// it. An armed interruption resumes even when iOS withholds
    /// `.shouldResume` (the founder's decision — alarms and timers are the
    /// common case, and staying paused left Heiko silently muted), and a
    /// second trigger does not resume again.
    func testL1_41d_anArmedResumeFiresOnceRegardlessOfTheSystemHint() {
        let vm = ConversationViewModel()
        vm.simulateInterruptionBeganForTesting()

        // options WITHOUT .shouldResume — iOS objecting. We resume anyway.
        XCTAssertFalse(ConversationViewModel.mayResume(afterInterruptionOptions: 0),
                       "precondition: this is the case iOS objects to")
        XCTAssertTrue(vm.noteInterruptionEnded(options: 0),
                      "the hint is diagnostic now, not a gate")
        XCTAssertEqual(vm.automaticResumeCount, 1)

        // The flag is spent: neither a repeat notification nor a foreground
        // may start a second time.
        XCTAssertFalse(vm.noteInterruptionEnded(options: 0))
        XCTAssertFalse(vm.noteBecameActive())
        XCTAssertEqual(vm.automaticResumeCount, 1, "exactly one")
    }

    /// L1.41e — the mic notice is informational, and a manual tap clears it
    /// immediately: it must never linger over a state the user has since
    /// changed by hand.
    func testL1_41e_theMicNoticeIsInformationalAndClearsOnAManualTap() {
        let vm = ConversationViewModel()
        XCTAssertNil(vm.micNotice)

        // A resume that did NOT start shows no NOTICE — "the microphone is on
        // again" over a start that did not happen is worse than silence — but
        // it no longer says NOTHING: the tap prompt goes to the errorMessage
        // layer, because the failed state has statusShowsMuted true and the
        // notice slot's precedence would never render a notice (GitHub #5).
        vm.noteAutomaticResumeFinished(started: false)
        XCTAssertNil(vm.micNotice, "a failed resume must not announce a resume")
        XCTAssertEqual(vm.errorMessage, vm.strings.micResumeFailed,
                       "the reader gets an ACTION, not a statement of failure")
        XCTAssertNotEqual(vm.strings.micResumeFailed, vm.strings.micFailed,
                          "the manual-failure copy is deliberately different and unchanged")

        vm.noteAutomaticResumeFinished(started: true)
        XCTAssertEqual(vm.micNotice?.severity, .info, "informational — not styled as a warning")
        // The notice is written in the HOME language now, whatever the
        // persisted pair happens to be — so assert against that rather than
        // against German, which only passed while German was hardcoded.
        XCTAssertEqual(vm.micNotice?.text, vm.strings.micResumed)
        // The issue's extension to this test: a SUCCESSFUL resume carries no
        // error — and it clears a failed attempt's prompt, which must not
        // outlive the state it described. GitHub #5.
        XCTAssertNil(vm.errorMessage, "success shows the notice and no error")

        vm.noteManualToggle()
        XCTAssertNil(vm.micNotice)

        // Idempotent: every path that ends the resumed state calls this, and
        // none of them should have to check first.
        vm.clearMicNotice()
        XCTAssertNil(vm.micNotice)
    }

    /// L1.41f — the precedence for the one slot under the button.
    ///
    /// The warning is a condition and the notice is an event; they are separate
    /// properties precisely so neither clobbers the other, which means
    /// something has to decide which is drawn when both are set. Pinned here
    /// rather than left implicit in the view.
    func testL1_41f_theBottomSlotHasOneExplicitPrecedence() {
        typealias VM = ConversationViewModel
        let warning = VM.warning(for: .degraded)
        let notice = VM.StatusNotice(text: "Mikrofon wieder aktiv — die Übersetzung läuft weiter.",
                                     severity: .info)

        // Muted outranks everything — the red "Mikrofon pausiert" is the truth
        // that matters while the app is not listening.
        XCTAssertNil(VM.bottomNotice(muted: true, warning: warning, micNotice: notice))
        XCTAssertNil(VM.bottomNotice(muted: true, warning: nil, micNotice: notice))

        // A standing warning outranks the newer event.
        XCTAssertEqual(VM.bottomNotice(muted: false, warning: warning, micNotice: notice), warning)
        // …and the notice shows when nothing outranks it.
        XCTAssertEqual(VM.bottomNotice(muted: false, warning: nil, micNotice: notice), notice)
        // Nothing set, nothing drawn — the status line shows through.
        XCTAssertNil(VM.bottomNotice(muted: false, warning: nil, micNotice: nil))
    }

    /// Puts the view model in a listening state with a known running pair,
    /// without audio hardware. `serviceStartForTesting` stands in for the
    /// audio-and-network step, and the real `start()` records the pair around
    /// it — which is the thing these tests are about.
    private func makeListeningViewModel(
        home: TurnLogic.Lang = .de, partner: TurnLogic.Lang = .en
    ) async -> ConversationViewModel {
        let vm = ConversationViewModel()
        vm.homeLang = home
        vm.partnerLang = partner
        vm.serviceStartForTesting = { true }
        await vm.beginListening()
        return vm
    }

    /// L1.45 — a whole spin of the wheel touches no connection; the pair
    /// reaches the sessions once, when the sheet closes.
    ///
    /// The wheels are rotaries: a flick crosses several notches and each notch
    /// is a language change. Every one of them used to tear both WebSocket
    /// sessions down and rebuild them (GitHub #1's churn by a new route), and
    /// the 0.4s settle delay that replaced it still produced five full
    /// restarts for one language change on device — a deliberate scroll rests
    /// between detents for longer than any responsive interval. GitHub #146.
    ///
    /// Persisting still happens per notch, so the stored pair is always the
    /// truth. Only the restart waits, and it waits for a signal rather than a
    /// clock.
    func testL1_45_aSpinReachesTheSessionsOnceOnDismiss() async {
        let vm = await makeListeningViewModel()
        let baseline = vm.languageApplyCount
        XCTAssertEqual(vm.languageRestartCount, 0)

        for lang in [TurnLogic.Lang.es, .fr, .ko, .zh, .es, .fr] {
            vm.partnerLang = lang
        }
        XCTAssertEqual(vm.languageApplyCount - baseline, 6,
                       "every notch still persists — only the restart waits")
        XCTAssertEqual(vm.languageRestartCount, 0,
                       "the sheet is still open: nothing may reach the sessions")

        // Long enough that any reintroduced settle timer would have fired.
        // This is the assertion that distinguishes "waits for dismissal" from
        // "waits a bit longer": the old 0.4s debounce passes the check above
        // and fails this one.
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(vm.languageRestartCount, 0,
                       "no clock may restart the sessions — only the dismissal")

        vm.languageSelectionDidFinish()
        XCTAssertEqual(vm.languageRestartCount, 1, "six notches, one restart")
    }

    /// L1.45b — opening the sheet and closing it again is free.
    ///
    /// The expensive reading of "changing it restarts the translation" is that
    /// any visit to the sheet costs a reconnect. Dismissing without choosing
    /// anything different must not interrupt a conversation in progress.
    func testL1_45b_dismissingWithoutAChangeRestartsNothing() async {
        let vm = await makeListeningViewModel(home: .de, partner: .en)

        vm.languageSelectionDidFinish()
        XCTAssertEqual(vm.languageRestartCount, 0, "same pair, nothing to do")

        // Scrolled away and back again: the pair the sessions run never
        // changed, so neither should the sessions.
        vm.partnerLang = .fr
        vm.partnerLang = .ko
        vm.partnerLang = .en
        vm.languageSelectionDidFinish()
        XCTAssertEqual(vm.languageRestartCount, 0,
                       "a value scrolled past is not a value chosen")
    }

    /// L1.45c — with nothing listening there is nothing to restart. The next
    /// start reads the stored pair, which every notch has already written.
    func testL1_45c_aChangeWhileStoppedRestartsNothing() {
        let (vm, _) = makeViewModel()
        vm.partnerLang = .fr
        vm.languageSelectionDidFinish()
        XCTAssertEqual(vm.languageRestartCount, 0)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.partnerLang"), "fr",
                       "the choice still persists — only the restart is conditional")
    }

    /// L1.46 — on a cold launch the NOTICE stays silent while the GLYPH
    /// reads muted. Two rules, and they disagree here on purpose.
    ///
    /// The mic glyph is amber and struck through before the first tap. That
    /// is **Georg's decision, 2026-08-07**, taken after seeing the
    /// alternative on his own phone: the slash is what makes "Zum Sprechen
    /// antippen" legible, because it shows the state the tap is about to
    /// change. A plain white mic at rest reads as a mic already listening,
    /// which is the more expensive misreading.
    ///
    /// The "Mikrofon pausiert" NOTICE is the opposite: it announces something
    /// the user did, so it needs a session they actually started. Announcing
    /// "paused" to someone who has never pressed anything is noise.
    ///
    /// This test exists because the distinction is invisible in every state
    /// but this one, and because two separate sessions have now read the
    /// glyph's behaviour as a bug and "fixed" it. It is not a bug.
    func testL1_46_aColdLaunchIsMutedGlyphButSilentNotice() {
        let vm = ConversationViewModel()
        XCTAssertTrue(vm.statusIsPaused,
                      "nothing is listening yet")
        XCTAssertTrue(vm.micReadsAsMuted,
                      "the glyph IS amber and struck through before the first tap — a product decision, not a defect")
        XCTAssertFalse(vm.statusShowsMuted,
                       "but the notice stays silent: nothing was paused, because nothing was ever started")
        XCTAssertNotNil(vm.startHint,
                        "and the hint asking for that tap is on screen at the same moment")
    }

    /// L1.46c — the glyph's rule over every combination.
    ///
    /// Pure, so it reaches states an instance cannot be put into without
    /// audio hardware. The rule: the glyph is muted whenever nothing is
    /// listening AND nothing is starting up — `hasEverStarted` deliberately
    /// does not appear, which is the only difference from `readsAsMuted`.
    func testL1_46c_theGlyphIsMutedWheneverNothingIsRunning() {
        typealias VM = ConversationViewModel

        XCTAssertTrue(VM.glyphReadsAsMuted(isListening: false, isLaunching: false),
                      "at rest — including the very first frame after launch")

        XCTAssertFalse(VM.glyphReadsAsMuted(isListening: false, isLaunching: true),
                       "starting up is not muted — the spinner owns that moment")
        for launching in [true, false] {
            XCTAssertFalse(VM.glyphReadsAsMuted(isListening: true, isLaunching: launching),
                           "a live session is never drawn muted")
        }

        // The two rules agree everywhere EXCEPT the cold launch. That single
        // disagreement is the whole point of having two of them.
        for listening in [true, false] {
            for launching in [true, false] {
                let glyph = VM.glyphReadsAsMuted(isListening: listening, isLaunching: launching)
                let notice = VM.readsAsMuted(isListening: listening, isLaunching: launching,
                                             hasEverStarted: true)
                XCTAssertEqual(glyph, notice,
                               "once a session has been started the two rules must agree")
            }
        }
        XCTAssertNotEqual(VM.glyphReadsAsMuted(isListening: false, isLaunching: false),
                          VM.readsAsMuted(isListening: false, isLaunching: false,
                                          hasEverStarted: false),
                          "and they must differ on the cold launch — that is the decision")
    }

    /// L1.46b — the whole muted-appearance rule, over every combination.
    ///
    /// `readsAsMuted` is pure so this can reach states a `ConversationViewModel`
    /// cannot be put into without audio hardware — mid-launch, and listening.
    /// The instance test above only reaches the cold-launch corner, which is
    /// exactly one of the eight.
    ///
    /// The rule in one line: **muted means the user turned it off**, so it
    /// needs a session they actually started. Never started, or still
    /// starting, is not muted. GitHub #43.
    func testL1_46b_mutedRequiresASessionTheUserStarted() {
        typealias VM = ConversationViewModel

        // The only state that is muted: stopped, not launching, has run before.
        XCTAssertTrue(VM.readsAsMuted(isListening: false, isLaunching: false, hasEverStarted: true))

        // Never started — the cold launch this PR is about.
        XCTAssertFalse(VM.readsAsMuted(isListening: false, isLaunching: false, hasEverStarted: false),
                       "a mic the user has never switched on is not a mic they muted")

        // Still starting: "Verbinde…" is not "off", whether or not it has run before.
        for everStarted in [true, false] {
            XCTAssertFalse(VM.readsAsMuted(isListening: false, isLaunching: true, hasEverStarted: everStarted),
                           "connecting must not draw the slash — the app is on its way up")
        }

        // Listening is never muted, whatever the other flags say.
        for launching in [true, false] {
            for everStarted in [true, false] {
                XCTAssertFalse(VM.readsAsMuted(isListening: true, isLaunching: launching,
                                               hasEverStarted: everStarted),
                               "a live session is not muted under any combination")
            }
        }

        // And the instance property is that rule, not a second copy of it.
        let vm = ConversationViewModel()
        XCTAssertEqual(vm.statusShowsMuted,
                       VM.readsAsMuted(isListening: vm.isListening,
                                       isLaunching: vm.isLaunching,
                                       hasEverStarted: vm.hasEverStarted))
    }

    // MARK: - GitHub #90

    /// Seeds the persisted pair and returns the undo. The keys are
    /// process-wide — every test in this process reads the same
    /// `UserDefaults.standard` — so a seeded value must not outlive its
    /// test. Call the returned closure in a `defer`.
    private func seedStoredPair(home: String, partner: String) -> () -> Void {
        let defaults = UserDefaults.standard
        let prior = [("settings.homeLang", defaults.string(forKey: "settings.homeLang")),
                     ("settings.partnerLang", defaults.string(forKey: "settings.partnerLang"))]
        defaults.set(home, forKey: "settings.homeLang")
        defaults.set(partner, forKey: "settings.partnerLang")
        return {
            for (key, value) in prior {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
    }

    /// L1.75c — a PERSISTED partner-only home is repaired during init.
    ///
    /// The #30 belt in `homeLang`'s `didSet` reverts a partner-only write —
    /// but property observers do not fire during `init`, and init is the one
    /// path a bad STORED value actually arrives by. Not reachable by any
    /// shipped build (the didSet reverts before anything persists); this is
    /// defense-in-depth for future migrations and hand-edited containers.
    /// GitHub #90.
    func testL1_75c_aPersistedPartnerOnlyHomeIsRepairedAtInit() {
        let restore = seedStoredPair(home: "tl", partner: "en")
        defer { restore() }

        let vm = ConversationViewModel()
        XCTAssertEqual(vm.homeLang, ConversationViewModel.defaultHomeLang,
                       "a stored tl home must not seat — it has no UI set")
        XCTAssertEqual(vm.partnerLang, .en,
                       "the partner side was valid and is not the repair's business")
        // And the repair must reach the STORE, or it lasts exactly one launch.
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.homeLang"),
                       vm.homeLang.rawValue, "the persisted home is repaired too")

        // Same repair when the fallback COLLIDES with the stored partner:
        // the distinct-pair fix must re-run after it, and the store must end
        // up with the pair that is actually on screen. (The outer restore
        // still holds the true priors, so this seed's undo can be dropped.)
        _ = seedStoredPair(home: "vi", partner: "de")
        let vm2 = ConversationViewModel()
        XCTAssertEqual(vm2.homeLang, ConversationViewModel.defaultHomeLang)
        XCTAssertNotEqual(vm2.homeLang, vm2.partnerLang,
                          "the distinct-pair fix must re-run after the repair")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.homeLang"),
                       vm2.homeLang.rawValue)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.partnerLang"),
                       vm2.partnerLang.rawValue,
                       "the store must match the screen, or next launch re-repairs forever")
    }

    /// L1.75d — a legitimate persisted pair rides through the same init path
    /// untouched, in memory AND in the store. A partner-only PARTNER is a
    /// legitimate state — tl on the partner side is exactly where it belongs
    /// — so the repair must not so much as rewrite it. GitHub #90.
    func testL1_75d_aLegitimatePersistedPairLoadsUnchanged() {
        let restore = seedStoredPair(home: "es", partner: "fr")
        defer { restore() }

        let vm = ConversationViewModel()
        XCTAssertEqual(vm.homeLang, .es)
        XCTAssertEqual(vm.partnerLang, .fr)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.homeLang"), "es",
                       "a valid stored value is not rewritten")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.partnerLang"), "fr")

        _ = seedStoredPair(home: "de", partner: "tl")
        let vm2 = ConversationViewModel()
        XCTAssertEqual(vm2.homeLang, .de)
        XCTAssertEqual(vm2.partnerLang, .tl,
                       "partner-only means partner is allowed — the repair is home-side only")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.partnerLang"), "tl")
    }

    /// L1.29e — the pair is never left with both sides equal, whichever wheel
    /// moved. R-invariant behind the swap: two identical sessions would both
    /// claim every turn.
    func testL1_29e_pairIsAlwaysTwoDistinctLanguages() {
        // allCases, not a hand-written list: the old one stopped at fr, so
        // ko and zh — selectable on the real wheels — were claimed covered
        // and weren't. A future Lang case joins this invariant on the day
        // it is added, not when someone remembers. GitHub #22.
        for lang in TurnLogic.Lang.allCases {
            let (vm, _) = makeViewModel()
            vm.partnerLang = lang
            XCTAssertNotEqual(vm.homeLang, vm.partnerLang,
                              "picking \(lang.rawValue) on the partner wheel left both sides equal")
            let (vm2, _) = makeViewModel()
            vm2.homeLang = lang
            XCTAssertNotEqual(vm2.homeLang, vm2.partnerLang,
                              "picking \(lang.rawValue) on the home wheel left both sides equal")
        }
    }
}
