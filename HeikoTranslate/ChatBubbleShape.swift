import SwiftUI

/// An iMessage bubble, measured off a real Messages screenshot rather than
/// guessed (iPhone 14 Pro, 3x, 2026-07-31):
///
/// | property | measured |
/// |---|---|
/// | bubble edge to screen edge | 16.0 pt |
/// | single-line body height | 40.0 pt |
/// | corner radius | 18.0 pt, CIRCULAR — a multi-line bubble's corner extends |
/// | | 17.7pt below its top edge; a continuous/squircle corner would |
/// | | extend ~30pt and reads visibly softer than Messages |
/// | tail drop below the body | 6.7 pt |
/// | tail tip, from the body's outer edge | ~9 pt inward |
///
/// The two things that are easy to get wrong, and that the screenshot
/// settled:
///
/// 1. **The tail hangs BELOW the bubble.** It does not sit level with the
///    base. That overhang is what makes it read as a tail instead of a
///    thickened corner. It is drawn outside the shape's rect, which SwiftUI
///    renders happily; the 8pt gap to the next run absorbs it.
/// 2. **The tail does not stick out sideways.** Its tip is *inside* the
///    bubble's outer edge, tucked under the corner. Every earlier attempt
///    here pushed it outward and looked like a comic-strip speech balloon.
///
/// Body and tail are combined with a boolean `union`. Appending them as two
/// subpaths does not work: `addRoundedRect` and a hand-drawn tail wind in
/// opposite directions, so the non-zero fill rule SUBTRACTS the overlap and
/// the tail appears as a wedge bitten out of the corner.
struct ChatBubbleShape: Shape {
    /// true → tail on the right (home side), false → tail on the left.
    let tailOnRight: Bool
    /// Only the last bubble of a run carries a tail, as in Messages.
    let hasTail: Bool

    var radius: CGFloat = ChatMetrics.radius
    var tailDrop: CGFloat = ChatMetrics.tailDrop

    /// The tail overhangs the layout rect, so it must not be clipped.
    static var overhang: CGFloat { ChatMetrics.tailDrop }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(radius, min(w, h) / 2)

        var body = Path()
        body.addRoundedRect(in: CGRect(x: 0, y: 0, width: w, height: h),
                            cornerSize: CGSize(width: r, height: r),
                            style: .circular)
        guard hasTail else { return body }

        // Both ends of the hook sit inside the body so the union is seamless;
        // only the tip, below the base, actually shows.
        var tail = Path()
        if tailOnRight {
            let e = w                                   // outer edge
            tail.move(to: CGPoint(x: e - r * 0.95, y: h - r * 0.35))
            tail.addQuadCurve(to: CGPoint(x: e - r * 0.45, y: h + tailDrop),
                              control: CGPoint(x: e - r * 0.30, y: h + tailDrop * 0.55))
            tail.addQuadCurve(to: CGPoint(x: e - r * 1.15, y: h - 1),
                              control: CGPoint(x: e - r * 0.75, y: h + 1))
        } else {
            let e: CGFloat = 0
            tail.move(to: CGPoint(x: e + r * 0.95, y: h - r * 0.35))
            tail.addQuadCurve(to: CGPoint(x: e + r * 0.45, y: h + tailDrop),
                              control: CGPoint(x: e + r * 0.30, y: h + tailDrop * 0.55))
            tail.addQuadCurve(to: CGPoint(x: e + r * 1.15, y: h - 1),
                              control: CGPoint(x: e + r * 0.75, y: h + 1))
        }
        tail.closeSubpath()
        return body.union(tail)
    }
}

/// Messages' own metrics, so a run of bubbles reads as one person talking.
/// Every number here is read out of the Figma via `get_design_context`
/// (`kVIFjrXtrjwKw1bbAkdyEH`, bubble node 1:83), not measured off a render and
/// not guessed. The first pass at this redesign carried the OLD values through
/// unchanged and only repainted the fills, which is why it read as "close but
/// not the design".
/// The in-app text-size setting: one step index, persisted, driving Dynamic
/// Type for the whole app.
///
/// Deliberately Dynamic Type rather than a private multiplier. Every semantic
/// font (`.footnote`, `.callout`, the status line, the settings rows) follows
/// it for free, and the transcript's own point sizes — which the Figma
/// specifies exactly — follow via `@ScaledMetric`. One mechanism, so nothing
/// can scale out of step with anything else.
enum TextSize {
    static let key = "settings.textSizeStep"
    /// Seven notches, matching the tick marks in the design.
    static let steps: [DynamicTypeSize] = [.xSmall, .small, .medium, .large,
                                           .xLarge, .xxLarge, .xxxLarge]
    /// The untouched state: FOLLOW THE SYSTEM. The old default was step 3
    /// ("`.large` — the iOS default, so an untouched install looks like
    /// stock"), but forcing it at the root replaced the system Dynamic Type
    /// environment for everyone — a user who had chosen an accessibility
    /// text size in iOS was silently pushed back to `.large` until they
    /// found the in-app slider. Stock-looking is what NOT overriding gives
    /// you, for free, including the accessibility categories the slider's
    /// seven notches cannot reach. GitHub #12.
    ///
    /// Existing installs migrate correctly on their own: `@AppStorage` only
    /// persists on write, so a slider that was never touched left no stored
    /// value, and those installs now follow the system; a deliberately set
    /// size was written, and stays.
    static let system = -1
    static let defaultStep = system
    /// The explicit override for a slider step, or nil when the system
    /// environment should flow through untouched.
    static func override(for step: Int) -> DynamicTypeSize? {
        guard step != system else { return nil }
        return steps[min(max(step, 0), steps.count - 1)]
    }
    /// Where the slider thumb sits while no override is set: the notch
    /// nearest the CURRENT system size, so the first touch starts from what
    /// the user already sees. Accessibility categories sit past the last
    /// notch and clamp to it.
    static func nearestStep(to size: DynamicTypeSize) -> Int {
        if let exact = steps.firstIndex(of: size) { return exact }
        return size < steps[0] ? 0 : steps.count - 1
    }
}

