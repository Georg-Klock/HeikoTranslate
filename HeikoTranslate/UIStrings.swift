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
/// English was written alongside it. **Spanish, French, Korean and Chinese
/// have still never been read by a speaker of them** — that is what #6 asks
/// for and this is not it.
///
/// What they have had is a second AI pass (2026-08-13, decision on #6): every
/// string re-rendered independently and the reading kept that most of those
/// renderings agreed on, with a set's own established phrasing as the
/// tiebreaker — so `micDenied`'s "…tap to open Settings" pattern is what
/// `micResumeFailed` was made to match in Korean, rather than an outside
/// idea of good Korean. Consensus between AI renderings is a check on
/// carelessness, not on correctness: it catches a string nobody thought
/// about, and cannot catch four renderings that are wrong the same way.
/// Treat these as better than they were and still unverified.
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
    /// A failed AUTOMATIC resume — the app tried to restart listening by
    /// itself and could not. Deliberately actionable where micFailed is a
    /// statement: the reader was not at the button when this happened.
    /// German approved by Georg 2026-08-06 (GitHub #5); the other five ride
    /// the #6 native-review backlog like the rest of their sets.
    /// Also shown when the mic watchdog spends both rebuilds on a dead
    /// microphone and gives up (GitHub #87) — the same contract holds: the
    /// app tried by itself, could not, and a tap is the recovery.
    ///
    /// The four unreviewed sets all said some form of "tap the screen"
    /// until 2026-08-13, which is both vaguer than the contract (the tap
    /// that recovers is on the button) and drops the *why*. They now name
    /// the outcome — turn it back on — the way English does. #6.
    let micResumeFailed: String
    let connectionError: String
    /// The key this build shipped with has been revoked — rotation after
    /// abuse, see GitHub #9. Terminal in a way connectionError is not: no
    /// retry can ever work, only an update can, and the one button opens the
    /// update page (the micDenied pattern). German is a CANDIDATE awaiting
    /// Georg's on-device check; the other five ride the #6 review backlog.
    let updateRequired: String

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
    /// The privacy-policy row on the language sheet (GitHub #91). App Review
    /// 5.1.1(i) requires the policy link "within the app in an easily
    /// accessible manner"; this row opens the published policy. The word each
    /// language uses is the one its websites put on exactly this link — the
    /// reader is finding a legal page, not learning a coinage. German
    /// approved by Georg 2026-08-13; the other five ride the #6 backlog.
    let privacyPolicy: String

    // Accessibility
    let settingsLabel: String
    let startListeningLabel: String
    let stopListeningLabel: String

    /// Every selectable language — the six full ones plus the
    /// partner-only pair (#30) — named in THIS language.
    let languageNames: [TurnLogic.Lang: String]

    static func of(_ lang: TurnLogic.Lang) -> UIStrings {
        switch lang {
        // Partner-only languages (#30) can never be the HOME/reader side —
        // `canBeHome` gates the wheel and the collision swap — so no UI set
        // exists for them. German is the safe fallback if an impossible
        // state ever reaches here: the app's own language.
        case .tl, .vi: return german
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
        micResumeFailed: "Mikrofon ist aus — bitte antippen.",
        connectionError: "Verbindungsfehler. Bitte nochmal versuchen.",
        updateRequired: "Diese Version der App funktioniert nicht mehr. Zum Aktualisieren antippen.",
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
        privacyPolicy: "Datenschutz",
        settingsLabel: "Einstellungen",
        startListeningLabel: "Zuhören starten",
        stopListeningLabel: "Zuhören beenden",
        languageNames: [.de: "Deutsch", .en: "Englisch", .es: "Spanisch",
                        .fr: "Französisch", .ko: "Koreanisch", .zh: "Chinesisch",
                        .tl: "Tagalog", .vi: "Vietnamesisch"])

    static let english = UIStrings(
        connecting: "Connecting…",
        hearing: "Listening",
        translating: "Translating",
        micPaused: "Microphone paused",
        tapToSpeak: "Tap to speak",
        micDenied: "No microphone access. Tap to open Settings.",
        micFailed: "Couldn't start the microphone.",
        micResumeFailed: "Microphone is off — tap to turn it back on.",
        connectionError: "Connection problem. Please try again.",
        updateRequired: "This version of the app no longer works. Tap to update.",
        poorConnection: "Poor connection — translation quality may drop.",
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
        sendLogSubtitleFormat: "If something isn't working · %@",
        privacyPolicy: "Privacy policy",
        settingsLabel: "Settings",
        startListeningLabel: "Start listening",
        stopListeningLabel: "Stop listening",
        languageNames: [.de: "German", .en: "English", .es: "Spanish",
                        .fr: "French", .ko: "Korean", .zh: "Chinese",
                        .tl: "Tagalog", .vi: "Vietnamese"])

    // MARK: - Unreviewed translations (see the note on this type)

    static let spanish = UIStrings(
        connecting: "Conectando…",
        hearing: "Escuchando",
        translating: "Traduciendo",
        micPaused: "Micrófono en pausa",
        tapToSpeak: "Toca para hablar",
        micDenied: "Sin acceso al micrófono. Toca para abrir Configuración.",
        micFailed: "No se pudo iniciar el micrófono.",
        micResumeFailed: "El micrófono está apagado — toca para reactivarlo.",
        connectionError: "Error de conexión. Inténtalo de nuevo.",
        updateRequired: "Esta versión de la app ya no funciona. Toca para actualizar.",
        poorConnection: "Mala conexión — la traducción puede verse afectada.",
        noServerResponse: "El servidor no responde — revisa tu conexión.",
        offline: "Sin conexión a internet.",
        micResumed: "Micrófono activo de nuevo — la traducción continúa.",
        othersSpeak: "Los demás hablan",
        iSpeak: "Yo hablo",
        textSize: "Tamaño del texto",
        done: "Listo",
        usage: "Uso",
        minutesSpokenFormat: "%.0f minutos de conversación",
        sendLog: "Enviar el registro a Georg",
        sendLogSubtitleFormat: "Si algo no funciona · %@",
        privacyPolicy: "Política de privacidad",
        settingsLabel: "Configuración",
        startListeningLabel: "Empezar a escuchar",
        stopListeningLabel: "Dejar de escuchar",
        languageNames: [.de: "Alemán", .en: "Inglés", .es: "Español",
                        .fr: "Francés", .ko: "Coreano", .zh: "Chino",
                        .tl: "Tagalo", .vi: "Vietnamita"])

    static let french = UIStrings(
        connecting: "Connexion…",
        hearing: "À l'écoute",
        translating: "Traduction",
        micPaused: "Microphone en pause",
        tapToSpeak: "Touchez pour parler",
        micDenied: "Pas d'accès au microphone. Touchez pour ouvrir les Réglages.",
        micFailed: "Impossible de démarrer le microphone.",
        micResumeFailed: "Le microphone est coupé — touchez pour le réactiver.",
        connectionError: "Problème de connexion. Veuillez réessayer.",
        updateRequired: "Cette version de l'app ne fonctionne plus. Touchez pour mettre à jour.",
        poorConnection: "Connexion faible — la traduction peut s'en ressentir.",
        noServerResponse: "Pas de réponse du serveur — vérifiez votre connexion.",
        offline: "Pas de connexion internet.",
        micResumed: "Microphone réactivé — la traduction continue.",
        othersSpeak: "Les autres parlent",
        iSpeak: "Je parle",
        textSize: "Taille du texte",
        done: "Terminé",
        usage: "Utilisation",
        minutesSpokenFormat: "%.0f minutes de conversation",
        sendLog: "Envoyer le journal à Georg",
        sendLogSubtitleFormat: "Si quelque chose ne marche pas · %@",
        privacyPolicy: "Politique de confidentialité",
        settingsLabel: "Réglages",
        startListeningLabel: "Commencer à écouter",
        stopListeningLabel: "Arrêter d'écouter",
        languageNames: [.de: "Allemand", .en: "Anglais", .es: "Espagnol",
                        .fr: "Français", .ko: "Coréen", .zh: "Chinois",
                        .tl: "Tagalog", .vi: "Vietnamien"])

    static let korean = UIStrings(
        connecting: "연결 중…",
        hearing: "듣는 중",
        translating: "번역 중",
        micPaused: "마이크 일시정지",
        tapToSpeak: "탭하여 말하기",
        micDenied: "마이크 접근 권한이 없습니다. 설정을 열려면 탭하세요.",
        micFailed: "마이크를 시작할 수 없습니다.",
        micResumeFailed: "마이크가 꺼져 있습니다 — 다시 켜려면 탭하세요.",
        connectionError: "연결 오류입니다. 다시 시도해 주세요.",
        updateRequired: "이 버전은 더 이상 작동하지 않습니다. 업데이트하려면 탭하세요.",
        poorConnection: "연결 상태가 좋지 않습니다 — 번역 품질이 떨어질 수 있습니다.",
        noServerResponse: "서버 응답이 없습니다 — 인터넷 연결을 확인해 주세요.",
        offline: "인터넷에 연결되어 있지 않습니다.",
        micResumed: "마이크가 다시 켜졌습니다 — 번역이 계속됩니다.",
        othersSpeak: "상대방이 쓰는 언어",
        iSpeak: "내가 쓰는 언어",
        textSize: "글자 크기",
        done: "완료",
        usage: "사용량",
        minutesSpokenFormat: "말한 시간 %.0f분",
        sendLog: "Georg에게 로그 보내기",
        sendLogSubtitleFormat: "문제가 있을 때 · %@",
        privacyPolicy: "개인정보 처리방침",
        settingsLabel: "설정",
        startListeningLabel: "듣기 시작",
        stopListeningLabel: "듣기 중지",
        languageNames: [.de: "독일어", .en: "영어", .es: "스페인어",
                        .fr: "프랑스어", .ko: "한국어", .zh: "중국어",
                        .tl: "타갈로그어", .vi: "베트남어"])

    static let chinese = UIStrings(
        connecting: "连接中…",
        hearing: "聆听中",
        translating: "翻译中",
        micPaused: "麦克风已暂停",
        tapToSpeak: "轻点开始说话",
        micDenied: "无法访问麦克风。轻点前往设置。",
        micFailed: "无法启动麦克风。",
        micResumeFailed: "麦克风已关闭，轻点重新开启。",
        connectionError: "连接出错，请重试。",
        updateRequired: "此版本已无法使用。轻点前往更新。",
        poorConnection: "连接不佳，翻译质量可能会受影响。",
        noServerResponse: "服务器无响应，请检查网络连接。",
        offline: "没有网络连接。",
        micResumed: "麦克风已重新开启，翻译继续进行。",
        othersSpeak: "对方说的语言",
        iSpeak: "我说的语言",
        textSize: "文字大小",
        done: "完成",
        usage: "使用时长",
        minutesSpokenFormat: "共说了 %.0f 分钟",
        sendLog: "把日志发给 Georg",
        sendLogSubtitleFormat: "如果出了问题 · %@",
        privacyPolicy: "隐私政策",
        settingsLabel: "设置",
        startListeningLabel: "开始聆听",
        stopListeningLabel: "停止聆听",
        languageNames: [.de: "德语", .en: "英语", .es: "西班牙语",
                        .fr: "法语", .ko: "韩语", .zh: "中文",
                        .tl: "他加禄语", .vi: "越南语"])
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
