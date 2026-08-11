import SwiftUI

/// Replace content by fading the old out and then the new in — never a
/// crossfade.
///
/// A crossfade has both strings on screen together at half opacity, which on
/// text reads as doubled or smeared rather than as a change. Out-then-in costs
/// a beat of empty space and is unambiguous: the old thing leaves, the new
/// thing arrives.
private extension View {
    func fadeThrough<V: Hashable>(_ value: V) -> some View {
        self
            .id(value)
            .transition(.asymmetric(
                insertion: .opacity.animation(.easeIn(duration: 0.16).delay(0.18)),
                removal: .opacity.animation(.easeOut(duration: 0.16))))
    }
}

/// One side's language choice, drawn as the conversation itself.
///
/// The selected language sits in a **chat bubble** — same shape, same fill,
/// same side as it will occupy in the transcript — and the alternatives list
/// underneath it. That is the whole idea of this screen: it does not *explain*
/// that the partner is grey-on-the-left and home is indigo-on-the-right, it
/// *shows* it, so the settings sheet is the legend for the main screen. It
/// replaced two labelled wheel pickers ("Gesprächspartner" / "Zuhause") and a
/// sentence of German explaining the layout, none of which a non-reader of
/// German-as-instructions needs if the picture is right.
private struct LanguageColumn: View {
    @Binding var selection: TurnLogic.Lang
    /// The other side's current pick.
    let otherSide: TurnLogic.Lang
    /// Whether this column hides `otherSide`.
    ///
    /// TRUE for "others speak" — it lists languages that are not yours, and a
    /// collision there would silently move the language you did not touch.
    ///
    /// FALSE for "I speak". That column offers all six, always, in an order
    /// that never changes — endonyms are the same words in every language, so
    /// there is nothing for a language change to re-sort. Which is the point:
    /// what the other person speaks has NO bearing on what you speak, and the
    /// ME wheel had been fading and re-ordering every time the YOU wheel
    /// moved. Choosing the other side's language here still swaps the pair,
    /// which is SPEC §4.4 and pinned by L1.29.
    let excludesOtherSide: Bool
    /// Whose language the labels are written in — the home side.
    let reader: TurnLogic.Lang
    /// Name each language in ITSELF rather than in the reader's language.
    ///
    /// True for the home column, and the asymmetry is the point. That column
    /// is where you pick YOUR OWN language, and you have to find it while the
    /// app is still speaking somebody else's — a Spanish speaker handed a
    /// German phone is scanning for "Español", not "Spanisch". The partner
    /// column is the opposite case: you are naming someone else's language to
    /// yourself, so it stays in your own words.
    let useEndonyms: Bool
    /// The line above the wheel — "Andere sprechen" / "Ich spreche".
    let descriptor: String
    let onRight: Bool
    let fill: Color
    let stroke: Color

    /// Which NOTCH is parked in the bubble. Driven by the scroll, and it IS
    /// the selection — that is the point of a rotary: there is no separate
    /// "selected row", the row in the bubble is selected because it is there.
    @State private var parked: Notch?

    /// One position on an endless wheel: a language plus which turn of the
    /// wheel it belongs to.
    struct Notch: Hashable {
        let turn: Int
        let lang: TurnLogic.Lang
    }

    /// How many times the list repeats. 101 turns of five languages is ~500
    /// notches — far more than anyone will spin past, so the wheel never has
    /// to be silently recentred mid-scroll, which is the part that visibly
    /// jumps in every hand-rolled infinite list.
    private static let turns = 101
    private static var middle: Int { turns / 2 }

    @ScaledMetric(relativeTo: .title3) private var selectedSize: CGFloat = 20
    /// The descriptor rides the text-size setting like everything else. It was
    /// a bare 13pt, so it stayed put while the wheel under it grew — the one
    /// line on this screen that ignored the slider.
    @ScaledMetric(relativeTo: .footnote) private var descriptorSize: CGFloat = 13
    /// Flags at the same size as the pair in the chat screen's pill, so the
    /// two places that show a flag agree. The Figma's wheel drew flag and name
    /// as one 20pt run, which made the flags here noticeably smaller than the
    /// ones the user has just tapped to get here.
    @ScaledMetric(relativeTo: .title3) private var flagSize: CGFloat = 30

