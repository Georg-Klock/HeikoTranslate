import SwiftUI

@main
struct HeikoTranslateApp: App {
    init() {
        // Touch the logger immediately so every launch is recorded, even one
        // where the user opens the app and does nothing — "it did nothing" is
        // exactly the report we need evidence for.
        diag("app", "process start")
        // One line answering "which languages can the referee actually work
        // on THIS phone" (#135). Without it the answer only arrives for the
        // pair currently selected, so learning it for six languages meant six
        // pair switches and six conversations. Capability queries only — no
        // authorization prompt, no audio, no recognition.
        LanguageReferee.logOnDeviceCapability()
    }

    /// The in-app text-size setting, applied HERE rather than inside
    /// `ContentView`.
    ///
    /// This is the whole reason the slider only appeared to work: a
    /// `.dynamicTypeSize(…)` written inside a view's own `body` applies to
    /// that view's DESCENDANTS, not to the view itself — so `ContentView`'s
    /// own `@ScaledMetric` properties, which is where the transcript's point
    /// sizes live, kept reading the unmodified environment. Semantic fonts
    /// further down the tree scaled; the bubbles did not, which looked like
    /// "it only works inside settings".
    ///
    /// Applied one level up, `ContentView` inherits it and every size in the
    /// app moves together.
    @AppStorage(TextSize.key) private var textSizeStep = TextSize.defaultStep

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(TextSizeOverride(step: textSizeStep))
        }
    }
}
