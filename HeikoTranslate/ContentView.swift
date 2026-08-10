import SwiftUI

/// The screen's colours, sampled from the Figma render at 1x rather than
/// eyeballed — every value here is a measured pixel from the mock
/// (`kVIFjrXtrjwKw1bbAkdyEH`, node 1:50). Named so a redesign changes one
/// place instead of eleven call sites.
enum Palette {
    // Background: near-black at the top, lifting to a faint indigo at the
    // bottom so the mic button sits in a pool of light rather than a void.
    static let backgroundTop = Color(red: 0.004, green: 0.004, blue: 0.012)     // #010103
    static let backgroundBottom = Color(red: 0.055, green: 0.055, blue: 0.114)  // #0E0E1D

    // Bubbles. HOME is the indigo one — SPEC §4.1 keeps it on the right.
    static let homeBubble = Color(red: 0.102, green: 0.075, blue: 0.184)        // #1A132F
    static let homeBubbleStroke = Color(red: 0.286, green: 0.204, blue: 0.506)  // #493481
    static let foreignBubble = Color(red: 0.157, green: 0.157, blue: 0.180)     // #28282E
    static let foreignBubbleStroke = Color(red: 0.282, green: 0.282, blue: 0.302) // #48484D

    /// The language pill. Unchanged from the old settings pill — the mock
    /// measures #242424, which is exactly the `white: 0.14` already shipped.
    static let pill = Color(white: 0.14)

    // The one button.
    static let micButton = Color(red: 0.161, green: 0.161, blue: 0.208)         // #292935
    static let micButtonActive = Color(red: 0.231, green: 0.231, blue: 0.278)
    static let micButtonStroke = Color(red: 0.388, green: 0.388, blue: 0.435)   // #63636F

    /// Voice rings. The mock's rings read as a faint lavender against the
    /// background rather than the plain white they were.
    static let ring = Color(red: 0.60, green: 0.60, blue: 0.92)

    /// Muted. Amber rather than red: the microphone being off is a STATE the
    /// user chose, not a failure — red is reserved for things that broke.
    static let muted = Color(red: 1.0, green: 0.70, blue: 0.20)

    // Settings sheet.
    static let sheetBackground = Color(red: 0.059, green: 0.059, blue: 0.082)  // #0F0F15
    static let card = Color(red: 0.114, green: 0.114, blue: 0.149)             // #1D1D26
}

/// The language pill's geometry, in one place because two views depend on it:
/// the pill draws itself with these numbers, and the transcript's fade uses
/// them to finish dissolving BEFORE the pill's lower edge. Get that wrong and
/// scrolled text emerges sharply from behind an opaque capsule — which is
/// exactly what the first simulator capture of this design showed.
private enum PillLayout {
    /// Below the status bar / Dynamic Island.
    static let topGap: CGFloat = 4
    /// 30pt flags, 22pt either side of the ellipsis, 20/8 padding — all read
    /// out of the Figma (node 1:70) rather than eyeballed.
    static let flagSize: CGFloat = 30
    static let gap: CGFloat = 22
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 8
    /// Emoji render at roughly 1.2x their point size.
    static var height: CGFloat { flagSize * 1.2 + verticalPadding * 2 }
    /// The pill's lower edge, measured from the safe-area top.
    static var bottomEdge: CGFloat { topGap + height }
    /// How far below that edge the transcript ramps back to full strength.
    static let fadeIn: CGFloat = 40
    /// Where a resting bubble may start: clear of the pill and of its fade.
    static var clearance: CGFloat { bottomEdge + fadeIn }
}

/// Liquid Glass where the design asks for it, with the shipped solid fill as
/// the floor. The deployment target is iOS 17 and `.glassEffect` is iOS 26+,
/// so this cannot be applied unguarded — both target phones run iOS 26.5, so
/// the glass branch is the one that actually renders for Georg and Heiko.
private extension View {
    @ViewBuilder
    func glassOrSolid<S: Shape>(_ shape: S, fallback: Color) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ConversationViewModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Set on `ContentView` by the App from the text-size slider. Watched here
    /// because changing it REFLOWS the whole transcript: every bubble changes
    /// height, so whatever the scroll offset used to point at, it no longer
    /// points at the newest message.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingSettings = false
    /// SPIKE — ties the pill to the sheet so one can morph into the other.
    @Namespace private var pillMorph
    /// SPIKE — true once a connection has been slow enough to deserve a ring.
    @State private var showConnectingSpinner = false

