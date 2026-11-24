import Foundation
import MinutesKit

/// 画面の表示の決まり（日本語）。
enum Formatting {
    /// 11月23日（日）14:05
    static func meetingDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "ja_JP")))
    }

    /// 12:34 か 1:02:03
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 1時間2分 / 12分 / 40秒
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)秒" }
        let minutes = (total + 30) / 60
        return minutes >= 60 ? "\(minutes / 60)時間\(minutes % 60)分" : "\(minutes)分"
    }

    /// 話者の表示名（名前がなければ「話者 1」）
    static func speaker(_ label: String?, in document: TranscriptDocument?) -> String {
        guard let label else { return "話者" }
        if let name = document?.speakers.first(where: { $0.label == label })?.name, !name.isEmpty { return name }
        if label == "me" { return "自分" }
        if let number = Int(label.split(separator: "_").last ?? "") { return "話者 \(number + 1)" }
        return label
    }

    /// やることの担当者の表示名。要約は担当者を "me"・"agent"・話者のラベルか名前で返す（Mac の ActionRow と同じ読み方）。空なら出さない
    static func owner(_ owner: String, in document: TranscriptDocument?) -> String? {
        switch owner {
        case "": nil
        case "agent": "エージェント"
        default: speaker(owner, in: document)
        }
    }

    /// 一覧と詳細に出す状態（空なら出さない）
    static func status(_ item: MeetingItem, recordingClientId: String?) -> String {
        if item.id == recordingClientId { return "録音中" }
        if let local = item.local, !local.completed {
            if let error = local.lastError { return "送れていません: \(error)" }
            if !CloudEnvironment.uploadsAllowed { return "この端末に保存（シミュレータからは本番に送りません）" }
            if !local.stopped { return "録音中" }
            return "送っています"
        }
        switch item.server?.status {
        case "uploading": return "送っています"
        case "queued", "transcribing": return "文字起こし中"
        case "summarizing": return "議事録を作っています"
        case "failed": return "失敗しました\(item.server?.error.map { "（\($0)）" } ?? "")"
        case "done": return item.server?.summaryError != nil ? "要約できませんでした（文字起こしはあります）" : ""
        case nil: return item.local?.lastError ?? "サーバーで処理しています"
        default: return ""
        }
    }
}