    /// Alphabetical by the name THIS COLUMN shows — the partner column sorts
    /// in the reader's language, the home column by endonym. Either way the
    /// order matches what the eye is scanning.
    private var options: [TurnLogic.Lang] {
        TurnLogic.Lang.allCases
            .filter { !excludesOtherSide || $0 != otherSide }
            .sorted { displayed($0).localizedCompare(displayed($1)) == .orderedAscending }
    }

    /// What a rebuild-and-fade is keyed to. Constant for the ME column, so it
    /// never rebuilds; the YOU column re-sorts when the reader's language
    /// changes and fades through that.
    private var reorderKey: String { excludesOtherSide ? otherSide.rawValue : "fixed" }

    private var notches: [Notch] {
        (0..<Self.turns).flatMap { turn in options.map { Notch(turn: turn, lang: $0) } }
    }

    /// The notch for a language, on the turn the wheel is already showing.
    private func notch(for lang: TurnLogic.Lang) -> Notch {
        Notch(turn: parked?.turn ?? Self.middle, lang: lang)
    }
    /// One notch of the rotary. Driven by the FLAG now, since at 30pt it is
    /// the tallest thing in a row; the Figma's 42pt pitch was set by 20pt type.
    private var slot: CGFloat { flagSize * 1.5 }
    /// The bubble is deliberately TALLER than one notch (the Figma's is 51pt
    /// against a 42pt pitch), so it reads as a frame the rows pass through
    /// rather than as one row painted a different colour.
    private var bubblePadH: CGFloat { selectedSize * 1.2 }
    private var bubblePadV: CGFloat { selectedSize * 0.45 }
    /// Tall enough for the flag, which now sets the row's height.
    private var bubbleContentHeight: CGFloat { flagSize * 1.2 }

    /// How many notches the window shows — chosen by SCREEN HEIGHT, and
    /// deliberately NOT by text size.
    ///
    /// This is the fix for the flicker. The window used to snap to whole rows
    /// out of a fixed budget, `floor(budget / slot)`, which meant the count
    /// itself changed as the slider moved: three rows up to step 3, two from
    /// step 4. Dragging across that boundary made a whole language pop in and
    /// out, and dragging quickly made it flicker. Whole rows were right — the
    /// half-sliced language before them was worse — but deriving the COUNT
    /// from the thing the user is dragging is what put a discontinuity in the
    /// middle of a continuous gesture.
    ///
    /// Fixing the count per device removes the discontinuity without
    /// reintroducing partial rows: the height is now `slot * count`, which
    /// scales smoothly with the text, and the count never changes on a given
    /// phone, so nothing can pop.
    ///
    /// Three does not fit an SE at the largest text — measured, and the Fertig
    /// button clips off the top — so small screens get two. That difference is
    /// invisible to anyone holding one phone, which is everyone.
    private static let visibleNotches: CGFloat = UIScreen.main.bounds.height >= 700 ? 3 : 2
    private var wheelHeight: CGFloat { slot * Self.visibleNotches }

    /// Height of the descriptor line above the wheel — the design's 18pt on a
    /// 13pt face, kept in proportion as the face scales.
    private var descriptorHeight: CGFloat { descriptorSize * (18.0 / 13.0) }
    /// The descriptor sits above its bubble, not on it. 6pt read as a caption
    /// stuck to the frame; 12 gives "Ich spreche" and "Andere sprechen" room
    /// to be their own line.
    private var descriptorGap: CGFloat { 12 }

    /// The bubble is a FIXED width, not a hug.
    ///
    /// The Figma's two bubbles are 187 and 186pt on a 393pt sheet — the same
    /// width whatever is inside them. Hugging looked right with one language
    /// and turned the screen restless with six: "中文" and "Französisch" are
    /// nowhere near the same length, so the bubble, and the descriptor pinned
    /// to its edge, jumped every time the language changed. A frame the words
    /// sit inside does not move at all.
    private var bubbleWidth: CGFloat {
        // A shade wider than the Figma's 187, because a 30pt flag takes more
        // room than the 20pt one the design measured.
        UIScreen.main.bounds.width * (203.0 / 393.0) * (selectedSize / 20)
    }

    /// What this column calls a language — and therefore what it sorts by too.
    private func displayed(_ lang: TurnLogic.Lang) -> String {
        useEndonyms ? lang.endonym : lang.name(in: reader)
    }