    // The transcript's own sizes are specified in points by the design, so
    // they ride Dynamic Type through @ScaledMetric rather than ignoring it.
    // Without these the transcript was pixel-identical at `large` and at
    // AX-XXXL — measured, 734×39 either way — while the chrome around it grew
    // about eightfold, so the one part of the screen that is actually READ was
    // the one part the text-size slider could not touch. GitHub #43.
    @ScaledMetric(relativeTo: .body) private var primarySize = ChatMetrics.primarySize
    @ScaledMetric(relativeTo: .footnote) private var secondarySize = ChatMetrics.secondarySize

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Palette.backgroundTop, Palette.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()
            // Insets drive the layout because the two target phones differ
            // sharply: the 14 Pro has a Dynamic Island and a home indicator,
            // the iPhone SE has neither. Fixed margins that look right on one
            // look wrong on the other.
            GeometryReader { geo in
                conversation(
                    topInset: geo.safeAreaInsets.top,
                    bottomInset: geo.safeAreaInsets.bottom
                )
            }
        }
        .sheet(isPresented: $showingSettings) {
            LanguageSettingsSheet(viewModel: viewModel)
                .morphDestination(Self.pillMorphID, pillMorph)
        }
        // Both occupants of the bottom slot fade, so a mic notice replacing a
        // cleared warning animates rather than snapping. Needs StatusNotice to
        // be Equatable.
        .animation(.easeInOut(duration: 0.3), value: viewModel.connectionWarning)
        .animation(.easeInOut(duration: 0.3), value: viewModel.micNotice)
        .preferredColorScheme(.dark)
        // The status line and hint are rewritten wholesale when the home
        // language changes — crossfade rather than snap.
        .animation(.easeInOut(duration: 0.28), value: viewModel.homeLang)
        .task {
            #if DEBUG
            // Opens the settings sheet on launch so a visual pass across all
            // six languages is scriptable — the sheet otherwise needs a real
            // tap, which is the one thing a headless capture cannot do.
            //   xcrun simctl launch <udid> <bundle> -UITestSettings YES
            if UserDefaults.standard.bool(forKey: "UITestSettings") { showingSettings = true }
            #endif
            // Deliberately does NOT start listening (speak-at-launch loss is
            // an open bug; the app waits for a tap and says so). Permission
            // is requested now so the first tap goes straight to listening.
            await viewModel.prepareAtLaunch()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding stops the sessions (iOS kills the audio anyway,
            // and streaming would keep billing); becoming active resumes.
            viewModel.handleScenePhase(phase)
        }
    }

    // MARK: - Conversation

    /// What the single bottom overlay is showing, if anything. The precedence
    /// itself lives in `ConversationViewModel.bottomNotice` so L1 can pin it;
    /// this is the binding. GitHub #28.
    private var bottomNotice: ConversationViewModel.StatusNotice? {
        ConversationViewModel.bottomNotice(muted: viewModel.statusShowsMuted,
                                           warning: viewModel.connectionWarning,
                                           micNotice: viewModel.micNotice)
    }

    /// True while the overlay pill covers the status/hint slot.
    private var warningCoversStatus: Bool { bottomNotice != nil }

    /// Status line, start hint, and the notice that can cover both — one
    /// fixed-height slot directly above the button.
    ///
    /// The notice is an OVERLAY on the slot rather than a row in it, so the
    /// mic button never moves when a warning comes and goes (on marginal LTE
    /// it can flap, and the app's single control must stay put). Opaque, so
    /// the covered status/hint text never bleeds through.
    private var statusSlot: some View {
        VStack(spacing: 0) {
            Text(viewModel.statusText)
                .font(.subheadline.weight(.medium))
                // Fade out, then in — never a crossfade, which on text reads
                // as doubled rather than as a change.
                .id(viewModel.statusText)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeIn(duration: 0.16).delay(0.18)),
                    removal: .opacity.animation(.easeOut(duration: 0.16))))
                // Amber while paused, matching the struck-through mic below
                // it. One state should not speak in two colours.
                .foregroundStyle(viewModel.statusIsPaused ? Palette.muted : Color.secondary)
                .frame(minHeight: 22)
                // Invisible (but still occupying its slot, so the button
                // never moves) while the notice covers this area.
                .opacity(warningCoversStatus ? 0 : 1)

            // Shown only before the very first tap, since the app now opens
            // muted (see the .task above).
            Text(viewModel.startHint ?? " ")
                .font(.footnote)
                .id(viewModel.startHint ?? "")
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeIn(duration: 0.16).delay(0.18)),
                    removal: .opacity.animation(.easeOut(duration: 0.16))))
                .foregroundStyle(.white.opacity(viewModel.startHint == nil || warningCoversStatus ? 0 : 0.45))
        }
        .frame(maxWidth: .infinity)
        .overlay {
            if let notice = bottomNotice {
                // Severity comes from the view model, not from prefix-matching
                // the German copy — rewording the text must not repaint it.
                // `.info` is deliberately not an alert colour: the mic notice
                // reports something that worked.
                let tint: Color = switch notice.severity {
                case .info: .white
                case .degraded: .orange
                case .lost: .red
                }
                Text(notice.text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.10).opacity(0.96), in: Capsule())
                    .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }
        }
    }

    private func conversation(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            transcript(topInset: topInset)
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.bottom, 4)
            }
            // Status and hint read BEFORE the control they describe, so they
            // sit above it. They used to hang underneath, which put the one
            // sentence telling Heiko what to do ("Zum Sprechen antippen") in
            // the strip of screen a thumb reaching for the button covers.
            statusSlot

            // The button's ring canvas is 200x200 but its visible circle is
            // 96, so laying it out at full size reserved ~50pt of empty space
            // above the circle and held the transcript that much higher. The
            // rings overflow this frame quite happily — nothing clips them —
            // and the transcript gets the room back.
            micButton
                .frame(height: 130)
                // Sit as low as the HIG allows: on a phone with a home
                // indicator the safe area already provides the margin, so
                // add almost nothing; on a home-button phone (Heiko's SE)
                // there is no inset at all and the button would otherwise
                // touch the glass.
                .padding(.bottom, bottomInset > 0 ? 4 : 20)
        }
        // Language pill, top-centre: the two flags of the current pair, which
        // is the one piece of state worth showing permanently. It replaces the
        // gear — the destination is language selection, and for a user who
        // reads no English two flags say that better than a cog does. The
        // flags used to live on the button itself, where they were doing two
        // jobs at once: naming the pair AND being the start/stop control.
        //
        // Anchored on `conversation`, which IS laid out inside the safe area —
        // so this padding is measured from below the Dynamic Island, and must
        // NOT add `topInset` again. The transcript underneath is the one that
        // ignores the safe area, which is why its fade below is the view that
        // has to add the inset back.
        .overlay(alignment: .top) {
            languagePill
                .padding(.top, PillLayout.topGap)
        }
        // The build number, top-right and deliberately almost invisible, on
        // the same baseline as the flags. It answers "is my phone current?"
        // and nothing else — non-interactive on purpose, so there is no
        // second tappable thing on a one-button screen, and hidden from
        // VoiceOver because it is for Georg, not Heiko.
        //
        // `.background`, not `.overlay`: this is the LOWEST layer on the
        // screen, so the transcript scrolls straight over it and the number
        // disappears behind the conversation as it fills up. It matters most
        // on a cold launch with nothing to read yet — which is exactly when
        // nothing covers it.
        .background(alignment: .topTrailing) {
            Text(AppVersion.label)
                .font(.caption2)
                // Pinned: the text-size slider is Heiko's, and this number is
                // not for him. Left to scale, it grows into the flags at the
                // larger steps and turns a corner mark into a headline.
                .dynamicTypeSize(.large)
                .foregroundStyle(.white.opacity(0.20))
                // Same band as the pill, so the number is centred on the
                // flags rather than on the top edge.
                .frame(height: PillLayout.height)
                .padding(.top, PillLayout.topGap)
                .padding(.trailing, 20)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var languagePill: some View {
        Button { showingSettings = true } label: {
            HStack(spacing: PillLayout.gap) {
                Text(viewModel.partnerLang.flag)
                    .font(.system(size: PillLayout.flagSize))
                // The design uses the SF Symbol, not three typed dots — which
                // is also why there is no longer a "···" string to review.
                // Not a decoration: it sits where a gear would have been and
                // reads as "these two can change".
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Text(viewModel.homeLang.flag)
                    .font(.system(size: PillLayout.flagSize))
            }
            .padding(.horizontal, PillLayout.horizontalPadding)
            .padding(.vertical, PillLayout.verticalPadding)
            // Glass, per the design. The transcript still fades out above the
            // pill's lower edge, so what glass refracts here is mostly the
            // background — a pill that is only 162pt wide cannot be a nav bar,
            // and letting sharp text run out from either side of it was the
            // worse of the two looks (simulator capture, this branch).
            .glassOrSolid(Capsule(), fallback: Palette.pill)
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .morphSource(Self.pillMorphID, pillMorph)
        .accessibilityLabel(viewModel.strings.settingsLabel)
    }

    /// SPIKE — one id, named once, because a typo in either half of a matched
    /// transition fails silently by falling back to the ordinary slide.
    private static let pillMorphID = "language-pill"


    /// One edge of the transcript, built the way the Figma builds it (node
    /// 1:51). Read off the node itself — its CSS export flattened both halves
    /// away, reporting `backdrop-blur-[0px]` and a plain two-stop gradient.
    ///
    /// - **Fill** — `GRADIENT_LINEAR`, pure black `a: 1` at the outer edge to
    ///   `a: 0` at the inner one. One straight ramp across the whole band, not
    ///   a hold-then-fall.
    /// - **Effect** — `BACKGROUND_BLUR`, `blurType: PROGRESSIVE`,
    ///   `startRadius: 8`, `startOffset.y 0 → endOffset.y 1`. The backdrop blur
    ///   is 8pt at the outer edge and 0 at the inner one.
    ///
    /// SwiftUI has no variable-radius backdrop blur, so the progressive half is
    /// approximated by stacking material bands, each covering less of the scrim
    /// than the one before, so blur compounds toward the outer edge. That is
    /// why a single flat material layer read wrong: a constant blur is simply
    /// not this effect.
    /// `tint` is optional: pass `nil` for blur with no darkening at all, which
    /// is what the lower edge wants — there the job is only "there is more
    /// below", and a tint reads as a shadow the design does not have.
    private func scrim(top: Bool, height: CGFloat, tint: Color?) -> some View {
        func stops(_ outer: Color, _ inner: Color, coverage: Double) -> [Gradient.Stop] {
            top ? [.init(color: outer, location: 0),
                   .init(color: inner, location: coverage)]
                : [.init(color: inner, location: 1 - coverage),
                   .init(color: outer, location: 1)]
        }
        return ZStack {
            // `.ultraThinMaterial` is the only backdrop blur SwiftUI exposes,
            // and it is not a pure blur — it lightens what is behind it. Where
            // a tint is wanted anyway (the top) that is harmless. Where it is
            // not (the bottom) the bands are held back so the blur reads and
            // the luminance barely does.
            ForEach([1.0, 0.66, 0.33], id: \.self) { coverage in
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(LinearGradient(stops: stops(.black, .clear, coverage: coverage),
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(tint == nil ? 0.55 : 1)
            }
            if let tint {
                LinearGradient(stops: stops(tint, tint.opacity(0), coverage: 1),
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }

    private func transcript(topInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Rests the first bubble below the status bar / Dynamic
                    // Island. Proportional to the inset: ~83pt on a 14 Pro,
                    // ~44pt on an SE, where a fixed 72 ate the screen.
                    Color.clear.frame(height: topInset + PillLayout.clearance)
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? viewModel.messages[index - 1] : nil
                        let next = index + 1 < viewModel.messages.count
                            ? viewModel.messages[index + 1] : nil
                        // A run is consecutive bubbles from the same speaker.
                        // Only its last bubble gets a tail, and the gap inside
                        // a run is tighter than the gap between speakers.
                        let startsRun = previous?.fromHome != message.fromHome
                        let endsRun = next?.fromHome != message.fromHome
                        let isNewest = index == viewModel.messages.count - 1
                            && viewModel.liveTranscript.isEmpty
                        messageRow(message, hasTail: endsRun)
                            .padding(.top, index == 0 ? 0
                                     : (startsRun ? ChatMetrics.spacingBetweenRuns
                                                  : ChatMetrics.spacingWithinRun))
                            .padding(.bottom, isNewest ? ChatMetrics.bottomClearance : 0)
                            .id(message.id)
                    }
                    if !viewModel.liveTranscript.isEmpty {
                        liveRow
                            .padding(.top, ChatMetrics.spacingBetweenRuns)
                            .padding(.bottom, ChatMetrics.bottomClearance)
                            .id("live")
                    }
                }
                .padding(.horizontal, ChatMetrics.screenMargin)
            }
            // Scrolled text passes *under* the status bar rather than being
            // clipped at a hard edge, and is dimmed there rather than deleted.
            // This is the scrim from the Figma (node 1:51): a black gradient
            // over a progressive backdrop blur, NOT an alpha mask — a mask
            // makes content vanish, this leaves a little blur and a little
            // transparency, so text visibly continues past the edge.
            //
            // 185pt of it, pure black, measured from the VERY TOP OF THE
            // DISPLAY. The order of these three modifiers is the whole trick:
            // `.ignoresSafeArea` must come AFTER the overlays so the scroll
            // view and its scrim expand past the safe area TOGETHER. Applied
            // before them, the overlay is laid out inside the safe area and
            // the scrim starts ~59pt down — which left the top bubble sitting
            // sharp and undimmed above the pill, in the gap the scrim was
            // supposed to be covering.
            //
            // iOS draws the status bar above app content, so the clock, Wi-Fi
            // and battery stay legible on top of the black without anything
            // here having to make room for them.
            .overlay(alignment: .top) {
                scrim(top: true, height: ChatMetrics.topScrim, tint: .black)
            }
            .ignoresSafeArea(edges: .top)
            .onAppear {
                guard let last = viewModel.messages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
                // …and again once layout has settled. A LazyVStack does not
                // know its full height on the first pass, so a single scroll
                // at appear-time can land short and leave the newest bubble
                // part-way up — or, with a taller text setting, under the
                // button. Cheap, idempotent, and it is the default state every
                // launch lands in, so it is the one worth being sure of.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // Resizing the text reflows every bubble, so the scroll offset ends
            // up pointing at the wrong place — usually leaving the newest
            // bubble part-way off the bottom. Drop back to it. Deferred a beat
            // so the reflow has happened before we measure it.
            .onChange(of: dynamicTypeSize) {
                guard let last = viewModel.messages.last else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: viewModel.liveTranscript) {
                if !viewModel.liveTranscript.isEmpty {
                    withAnimation { proxy.scrollTo("live", anchor: .bottom) }
                }
            }
            // The moment listening starts, drop to the newest bubble — before
            // any words arrive. Otherwise the first thing said scrolls a view
            // that was parked halfway up the history, and the speaker watches
            // their own words appear off-screen.
            .onChange(of: viewModel.isListening) { _, listening in
                guard listening else { return }
                withAnimation {
                    if let last = viewModel.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ConversationViewModel.Message, hasTail: Bool) -> some View {
        if message.fromHome {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                bubble(message, alignment: .trailing,
                       background: Palette.homeBubble, stroke: Palette.homeBubbleStroke,
                       hasTail: hasTail)
            }
        } else {
            HStack(spacing: 0) {
                bubble(message, alignment: .leading,
                       background: Palette.foreignBubble, stroke: Palette.foreignBubbleStroke,
                       hasTail: hasTail)
                Spacer(minLength: 0)
            }
        }
    }

    /// The in-progress utterance, transcribed word by word as it's spoken.
    ///
    /// Until the app actually knows which way the turn is going, this sits
    /// centred and unaligned rather than picking a side. Picking early meant
    /// English text appeared on the German side and jumped across when the
    /// turn finished — the app looked like it had changed its mind.
    @ViewBuilder
    private var liveRow: some View {
        let text = Text(viewModel.liveTranscript)
            .font(.system(size: primarySize))
            .tracking(ChatMetrics.primaryTracking)
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, ChatMetrics.textHorizontal)
            .padding(.vertical, ChatMetrics.textVertical)
        let maxW = UIScreen.main.bounds.width * ChatMetrics.maxWidthFraction

        switch viewModel.liveIsHome {
        case .some(true):
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                text
                    .multilineTextAlignment(.trailing)
                    .background(Palette.homeBubble.opacity(0.6),
                                in: ChatBubbleShape(tailOnRight: true, hasTail: true))
                    .frame(maxWidth: maxW, alignment: .trailing)
            }
        case .some(false):
            HStack(spacing: 0) {
                text
                    .multilineTextAlignment(.leading)
                    .background(Palette.foreignBubble.opacity(0.6),
                                in: ChatBubbleShape(tailOnRight: false, hasTail: true))
                    .frame(maxWidth: maxW, alignment: .leading)
                Spacer(minLength: 0)
            }
        case .none:
            // Side not known yet — no tail, because a tail would claim a
            // speaker the app has not identified.
            HStack(spacing: 0) {
                Spacer(minLength: 24)
                text
                    .multilineTextAlignment(.center)
                    .background(Color(white: 0.16).opacity(0.6),
                                in: RoundedRectangle(cornerRadius: ChatMetrics.radius,
                                                     style: .continuous))
                Spacer(minLength: 24)
            }
        }
    }

    /// Two lines per bubble: what was heard, then the spoken translation.
    /// Font size follows the LANGUAGE, not the role — the HOME language is
    /// always the large line, the partner language the small one.
    private func bubble(_ message: ConversationViewModel.Message,
                        alignment: HorizontalAlignment,
                        background: Color,
                        stroke: Color,
                        hasTail: Bool) -> some View {
        let heardIsHome = message.fromHome
        let onRight = alignment == .trailing
        return VStack(alignment: alignment, spacing: ChatMetrics.lineGap) {
            Text(message.original)
                .font(.system(size: heardIsHome ? primarySize : secondarySize))
                .tracking(heardIsHome ? ChatMetrics.primaryTracking
                                      : ChatMetrics.secondaryTracking)
                .foregroundStyle(heardIsHome ? .white : Color.secondary)
            if !message.translation.isEmpty {
                Text(message.translation)
                    .font(.system(size: heardIsHome ? secondarySize : primarySize))
                    .tracking(heardIsHome ? ChatMetrics.secondaryTracking
                                          : ChatMetrics.primaryTracking)
                    .foregroundStyle(heardIsHome ? Color.secondary : .white)
            }
        }
        .multilineTextAlignment(onRight ? .trailing : .leading)
        .padding(.horizontal, ChatMetrics.textHorizontal)
        .padding(.vertical, ChatMetrics.textVertical)
        .background(background, in: ChatBubbleShape(tailOnRight: onRight, hasTail: hasTail))
        // A hairline edge. On a near-black background the fills alone lose
        // their silhouette; the stroke is what keeps a bubble a bubble.
        .overlay(ChatBubbleShape(tailOnRight: onRight, hasTail: hasTail)
            .stroke(stroke, lineWidth: 1))
        .frame(maxWidth: UIScreen.main.bounds.width * ChatMetrics.maxWidthFraction,
               alignment: onRight ? .trailing : .leading)
    }

    // MARK: - Mic button

    /// How much of the strike-through is drawn, 0…1.
    ///
    /// Animated rather than toggled, so the slash STRIKES the mic on the way in
    /// and unwinds on the way out — the gesture reads as an action taken, where
    /// a line appearing whole reads as a redraw. `.trim` is what makes it a
    /// stroke being drawn rather than a shape fading.
    /// SPIKE ONLY. `-UITestConnecting YES` pins the connecting state so the
    /// rim spinner can be looked at; it is otherwise on screen for well under
    /// a second, which is no way to judge a piece of motion.
    static var forceConnectingPreview: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "UITestConnecting")
        #else
        false
        #endif
    }

    /// Connecting, including the DEBUG pin — so the pin exercises the real
    /// delay rather than side-stepping it.
    private var connectingNow: Bool { viewModel.isConnecting || Self.forceConnectingPreview }

    private var slashProgress: CGFloat {
        // The pin has to suppress the slash too, or the preview shows a state
        // that cannot occur: while genuinely connecting a session IS live, so
        // `micReadsAsMuted` is false and the glyph is already bare.
        (viewModel.micReadsAsMuted && !Self.forceConnectingPreview) ? 1 : 0
    }

    /// The glyph grows with the sound reaching the microphone — the app's
    /// "I can hear you" signal, driven by the mic itself rather than by
    /// anything the API has decided yet.
    private var micScale: CGFloat {
        viewModel.isListening ? 1.0 + CGFloat(viewModel.micLevel) * 0.30 : 1.0
    }

    private var micButton: some View {
        Button(action: viewModel.toggleButton) {
            ZStack {
                if viewModel.isListening {
                    if viewModel.isSpeaking {
                        SpeakingRipples()
                            .transition(.opacity)
                    } else {
                        ListeningRings(level: viewModel.micLevel)
                            .transition(.opacity)
                    }
                }

                Color.clear
                    .frame(width: 96, height: 96)
                    .glassOrSolid(Circle(),
                                  fallback: viewModel.isListening ? Palette.micButtonActive
                                                                  : Palette.micButton)
                    .overlay(
                        Circle().stroke(Palette.micButtonStroke.opacity(viewModel.isListening ? 1.0 : 0.5),
                                        lineWidth: MicGlyph.buttonStrokeWidth)
                    )
                    // Node 1:77 carries the same GLASS + DROP_SHADOW pair as
                    // the pill; the button had the glass but not the shadow.
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 4)

                // A microphone, not the flag pair. The flags moved to the pill
                // at the top: they say WHICH languages, which is state, while
                // this button says START AND STOP, which is an action. One
                // glyph doing both jobs is what made the old face ambiguous.
                //
                // Georg's own icon, exported from the Figma as a template SVG
                // — an OUTLINE mic on a stand. `mic.fill` was a stand-in and
                // is a visibly different drawing.
                // Amber and struck through while muted — the one state where
                // speaking does nothing, so it has to be legible at a glance
                // rather than inferred from a grey glyph. Amber, not red: this
                // is a state the user chose, not a failure.
                ZStack {
                    // The glyph, with the slash's clearance CUT OUT of it
                    // rather than laid over it. `destinationOut` inside a
                    // compositing group removes those pixels, so the mic is
                    // visibly interrupted by the slash instead of having a
                    // line sitting on top of it — which is what makes a
                    // struck-through symbol read at a glance.
                    ZStack {
                        Image("MicIcon")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: MicGlyph.width, height: MicGlyph.height)
                        MicSlash()
                            .trim(from: 0, to: slashProgress)
                            .stroke(style: StrokeStyle(lineWidth: MicGlyph.maskWidth, lineCap: .round))
                            .frame(width: MicGlyph.slashBox, height: MicGlyph.slashBox)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()

                    // …and the slash itself, drawn into the gap it just made.
                    MicSlash()
                        .trim(from: 0, to: slashProgress)
                        .stroke(style: StrokeStyle(lineWidth: MicGlyph.slashWidth, lineCap: .round))
                        .frame(width: MicGlyph.slashBox, height: MicGlyph.slashBox)
                }
                .foregroundStyle(viewModel.micReadsAsMuted && !Self.forceConnectingPreview ? Palette.muted : .white)
                .opacity(connectingNow ? MicGlyph.connectingOpacity : 1)
                .scaleEffect(micScale)
                .animation(.easeInOut(duration: 0.2), value: viewModel.micReadsAsMuted)

                if showConnectingSpinner {
                    RimSpinner(diameter: MicGlyph.ringDiameter,
                               lineWidth: MicGlyph.slashWidth,
                               color: MicGlyph.connectingGrey)
                }
            }
            .frame(width: 200, height: 200)
        }
        .buttonStyle(.plain)
        // The ring waits out `connectingSpinnerDelay` before appearing, and
        // `.task(id:)` cancels the wait the moment connecting ends — so a
        // connection that beats the delay never draws it at all. That is the
        // whole point: no flash of motion for a handshake that was already
        // done.
        .task(id: connectingNow) {
            guard connectingNow else { showConnectingSpinner = false; return }
            try? await Task.sleep(nanoseconds: UInt64(MicGlyph.connectingSpinnerDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            showConnectingSpinner = true
        }
        .accessibilityLabel(viewModel.isListening ? viewModel.strings.stopListeningLabel
                                                  : viewModel.strings.startListeningLabel)
        .animation(.easeOut(duration: 0.1), value: viewModel.micLevel)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isSpeaking)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isListening)
    }
}



