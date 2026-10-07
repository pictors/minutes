import Foundation

/// グローバルショートカット（Carbon の仮想キーコードと修飾キーのビット）。表示用の文字列も保存する。
public struct GlobalShortcut: Codable, Sendable, Equatable {
    /// kVK_* の仮想キーコード。
    public var keyCode: UInt32
    /// Carbon の修飾キー（cmdKey / shiftKey / optionKey / controlKey の論理和）。
    public var carbonModifiers: UInt32
    /// "⌃⌥⌘R" のような表示。
    public var display: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }
}

/// 画面のテーマ（メニューバーのパネル・ウィンドウ・設定に共通）。
public enum AppAppearance: String, Codable, Sendable, CaseIterable {
    /// システム設定のライト / ダークに従う
    case system
    case light
    case dark
}

/// アプリ設定（SPEC §10.3）。`~/Library/Application Support/Minutes/settings.json` に JSON で保存する。
/// API キーはここに入れず Keychain に置く。
public struct AppSettings: Codable, Sendable, Equatable {
    public static let fileName = "settings.json"
    public static let defaultTargetBundleIdentifiers = ["com.google.Chrome", "com.microsoft.teams2", "com.apple.Safari", "company.thebrowser.Browser"]

    public var targetBundleIdentifiers: [String] = AppSettings.defaultTargetBundleIdentifiers
    /// 決定（2026-09-17）: 既定は ElevenLabs Scribe v2
    public var finalProviderId: String = "elevenlabs.scribe_v2"
    public var summaryModel: String = ClaudeSummarizer.defaultModel
    /// nil（旧設定も含む）は Codex を使う。Claude のモデル設定は保持する。
    public var summaryProvider: SummaryProvider?
    public var codexModel: String?
    public var codexExecutablePath: String?
    /// Claude Code の --model（エイリアスかモデル名）。nil なら Claude Code の設定に従う。
    public var claudeCodeModel: String?
    public var claudeCodeExecutablePath: String?
    public var resolvedSummaryProvider: SummaryProvider { summaryProvider ?? .codex }
    public var defaultPrivacyMode: PrivacyMode = .cloudOk
    public var audioRetentionDays: Int = 30
    /// 書き出しフォルダ（nil = Application Support/Minutes/export）
    public var exportDirectory: String?
    /// 同期先フォルダ（Google Drive / Dropbox 等）。nil なら同期しない
    public var syncDirectory: String?
    public var calendarIdentifiers: [String] = []
    public var autoStartOnAudio: Bool = true
    /// true なら音声検知後に自動開始せず、確認（通知 / 画面のボタン）を待つ（SPEC §6.2）。
    public var confirmBeforeAutoStart: Bool = false
    public var silenceTimeoutSeconds: Double = 180
    public var keytermsAutoLearn: Bool = true
    /// 新しい会議の言語（2026-10-07）。自動はライブ字幕を日本語で始め、会議のあとで英語の会議かを判定する。
    /// 録音中はパネルや録音画面で切り替えられる。
    public var meetingLanguage: MeetingLanguageChoice = .auto
    /// 英語の会議の要約の言語（2026-10-07 決定: 既定は英語）。
    public var englishSummaryLanguage: MeetingLanguage = .en
    public var includeMic: Bool = true
    /// 自分（mic トラック "me"）の表示名。空なら「自分」/ 書き出しは "me"。
    public var selfName: String?
    /// マイク入力デバイスの UID。nil ならシステムの既定入力（snake_case 往復のため名前は micDevice）。
    public var micDevice: String?
    /// 録音の開始 / 停止のグローバルショートカット（Carbon ホットキー）。nil なら無効。
    public var globalShortcut: GlobalShortcut?
    /// テーマ。既定はシステムに従う。
    public var appearance: AppAppearance = .system
    /// 初回の案内を終えた日時。nil なら、会議がまだない環境で初回の案内を出す（2026-10-05 決定）。
    public var onboardingCompletedAt: Date?
    /// 参加者に録音を知らせる文面。nil か空なら `AppSettings.defaultRecordingNotice`。
    public var recordingNotice: String?

    public static let defaultRecordingNotice = "この会議は、議事録を作るために録音と文字起こしをしています。録音を望まない方はお知らせください。"

    public var resolvedRecordingNotice: String {
        let text = recordingNotice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? Self.defaultRecordingNotice : text
    }

    public init() {}

