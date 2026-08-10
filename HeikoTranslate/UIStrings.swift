import Foundation

/// Every word the app says, in the language of the person reading it.
///
/// The **home** language — the right-hand bubble, the phone owner's own
/// language — decides this, NOT the system locale. That is deliberate: the
/// phone belongs to one person, the app's whole premise is that they cannot
/// read the other language, and the home wheel is where they already told us
/// which one is theirs. Asking them to also set an app language would be a
/// second answer to a question they have answered once.
///
/// A `struct` with named fields rather than a dictionary of keys, so the
/// compiler — not a test, not a review — is what guarantees every language has
/// every string. A missing translation is a build error.
///
/// **Review status.** German is the reviewed original (see `GermanUITests`).
/// English was written alongside it. **Spanish, French, Korean and Chinese are
/// unreviewed translations** — they are complete and idiomatic as far as I can
/// judge, but nobody who speaks those languages has read them, and this is an
/// app whose users by definition cannot check a translation themselves. They
/// should have a native reader before anyone relies on them.
struct UIStrings {
    // Status line
    let connecting: String
    let hearing: String
    let translating: String
    let micPaused: String

    // Hints and errors
    let tapToSpeak: String
    let micDenied: String
    let micFailed: String
    let connectionError: String

    // Connection warnings
    let poorConnection: String
    let noServerResponse: String
    let offline: String
    let micResumed: String

    // Settings sheet
    /// Above the left wheel and the right wheel. They name the two sides in
    /// terms of WHO is talking, not "partner"/"home" — the distinction the
    /// user actually has to make when handing the phone across a table.
    let othersSpeak: String
    let iSpeak: String
    /// Accessibility label for the text-size slider, which is otherwise two
    /// letter As and unreadable to VoiceOver.
    let textSize: String
    let done: String
    let usage: String
    /// One `%.0f` — minutes spoken.
    let minutesSpokenFormat: String
    let sendLog: String
    /// `%@` is the build number. Deliberately joined to the subtitle rather
    /// than shown on its own row: when Georg asks "which build are you on?",
    /// the answer sits on the line right under the button he is asking Heiko
    /// to press, so one screenshot answers both questions.
    let sendLogSubtitleFormat: String

    // Accessibility
    let settingsLabel: String
    let startListeningLabel: String
    let stopListeningLabel: String

    /// The six languages, named in THIS language.
    let languageNames: [TurnLogic.Lang: String]

    static func of(_ lang: TurnLogic.Lang) -> UIStrings {
        switch lang {
        case .de: return german
        case .en: return english
        case .es: return spanish
        case .fr: return french
        case .ko: return korean
        case .zh: return chinese
        }
    }

    /// The reviewed original. Heiko reads this one.
    static let german = UIStrings(
        connecting: "Verbinde…",
        hearing: "Verstehe",
        translating: "Übersetze",
        micPaused: "Mikrofon pausiert",
        tapToSpeak: "Zum Sprechen antippen",
        micDenied: "Kein Mikrofonzugriff. Zum Öffnen der Einstellungen antippen.",
        micFailed: "Mikrofon konnte nicht gestartet werden.",
        connectionError: "Verbindungsfehler. Bitte nochmal versuchen.",
        poorConnection: "Schlechte Verbindung — die Übersetzung kann darunter leiden.",
        noServerResponse: "Keine Antwort vom Server — bitte Internetverbindung prüfen.",
        offline: "Keine Internetverbindung.",
        micResumed: "Mikrofon wieder aktiv — die Übersetzung läuft weiter.",
        othersSpeak: "Andere sprechen",
        iSpeak: "Ich spreche",
        textSize: "Textgröße",
        done: "Fertig",
        usage: "Nutzung",
        minutesSpokenFormat: "%.0f Minuten gesprochen",
        sendLog: "Protokoll an Georg senden",
        sendLogSubtitleFormat: "Falls etwas nicht klappt · %@",
        settingsLabel: "Einstellungen",
        startListeningLabel: "Zuhören starten",
        stopListeningLabel: "Zuhören beenden",
        languageNames: [.de: "Deutsch", .en: "Englisch", .es: "Spanisch",
                        .fr: "Französisch", .ko: "Koreanisch", .zh: "Chinesisch"])

    static let english = UIStrings(
        connecting: "Connecting…",
        hearing: "Listening",
        translating: "Translating",
        micPaused: "Microphone paused",
        tapToSpeak: "Tap to speak",
        micDenied: "No microphone access. Tap to open Settings.",
        micFailed: "The microphone could not be started.",
        connectionError: "Connection problem. Please try again.",
        poorConnection: "Poor connection — the translation may suffer.",
        noServerResponse: "No response from the server — please check your connection.",
        offline: "No internet connection.",
        micResumed: "Microphone back on — translation continues.",
        othersSpeak: "Others speak",
        iSpeak: "I speak",
        textSize: "Text size",
        done: "Done",
        usage: "Usage",
        minutesSpokenFormat: "%.0f minutes spoken",
        sendLog: "Send the log to Georg",
        sendLogSubtitleFormat: "If something goes wrong · %@",
        settingsLabel: "Settings",
        startListeningLabel: "Start listening",
        stopListeningLabel: "Stop listening",
        languageNames: [.de: "German", .en: "English", .es: "Spanish",
                        .fr: "French", .ko: "Korean", .zh: "Chinese"])

    // MARK: - Unreviewed translations (see the note on this type)

