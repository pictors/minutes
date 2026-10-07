import Foundation

/// 会議の言語（2026-10-07: 日本語と英語。ライブ字幕・確定の文字起こし・要約・書き出しが従う）。
/// 値は ISO 639-1（`meetings.language`、`TranscriptionRequest.language`、transcript.json の `language`）。
public enum MeetingLanguage: String, Codable, Sendable, CaseIterable {
    case ja
    case en

    /// "ja" / "jpn" / "ja-JP" / "en" / "eng" / "en_US" などを受け付ける。
    public init?(code: String?) {
        guard let code = code?.lowercased(), !code.isEmpty else { return nil }
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        switch base {
        case "ja", "jpn": self = .ja
        case "en", "eng": self = .en
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .ja: "日本語"
        case .en: "英語"
        }
    }

    /// ライブ字幕とこの Mac の中の文字起こし（SpeechAnalyzer）のロケール。
    public var locale: Locale {
        switch self {
        case .ja: SpeechAssets.defaultLocale
        case .en: Locale(identifier: "en-US")
        }
    }
}

/// 新しい会議の言語の選び方（設定と、次の録音の選択）。
public enum MeetingLanguageChoice: String, Codable, Sendable, CaseIterable {
    /// ライブ字幕を日本語で始め、会議のあとでライブ字幕の文字から英語の会議かを判定する。
    case auto
    case ja
    case en

    /// 決まった言語から（nil は自動）。
    public init(_ language: MeetingLanguage?) {
        switch language {
        case nil: self = .auto
        case .ja?: self = .ja
        case .en?: self = .en
        }
    }

    /// 決まった言語（自動なら nil）。
    public var language: MeetingLanguage? {
        switch self {
        case .auto: nil
        case .ja: .ja
        case .en: .en
        }
    }

    /// 録音を始めるときのライブ字幕の言語。
    public var liveLanguage: MeetingLanguage { language ?? .ja }

    public var title: String {
        switch self {
        case .auto: "自動"
        case .ja: "日本語"
        case .en: "英語"
        }
    }
}

/// 日本語のライブ字幕（ja-JP）の出力から、英語の会議かを判定する。
/// 2026-10-01 の調査: 英語の会議を ja-JP で認識するとラテン文字が 97%、日本語の会議 5 本は 0〜1%。
/// 英単語は 1 語で何文字にもなるので、英語の多い日本語の会議でも割合は半分に届きにくい。境目は余裕を取って 70%。
public enum MeetingLanguageDetector {
    public static let minimumLetters = 60
    public static let englishRatio = 0.7

    /// 判定できるだけの文字がなければ nil。
    public static func detect(_ texts: [String]) -> MeetingLanguage? {
        var latin = 0
        var japanese = 0
        for text in texts {
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x41...0x5A, 0x61...0x7A:
                    latin += 1
                case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF66...0xFF9F:
                    japanese += 1
                default:
                    break
                }
            }
        }
        guard latin + japanese >= minimumLetters else { return nil }
        return Double(latin) / Double(latin + japanese) >= englishRatio ? .en : .ja
    }
}