/// The strike-through: one diagonal, lower-left to upper-right, matching the
/// direction SF Symbols uses for every `.slash` variant.
/// The muted-microphone glyph: the mic itself, and the stroke through it.
///
/// The slash is deliberately SHORTER than the icon it crosses — its box is
/// square, so its corner-to-corner length lands just about on the icon's own
/// height. It used to be framed larger than the icon (46x62 against 38x56) and
/// so shot past the glyph on both ends, which read as a line drawn over the
/// button rather than a struck-through mic.
private enum MicGlyph {
    static let width: CGFloat = 34
    static let height: CGFloat = 50
    /// Square, so the 45° slash spans `slashBox * sqrt(2)` ≈ 51pt ≈ `height`.
    static let slashBox: CGFloat = 36
    static let slashWidth: CGFloat = 3
    /// The visible button circle. The spinner traces exactly this, so the line
    /// lands ON the rim rather than floating inside it.
    static let buttonDiameter: CGFloat = 96
    /// How far the glyph is dimmed while connecting.
    static let connectingOpacity: Double = 0.3
    /// The button's own border.
    static let buttonStrokeWidth: CGFloat = 1

    /// The ring sits so its outer edge TOUCHES the inside of that border —
    /// no gap, no overlap. Derived rather than dialled in:
    ///
    ///   button radius              48
    ///   its 1pt border straddles   47.5 … 48.5, so the inner face is 47.5
    ///   the ring's 3pt stroke is centred at r, outer face at r + 1.5
    ///   touching means r + 1.5 = 47.5, so r = 46 — diameter 92
    ///
    /// which is `buttonDiameter - (slashWidth + buttonStrokeWidth)`. Written
    /// as the subtraction so it stays true if any of the three moves; a
    /// literal 92 would not.
    static var ringDiameter: CGFloat { buttonDiameter - (slashWidth + buttonStrokeWidth) }