/// Applies the user's explicit text-size choice, and only that: with no
/// choice made, the modifier adds nothing and the system Dynamic Type
/// environment reaches every descendant untouched. GitHub #12.
struct TextSizeOverride: ViewModifier {
    let step: Int
    func body(content: Content) -> some View {
        if let size = TextSize.override(for: step) {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}

enum ChatMetrics {
    /// 20pt, circular.
    static let radius: CGFloat = 20
    /// Text inset — 14 on all four sides. The vertical was 10, which is what
    /// made the bubbles sit tighter than the design.
    static let textHorizontal: CGFloat = 14
    static let textVertical: CGFloat = 14
    /// Between the heard line and the translation inside one bubble. The two
    /// lines sat 3pt apart; the design has them 8 apart (54 -> 62).
    static let lineGap: CGFloat = 8

    // Type. Fixed sizes rather than semantic styles because the design
    // specifies them exactly and half-points matter here; the text-size
    // slider that is coming will scale these by one multiplier.
    /// The reader's own language — 18pt, tracking -0.3.
    static let primarySize: CGFloat = 18
    static let primaryTracking: CGFloat = -0.3
    /// The other language — 14pt, tracking -0.08.
    static let secondarySize: CGFloat = 14
    static let secondaryTracking: CGFloat = -0.08
    /// How far the tail hangs below the bubble's base.
    static let tailDrop: CGFloat = 7
    /// Between two bubbles from the same speaker — same colour, one thought.
    /// The Figma measures 4pt body-to-body; doubled to 8 by product decision, so
    /// consecutive bubbles from one speaker read as separate utterances rather
    /// than one block of text.
    static let spacingWithinRun: CGFloat = 8
    /// Between speakers — different colour, a turn changing hands. Measured at
    /// 28 in the Figma and pulled back to 20 on Georg's eye: 28 read as a gap
    /// between two conversations rather than between two turns of one.
    static let spacingBetweenRuns: CGFloat = 20
    /// Bubble edge to screen edge. 20, not 16.
    static let screenMargin: CGFloat = 20
    /// A bubble never crosses this fraction of the width — it always hugs its
    /// own text, and this is only the ceiling.
    ///
    /// The design's widest body is 246pt on a 393pt screen (0.63), but the
    /// mock's strings are shorter than live German: at that cap "Das kostet
    /// Sie ungefähr 14 Euro." broke across two lines. Widened by product decision
    /// so the bubble follows the sentence instead of the sentence following
    /// the bubble.
    static let maxWidthFraction: CGFloat = 0.80
    /// How tall the transcript's lower scrim is. The top edge has always
    /// dissolved under the status bar; the bottom was a hard crop right above
    /// the mic button, which sliced whatever bubble happened to be there.
    ///
    /// 28, not 72: a tall band starts fading halfway up the empty space and
    /// pulls the whole transcript visually upward. Short and low means text
    /// stays crisp until it is nearly at the button.
    /// The Figma's scrim rectangle (node 1:51) is 185pt tall on a 393x852
    /// frame, top-anchored.
    static let topScrim: CGFloat = 185
    static let bottomScrim: CGFloat = 28
    /// Space kept below the newest bubble at rest, so the thing just said is
    /// never against the transcript's lower edge.
    ///
    /// Carried by the LAST ROW rather than by a trailing spacer: `scrollTo`
    /// anchors on a row, so a spacer after it just hangs below the fold and
    /// the bubble still lands on the edge. Stated outright rather than derived
    /// from `bottomScrim`, which no longer draws anything — a clearance that
    /// quietly tracked a deleted scrim was a number nobody could reason about.
    static let bottomClearance: CGFloat = 44
}