    /// 旧い settings.json（キーが足りない）も既定値で読めるようにする。未知のキーは無視する。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        targetBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .targetBundleIdentifiers) ?? defaults.targetBundleIdentifiers
        finalProviderId = try container.decodeIfPresent(String.self, forKey: .finalProviderId) ?? defaults.finalProviderId
        summaryModel = try container.decodeIfPresent(String.self, forKey: .summaryModel) ?? defaults.summaryModel
        // 未知のプロバイダ（新しい版で増えた値）でほかの設定まで既定に戻さない
        summaryProvider = (try? container.decodeIfPresent(String.self, forKey: .summaryProvider)).flatMap(SummaryProvider.init(rawValue:))
        codexModel = try container.decodeIfPresent(String.self, forKey: .codexModel)
        codexExecutablePath = try container.decodeIfPresent(String.self, forKey: .codexExecutablePath)
        claudeCodeModel = try container.decodeIfPresent(String.self, forKey: .claudeCodeModel)
        claudeCodeExecutablePath = try container.decodeIfPresent(String.self, forKey: .claudeCodeExecutablePath)
        defaultPrivacyMode = try container.decodeIfPresent(PrivacyMode.self, forKey: .defaultPrivacyMode) ?? defaults.defaultPrivacyMode
        audioRetentionDays = try container.decodeIfPresent(Int.self, forKey: .audioRetentionDays) ?? defaults.audioRetentionDays
        exportDirectory = try container.decodeIfPresent(String.self, forKey: .exportDirectory)
        syncDirectory = try container.decodeIfPresent(String.self, forKey: .syncDirectory)
        calendarIdentifiers = try container.decodeIfPresent([String].self, forKey: .calendarIdentifiers) ?? defaults.calendarIdentifiers
        autoStartOnAudio = try container.decodeIfPresent(Bool.self, forKey: .autoStartOnAudio) ?? defaults.autoStartOnAudio
        confirmBeforeAutoStart = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeAutoStart) ?? defaults.confirmBeforeAutoStart
        silenceTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .silenceTimeoutSeconds) ?? defaults.silenceTimeoutSeconds
        keytermsAutoLearn = try container.decodeIfPresent(Bool.self, forKey: .keytermsAutoLearn) ?? defaults.keytermsAutoLearn
        // 会議の言語を持つ前は、ライブ字幕のロケール（live_locale）だけを選べた。英語にしていたら英語の会議として引き継ぐ
        let legacyLiveLocale = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .liveLocale)
        meetingLanguage = (try? container.decodeIfPresent(String.self, forKey: .meetingLanguage)).flatMap(MeetingLanguageChoice.init(rawValue:))
            ?? (MeetingLanguage(code: legacyLiveLocale) == .en ? .en : defaults.meetingLanguage)
        englishSummaryLanguage = (try? container.decodeIfPresent(String.self, forKey: .englishSummaryLanguage)).flatMap(MeetingLanguage.init(rawValue:)) ?? defaults.englishSummaryLanguage
        includeMic = try container.decodeIfPresent(Bool.self, forKey: .includeMic) ?? defaults.includeMic
        selfName = try container.decodeIfPresent(String.self, forKey: .selfName)
        micDevice = try container.decodeIfPresent(String.self, forKey: .micDevice)
        globalShortcut = try container.decodeIfPresent(GlobalShortcut.self, forKey: .globalShortcut)
        // 未知の値（新しい版で増えたテーマ等）でほかの設定まで既定に戻さない
        appearance = (try? container.decodeIfPresent(String.self, forKey: .appearance)).flatMap(AppAppearance.init(rawValue:)) ?? defaults.appearance
        onboardingCompletedAt = try? container.decodeIfPresent(Date.self, forKey: .onboardingCompletedAt)
        recordingNotice = try container.decodeIfPresent(String.self, forKey: .recordingNotice)
    }

    private enum LegacyKeys: String, CodingKey {
        case liveLocale
    }

    public var resolvedSelfName: String? {
        selfName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? selfName?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    public static func defaultURL() -> URL {
        Store.applicationSupportDirectory().appendingPathComponent(fileName)
    }

    public static func load(from url: URL = defaultURL()) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONCoding.decoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(to url: URL = AppSettings.defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(self).write(to: url, options: .atomic)
    }

    public var exportDirectoryURL: URL {
        exportDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Store.applicationSupportDirectory().appendingPathComponent("export", isDirectory: true)
    }

    public var audioRootDirectoryURL: URL {
        Store.applicationSupportDirectory().appendingPathComponent("audio", isDirectory: true)
    }

    public var syncDirectoryURL: URL? {
        syncDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