    /// Now that the ring runs INSIDE the button, it lies on the same flat
    /// interior the glyph does — so it can simply BE the glyph's colour, white
    /// at `connectingOpacity`, and match by construction.
    ///
    /// That was not true when it traced the rim. There it crossed the button's
    /// 1pt stroke, the glass and the background gradient, so the same
    /// translucent white rendered anywhere from 64 to 113 luma depending on
    /// where the arc had rotated to, and had to be faked with an opaque grey
    /// sampled off a render. Moving it inside removed the cause rather than
    /// compensating for it, and the hardcoded RGB went with it.
    static var connectingGrey: Color { .white.opacity(connectingOpacity) }

    static let connectingSpinnerDelay: Double = 0.5
    /// The gap cut out of the glyph. Wider than the slash by more than it was
    /// before (12 against 9 for a 3pt line): the clearance either side is what
    /// separates the two shapes, and at the smaller size they crowd each other
    /// without it.
    static let maskWidth: CGFloat = 12
}


/// SPIKE — the connecting indicator, replacing `ProgressView`.
///
/// Georg's brief: the line that crosses out the microphone turns the same grey
/// as the icon and spins clockwise on the button's outside rim. So this is
/// deliberately the SAME stroke width and cap as `MicSlash` — it should read as
/// that one line having left the glyph and gone around the outside, not as a
/// new element arriving.
///
/// The slash needs no hiding: `micReadsAsMuted` is already false while
/// connecting (a session is live), so `slashProgress` is 0 and the glyph is
/// bare. The two states hand over cleanly by accident of the existing rule.
private struct RimSpinner: View {
    let diameter: CGFloat
    let lineWidth: CGFloat
    let color: Color

