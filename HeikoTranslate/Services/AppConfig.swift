import Foundation

/// Loads local secrets that must never be committed to git.
///
/// Setup: copy `HeikoTranslate/Resources/Secrets.plist.example` to
/// `HeikoTranslate/Resources/Secrets.plist` and fill in your Gemini API
/// key (console at aistudio.google.com). `Secrets.plist` is gitignored.
enum AppConfig {
    /// Where the diagnostic log is POSTed after a session, if anywhere.
    ///
    /// Absent by default, and absent means **nothing is ever uploaded**.
    /// Heiko's log contains the transcript of every conversation he has —
    /// his words and the words of whoever he was talking to — so switching
    /// this on is a decision about other people's speech, not just about
    /// debugging. Set `DIAGNOSTIC_UPLOAD_URL` in `Secrets.plist` only after
    /// telling Heiko the app does this.
    static var diagnosticUploadURL: URL? = {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let raw = plist["DIAGNOSTIC_UPLOAD_URL"] as? String,
            !raw.isEmpty, raw != "REPLACE-ME",
            let parsed = URL(string: raw), parsed.scheme?.lowercased() == "https"
        else { return nil }
        return parsed
    }()

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
}
