import Foundation

/// One plain version number that changes on every upload — e.g. "2.3.39".
///
/// Shared, because two screens show it: the chat screen's corner, and the
/// log-sharing row in settings. It is the number Georg asks Heiko to read off
/// the screen, so the two must never be able to disagree.
///
/// This used to be `CFBundleShortVersionString` alone, which meant the
/// marketing version had to move on every install for it to change. That is
/// exactly wrong for TestFlight: Apple reviews the *first build of a version*,
/// so a new marketing version puts every update to Heiko behind a fresh review
/// — a day instead of minutes, while he is abroad and the app is the reason he
/// can order lunch. Holding the marketing version steady and appending the
/// build number keeps both: a number that always moves, and the fast path to
/// external testers.
enum AppVersion {
    static let label: String = {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        // Pad to two digits so it keeps a steady width: "2.3.07", not "2.3.7".
        // Builds past 99 simply get wider, which is fine.
        let padded = build.count == 1 ? "0" + build : build
        return "\(short).\(padded)"
    }()
}