    /// How much of the rim the line occupies. A fifth reads as a line being
    /// dragged around a circle; much more and it reads as a loading ring,
    /// which is the stock look this is replacing.
    private let arc: CGFloat = 0.2
    private let period: Double = 0.9

    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: arc)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .foregroundStyle(color)
            .frame(width: diameter, height: diameter)
            // Positive degrees are clockwise in SwiftUI, which is the ask.
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: period).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}


/// SPIKE — the pill morphing into the settings sheet, rather than the sheet
/// sliding up from the bottom edge.
///
/// `zoom` is iOS 18+, and the deployment target is 17, so both halves are
/// guarded. Below 18 this is simply the stock sheet presentation — the
/// feature degrades to what shipped, which is the right floor for a motion
/// experiment. Both target phones run 26.5, so the morph is what Georg and
/// Heiko actually see.
///
/// A matched transition needs BOTH halves to agree on the id. If they do not,
/// nothing errors — you just get the ordinary slide and are left wondering
/// whether the API works. Hence the single shared constant.
private extension View {
    @ViewBuilder
    func morphSource(_ id: String, _ namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func morphDestination(_ id: String, _ namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

private struct MicSlash: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// Three concentric rings that unfold outward with the speaker's voice —
/// the louder the sound at the microphone, the more rings light up and the
/// further they reach. Near silence, a single faint ring breathes slowly so
/// a listening app never looks frozen.
private struct ListeningRings: View {
    /// Microphone loudness, 0...1 (already smoothed by the view model).
    let level: Double

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Slow breath, 3.2s period, used only when the room is quiet.
            let breath = (sin(t * 2 * .pi / 3.2) + 1) / 2
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let i = Double(ring)
                    // Outer rings need progressively more voice to appear,
                    // so the set unfolds outward as the speaker gets going.
                    let threshold = 0.12 * i
                    let response = max(0, level - threshold) / (1 - threshold)
                    let idleGlow = ring == 0 ? (0.05 + 0.05 * breath) : 0
                    let idleGrow = ring == 0 ? breath * 3 : 0
                    let diameter = 106 + i * 13 + response * (36 + i * 16) + idleGrow
                    Circle()
                        .stroke(
                            Palette.ring.opacity(response * (0.40 - 0.10 * i) + idleGlow),
                            lineWidth: 2.4 - i * 0.6
                        )
                        .frame(width: diameter, height: diameter)
                }
            }
        }
    }
}

/// Sonar-style ripples emanating outward while the translation is spoken —
/// deliberately rhythmic rather than sound-driven, so "the app is talking"
/// looks different from "the app is hearing you".
private struct SpeakingRipples: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let phase = (t / 1.7 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    let eased = 1 - pow(1 - phase, 2)   // fast launch, gentle fade-out
                    Circle()
                        .stroke(
                            Palette.ring.opacity((1 - eased) * 0.32),
                            lineWidth: 2.2 - phase * 1.2
                        )
                        .frame(width: 98 + eased * 96, height: 98 + eased * 96)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
