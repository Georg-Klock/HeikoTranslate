import Foundation

/// Loads local secrets that must never be committed to git.
///
/// Setup: copy `HeikoTranslate/Resources/Secrets.plist.example` to
/// `HeikoTranslate/Resources/Secrets.plist` and fill in your Gemini API
/// key (console at aistudio.google.com). `Secrets.plist` is gitignored.
enum AppConfig {

    /// True when this process is an XCTest run.
    ///
    /// Used to keep MEASUREMENT flags out of the suite. Those flags live in
    /// `Secrets.plist`, which the test host bundles, so a device experiment
    /// switched on locally would otherwise change what L1 tests — and a green
    /// suite that depends on which flags a machine happens to carry is not a
    /// gate. Only ever used to force flags OFF; nothing here may make tests
    /// take a path the app cannot.
    static let isRunningTests: Bool = NSClassFromString("XCTestCase") != nil

    // One guard per failure, each named. These used to be a single guard
    // with a single "missing Secrets.plist" message — and under simulator
    // load a TRANSIENT read failure took that path and killed the app while
    // the file sat right there, its message sending the debugging the wrong
    // way (GitHub #68). A fatal error is still right for every one of these
    // (the app cannot run without the key); the message now says which
    // stage actually failed.
    static var geminiAPIKey: String = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist") else {
            fatalError("""
                Secrets.plist is not in the app bundle. Copy \
                HeikoTranslate/Resources/Secrets.plist.example and fill in a real key.
                """)
        }
        guard let data = try? Data(contentsOf: url) else {
            fatalError("""
                Secrets.plist is in the bundle but could not be READ — a \
                transient I/O failure, not a missing file (GitHub #68).
                """)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            fatalError("Secrets.plist was read but does not parse as a plist dictionary.")
        }
        guard let key = plist["GEMINI_API_KEY"] as? String, !key.isEmpty else {
            fatalError("Secrets.plist parses but has no non-empty GEMINI_API_KEY entry.")
        }
        return key
    }()

    /// Run ONE interpreter session instead of the pair (#135, experiment).
    ///
    /// Off unless `INTERPRETER_MODE` is set in `Secrets.plist`, which is
    /// gitignored — so no committed state can enable it and a build from a
    /// clean checkout is the shipping two-session app. This is a measurement
    /// build's switch, not a feature: the mode is under test, and the
    /// arbitration it replaces has years of device evidence behind it.
    static var interpreterMode: Bool = {
        // A measurement flag must never reach the test suite. L1 runs in a
        // host that bundles the real Secrets.plist, so switching this on for a
        // device run turned the suite red — the service opened ONE session
        // where the tests expect the pair, and ReplacementWindowTests crashed
        // on a nil unwrap. That is a test depending on local machine config,
        // which is the same defect the capture flag hit (L1.104a) and is
        // resolved the same way: tests get the shipping behaviour, always.
        if isRunningTests { return false }
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        if let flag = plist["INTERPRETER_MODE"] as? Bool { return flag }
        if let flag = plist["INTERPRETER_MODE"] as? String {
            return ["YES", "true", "1"].contains(flag)
        }
        return false
    }()

    /// Where "Zum Aktualisieren antippen" leads: this app's install page,
    /// read from `APP_UPDATE_URL` in Secrets.plist. Optional and read
    /// SOFTLY, unlike the key above — a build without it still shows the
    /// update sentence, the tap just has nowhere to go. It lives in
    /// Secrets.plist rather than the repo because the value is an unlisted
    /// App Store link: publishing it in a public repository would unlist it.
    /// GitHub #9.
    static var appUpdateURL: URL? = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = plist["APP_UPDATE_URL"] as? String, !string.isEmpty
        else { return nil }
        return URL(string: string)
    }()
}
