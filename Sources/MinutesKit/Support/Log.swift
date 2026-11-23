import Foundation
import os

/// os.Logger のラッパ。本文・音声・キーは出さない（SPEC §14）。
/// 文字起こし本文を debug で出すときは `Log.preview` で先頭 40 文字に切る。
public enum Log {
    public static let subsystem = "jp.pictors.minutes"

    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let cli = Logger(subsystem: subsystem, category: "cli")
    public static let network = Logger(subsystem: subsystem, category: "network")

    /// 本文のログ用プレビュー（先頭 40 文字）。
    public static func preview(_ text: String, limit: Int = 40) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }
}