    /// Flag and name as two runs rather than one string, which is what lets
    /// the flag be 30pt while the name stays at the wheel's own size.
    @ViewBuilder
    private func label(_ lang: TurnLogic.Lang) -> some View {
        HStack(spacing: 10) {
            Text(lang.flag).font(.system(size: flagSize))
            Text(displayed(lang))
                .font(.system(size: selectedSize))
                .tracking(-0.43)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(notches, id: \.self) { notch in
                    let lang = notch.lang
                    // Read on the main actor and captured as a plain CGFloat.
                    // `slot` is main-actor isolated (it derives from a
                    // @ScaledMetric), and `visualEffect`'s closure is
                    // @Sendable — it may run off the main actor — so touching
                    // `slot` from inside it is a data race the compiler is
                    // right to warn about. A value captured here cannot race.
                    let rowHeight = slot
                    label(lang)
                        .foregroundStyle(.white)
                        .padding(.horizontal, bubblePadH)
                        .frame(width: bubbleWidth, alignment: .leading)
                        // Recede with distance from the bubble, the way the
                        // design's wheel does — computed from the live scroll
                        // offset rather than a static row index, because the
                        // rows move now.
                        //
                        // Applied to the fixed-width BOX, not to the
                        // full-width row, and anchored leading: the pivot is
                        // then the left edge of the words themselves, so every
                        // row shares one vertical edge however far it has
                        // receded. Scaling the full-width row instead — or
                        // anchoring to the column's own side — walked each
                        // step sideways and left a ragged edge under the
                        // bubble.
                        .visualEffect { content, proxy in
                            let d = max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY) / rowHeight
                            return content
                                .opacity(d < 0.5 ? 1 : max(0.22, 0.62 - (d - 0.5) * 0.30))
                                .scaleEffect(d < 0.5 ? 1 : max(0.78, 1 - (d - 0.5) * 0.10),
                                             anchor: .leading)
                        }
                        .frame(height: slot)
                        .frame(maxWidth: .infinity,
                               alignment: onRight ? .trailing : .leading)
                        .id(notch)
                }
            }
            .scrollTargetLayout()
        }
        .frame(height: wheelHeight)
        .padding(.top, descriptorHeight + descriptorGap)
        // The descriptor and the bubble are ONE block, so the label sits at
        // the bubble's leading edge rather than the column's — which is what
        // the design does, and what keeps it attached to the thing it names
        // when the bubble's width changes with the language.
        //
        // The bubble STAYS PUT and the languages move through it: a selection
        // frame, the way a real picker works, rather than a highlight that
        // travels with a row. It sits BEHIND the rows, which is what puts the
        // parked language inside it and lets the others pass over it.
        .background(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: descriptorGap) {
                Text(descriptor)
                    .font(.system(size: descriptorSize, weight: .medium))
                    .tracking(-0.08)
                    .foregroundStyle(.white)
                    // Indented to the flag, not to the bubble's edge: the
                    // label lines up with the first thing under it that the
                    // eye actually tracks.
                    .padding(.leading, bubblePadH)
                    .fadeThrough(descriptor)
                Color.clear
                    .frame(width: bubbleWidth, height: bubbleContentHeight + bubblePadV * 2)
                    .background(ChatBubbleShape(tailOnRight: onRight, hasTail: true).fill(fill))
                    .overlay(ChatBubbleShape(tailOnRight: onRight, hasTail: true)
                        .stroke(stroke, lineWidth: 1))
                    .frame(height: slot, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: onRight ? .trailing : .leading)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $parked, anchor: .top)
        .onAppear { if parked == nil { parked = notch(for: selection) } }
        .onChange(of: parked) { _, new in
            if let new, new.lang != selection { selection = new.lang }
        }
        // A swap from the other column moves this one's pick; follow it,
        // staying on the current turn so the wheel does not spin.
        .onChange(of: selection) { _, new in
            if parked?.lang != new { parked = notch(for: new) }
        }
        // Only the excluding column cares: the other side changing rewrites
        // its options and can strand `parked` on a notch that no longer exists.
        .onChange(of: otherSide) { _, _ in
            if excludesOtherSide { parked = notch(for: selection) }
        }
        // Rebuilt under a new identity when its order changes, so the rows fade
        // out and back rather than sliding past each other. Constant for the ME
        // column, which therefore never rebuilds at all.
        .fadeThrough(reorderKey)
    }
}

