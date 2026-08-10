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

    static var geminiAPIKey: String = {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let key = plist["GEMINI_API_KEY"] as? String,
            !key.isEmpty
        else {
            fatalError("""
                Missing HeikoTranslate/Resources/Secrets.plist with a GEMINI_API_KEY entry. \
                Copy Secrets.plist.example and fill in a real key.
                """)
        }
        return key
    }()
}
