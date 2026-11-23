import Foundation

// 会議の言語のロケール（SpeechAnalyzer を使うので Mac に残す。言語そのものは MinutesKit）
public extension MeetingLanguage {
    /// ライブ字幕とこの Mac の中の文字起こし（SpeechAnalyzer）のロケール。
    var locale: Locale {
        switch self {
        case .ja: SpeechAssets.defaultLocale
        case .en: Locale(identifier: "en-US")
        }
    }
}