/// The text-size control: a stock `Slider`, an A at each end.
///
/// Apple's own control rather than a hand-drawn one — it brings the right
/// gesture targets, the haptics at each notch, VoiceOver's adjustable trait
/// and every accessibility behaviour that a custom track has to reimplement
/// badly. The design's notched track was the one thing lost; the step count
/// still comes through as the slider's own detents.
///
/// It writes one step index, which the app turns into a Dynamic Type size —
/// so this scales the transcript, the status line and this sheet together,
/// and survives relaunch.
private struct TextSizeSlider: View {
    @Binding var step: Int
    let label: String
    /// The size the system is delivering right now — where the thumb sits
    /// while the user has not chosen anything, so the first drag starts
    /// from what they already see instead of jumping. Reading it is what
    /// keeps "untouched" honest: the slider reflects the system until the
    /// moment it is used, and only then writes an override. GitHub #12.
    @Environment(\.dynamicTypeSize) private var systemSize

    private var count: Int { TextSize.steps.count }
    private var displayedStep: Int {
        step == TextSize.system ? TextSize.nearestStep(to: systemSize) : step
    }

    var body: some View {
        HStack(spacing: 16) {
            Text("A").font(.system(size: 13))
            Slider(
                value: Binding(
                    get: { Double(displayedStep) },
                    set: { step = min(max(Int($0.rounded()), 0), count - 1) }
                ),
                in: 0...Double(count - 1),
                step: 1
            )
            .tint(.white.opacity(0.35))
            .accessibilityLabel(label)
            Text("A").font(.system(size: 22))
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 18)
        .frame(height: 66)
        .background(Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        // The control sets the app's text size; it must not resize itself as
        // the user drags, or the thumb moves out from under their finger.
        .dynamicTypeSize(.large)
    }
}

struct LanguageSettingsSheet: View {
    @ObservedObject var viewModel: ConversationViewModel
    @ObservedObject private var tracker = CostTracker.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TextSize.key) private var textSizeStep = TextSize.defaultStep

    /// Everything on this sheet is written in the home language.
    private var strings: UIStrings { viewModel.strings }

    /// The exported log, built once when the sheet appears rather than inside
    /// `body`. Writing it is a `queue.sync` plus a read of every kept run and
    /// a write of the concatenation, so doing it per `body` evaluation put all
    /// of that on the main thread. GitHub #6.
    @State private var logFile: URL?

    /// Always cents. It used to drop to four decimals under a penny, which
    /// turned the one number on this row into a different shape depending on
    /// how much had been spent.
    private func usd(_ value: Double) -> String { String(format: "$%.2f", value) }