    static let spanish = UIStrings(
        connecting: "Conectando…",
        hearing: "Escuchando",
        translating: "Traduciendo",
        micPaused: "Micrófono en pausa",
        tapToSpeak: "Toca para hablar",
        micDenied: "Sin acceso al micrófono. Toca para abrir Ajustes.",
        micFailed: "No se pudo iniciar el micrófono.",
        connectionError: "Error de conexión. Inténtalo de nuevo.",
        poorConnection: "Conexión débil — la traducción puede verse afectada.",
        noServerResponse: "El servidor no responde — comprueba tu conexión.",
        offline: "Sin conexión a internet.",
        micResumed: "Micrófono activo de nuevo — la traducción continúa.",
        othersSpeak: "Otros hablan",
        iSpeak: "Yo hablo",
        textSize: "Tamaño del texto",
        done: "Listo",
        usage: "Uso",
        minutesSpokenFormat: "%.0f minutos hablados",
        sendLog: "Enviar el registro a Georg",
        sendLogSubtitleFormat: "Si algo no funciona · %@",
        settingsLabel: "Ajustes",
        startListeningLabel: "Empezar a escuchar",
        stopListeningLabel: "Dejar de escuchar",
        languageNames: [.de: "Alemán", .en: "Inglés", .es: "Español",
                        .fr: "Francés", .ko: "Coreano", .zh: "Chino"])

    static let french = UIStrings(
        connecting: "Connexion…",
        hearing: "À l'écoute",
        translating: "Traduction",
        micPaused: "Microphone en pause",
        tapToSpeak: "Appuyez pour parler",
        micDenied: "Pas d'accès au microphone. Appuyez pour ouvrir Réglages.",
        micFailed: "Impossible de démarrer le microphone.",
        connectionError: "Problème de connexion. Veuillez réessayer.",
        poorConnection: "Connexion faible — la traduction peut en souffrir.",
        noServerResponse: "Pas de réponse du serveur — vérifiez votre connexion.",
        offline: "Pas de connexion internet.",
        micResumed: "Microphone réactivé — la traduction continue.",
        othersSpeak: "Les autres parlent",
        iSpeak: "Je parle",
        textSize: "Taille du texte",
        done: "Terminé",
        usage: "Utilisation",
        minutesSpokenFormat: "%.0f minutes parlées",
        sendLog: "Envoyer le journal à Georg",
        sendLogSubtitleFormat: "Si quelque chose ne marche pas · %@",
        settingsLabel: "Réglages",
        startListeningLabel: "Commencer à écouter",
        stopListeningLabel: "Arrêter d'écouter",
        languageNames: [.de: "Allemand", .en: "Anglais", .es: "Espagnol",
                        .fr: "Français", .ko: "Coréen", .zh: "Chinois"])

    static let korean = UIStrings(
        connecting: "연결 중…",
        hearing: "듣는 중",
        translating: "번역 중",
        micPaused: "마이크 일시정지",
        tapToSpeak: "탭하여 말하기",
        micDenied: "마이크 접근 권한이 없습니다. 탭하여 설정을 여세요.",
        micFailed: "마이크를 시작할 수 없습니다.",
        connectionError: "연결 오류입니다. 다시 시도해 주세요.",
        poorConnection: "연결 상태가 좋지 않습니다 — 번역 품질이 떨어질 수 있습니다.",
        noServerResponse: "서버 응답이 없습니다 — 인터넷 연결을 확인하세요.",
        offline: "인터넷에 연결되어 있지 않습니다.",
        micResumed: "마이크가 다시 켜졌습니다 — 번역이 계속됩니다.",
        othersSpeak: "상대방 언어",
        iSpeak: "내 언어",
        textSize: "글자 크기",
        done: "완료",
        usage: "사용량",
        minutesSpokenFormat: "%.0f분 말함",
        sendLog: "Georg에게 로그 보내기",
        sendLogSubtitleFormat: "문제가 있을 때 · %@",
        settingsLabel: "설정",
        startListeningLabel: "듣기 시작",
        stopListeningLabel: "듣기 중지",
        languageNames: [.de: "독일어", .en: "영어", .es: "스페인어",
                        .fr: "프랑스어", .ko: "한국어", .zh: "중국어"])

    static let chinese = UIStrings(
        connecting: "连接中…",
        hearing: "聆听中",
        translating: "翻译中",
        micPaused: "麦克风已暂停",
        tapToSpeak: "点按说话",
        micDenied: "无法访问麦克风。点按以打开设置。",
        micFailed: "无法启动麦克风。",
        connectionError: "连接出错，请重试。",
        poorConnection: "连接不佳 — 翻译质量可能受影响。",
        noServerResponse: "服务器无响应 — 请检查网络连接。",
        offline: "没有网络连接。",
        micResumed: "麦克风已重新开启 — 翻译继续。",
        othersSpeak: "对方说",
        iSpeak: "我说",
        textSize: "文字大小",
        done: "完成",
        usage: "用量",
        minutesSpokenFormat: "已说 %.0f 分钟",
        sendLog: "把日志发给 Georg",
        sendLogSubtitleFormat: "如果出了问题 · %@",
        settingsLabel: "设置",
        startListeningLabel: "开始聆听",
        stopListeningLabel: "停止聆听",
        languageNames: [.de: "德语", .en: "英语", .es: "西班牙语",
                        .fr: "法语", .ko: "韩语", .zh: "中文"])
}

extension TurnLogic.Lang {
    /// The name of this language, written in `reader`'s language.
    func name(in reader: TurnLogic.Lang) -> String {
        UIStrings.of(reader).languageNames[self] ?? displayName
    }

    /// The name of this language **in itself** — Deutsch, English, Español,
    /// Français, 한국어, 中文.
    ///
    /// Falls out of the string sets for free: a language's own name inside its
    /// own set IS the endonym, so there is no second table to keep in step.
    var endonym: String { UIStrings.of(self).languageNames[self] ?? displayName }
}