    var body: some View {
        ZStack {

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(strings.done) { dismiss() }
                        .fadeThrough(strings.done)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                // The columns sit 3/8 of the way down the gap between the
                // Fertig button and the usage rows — not at its midpoint.
                //
                // Dead centre measured 86.3pt above and 87.3pt below, and read
                // a shade LOW to Georg's eye, which is the usual optical-centre
                // effect: a block under a heading wants to sit above the
                // geometric middle. This lifts it by a quarter of the upper
                // gap.
                //
                // Adjacent Spacers divide free space equally and there is no
                // weighting API, so three above against five below IS the 3:5
                // split. The extras carry `minLength: 0` so that on an SE at
                // the largest text size — where there is no slack to divide —
                // they collapse to nothing rather than forcing 32pt of air
                // that would push the log row off the bottom.
                Spacer(minLength: 4)
                Spacer(minLength: 0)
                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    LanguageColumn(selection: $viewModel.partnerLang,
                                   otherSide: viewModel.homeLang,
                                   excludesOtherSide: true,
                                   reader: viewModel.homeLang,
                                   useEndonyms: false,
                                   descriptor: strings.othersSpeak,
                                   onRight: false,
                                   fill: Palette.foreignBubble,
                                   stroke: Palette.foreignBubbleStroke)
                    LanguageColumn(selection: $viewModel.homeLang,
                                   otherSide: viewModel.partnerLang,
                                   excludesOtherSide: false,
                                   reader: viewModel.homeLang,
                                   useEndonyms: true,
                                   descriptor: strings.iSpeak,
                                   onRight: true,
                                   fill: Palette.homeBubble,
                                   stroke: Palette.homeBubbleStroke)
                }
                .padding(.horizontal, 20)
                // Clear of the Fertig button, but no more than it has to be:
                // every point here comes off the bottom of an SE.


                Spacer(minLength: 4)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    usageRow
                    TextSizeSlider(step: $textSizeStep, label: strings.textSize)
                    logRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        // The sheet's own chrome, read off node 1:105: 38pt top corners, a
        // translucent dark gradient over a heavy backdrop blur, and a 1pt
        // INSIDE stroke that is itself a gradient — white at the top fading to
        // nothing at the bottom. The stroke is the part that was missing; it
        // is what separates the sheet from the screen behind it on a design
        // this dark, and an opaque fill cannot stand in for it.
        .presentationCornerRadius(38)
        // SPIKE — this glass used to be a `.presentationBackground`, and that
        // is the ONE modifier that silently disables the zoom morph: it
        // replaces the sheet's own backing view, which the transition needs to
        // own in order to grow it out of the pill. Measured, not guessed —
        // stripping it made the morph appear, and restoring
        // `.presentationCornerRadius` and `.presentationDetents` alongside it
        // kept the morph, so those two are innocent.
        //
        // Same pixels, drawn one layer in: as the content's own background
        // rather than the presentation's. `.ignoresSafeArea` so it still
        // reaches the sheet's edges.
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [Palette.sheetBackground.opacity(0.60),
                             Palette.sheetBackground.opacity(0.30)],
                    startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38,
                                   style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        // A sheet is its own presentation context and does not inherit the
        // presenter's `dynamicTypeSize`, so the setting is applied here too —
        // otherwise the slider visibly scaled the app behind the sheet while
        // the sheet it lives in stayed put. Same modifier as the root: with
        // no explicit choice, the system size flows through here as well.
        .modifier(TextSizeOverride(step: textSizeStep))
        // Changing the home language rewrites every word on this sheet at
        // once. Crossfade it: a whole screen of text swapping instantly reads
        // as a glitch, and the wheels are still moving under the user's finger
        // when it happens.
        .animation(.easeInOut(duration: 0.28), value: viewModel.homeLang)
        .task {
            // Off the main thread: exportedFile() does queue.sync and touches
            // every log file. Only a URL crosses back.
            logFile = await Task.detached(priority: .utility) {
                DiagnosticLog.shared.exportedFile()
            }.value
        }
        // One detent. The two language columns plus the two rows below them are
        // taller than `.medium`, and a half sheet that clips its own content is
        // worse than no half sheet.
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }

    /// Usage, tucked under the language settings — free tier, so the dollar
    /// figure is what the paid tier WOULD cost.
    /// A readout, not a control. The chevron and the detail sheet behind it
    /// are gone: this row now says what it says and nothing else, which is one
    /// fewer tappable thing on a screen whose user should never have to wonder
    /// what is a button.
    private var usageRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(strings.usage)
                    .fadeThrough(viewModel.homeLang)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(String(format: strings.minutesSpokenFormat, tracker.audioMinutesIn))
                    .fadeThrough(viewModel.homeLang)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(usd(tracker.estimatedCostUSD))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// The one thing the user may be asked to do remotely: send the log.
    /// It has to be one tap from the language pill, in German, and named after
    /// the person who receives it — the developer-facing copy lives one level
    /// deeper in CostSheet.
    @ViewBuilder
    private var logRow: some View {
        if let log = logFile {
            ShareLink(item: log) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(strings.sendLog)
                    .fadeThrough(viewModel.homeLang)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(String(format: strings.sendLogSubtitleFormat, AppVersion.label))
                    .fadeThrough(viewModel.homeLang)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            // One line in every language now that the copy is
                            // short — so no reserve is needed, and the card
                            // stops shifting on a language change by being
                            // the same height rather than by padding.
                            //
                            // Shrink rather than truncate: the build number is
                            // at the END of the line, so an ellipsis eats
                            // exactly the part Georg needs. On an SE at the
                            // largest text setting it read "… · 2.3…", which
                            // is the one failure this row cannot have.
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

#Preview {
    LanguageSettingsSheet(viewModel: ConversationViewModel())
}
