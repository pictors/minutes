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

    /// やることの期限の出し方。
    struct Due: Equatable {
        enum Timing: Equatable { case overdue, today, upcoming, unknown }
        /// 「11/25（水）」・「今日」・「明日」（読めない形はそのまま）
        var text: String
        var timing: Timing
        /// 読み上げ用（「11月25日（水）、期限を過ぎています」）
        var spoken: String
    }

    /// 期限 "2026-11-25" を「11/25（水）」にする（年が違えば「2027/1/5（火）」、今日・明日はそう書く）。
    /// 期限は人が直せるので（Mac で書き換えた文など）、日付として読めない形はそのまま出す。和暦などの設定でも西暦で読む。
    static func due(_ raw: String, now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> Due {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard trimmed.count == 10, parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day
        else { return Due(text: trimmed, timing: .unknown, spoken: trimmed) }
        let weekday = date.formatted(Date.FormatStyle(locale: Locale(identifier: "ja_JP")).weekday(.abbreviated))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let sameYear = calendar.component(.year, from: now) == year
        let text = sameYear ? "\(month)/\(day)（\(weekday)）" : "\(year)/\(month)/\(day)（\(weekday)）"
        let spoken = sameYear ? "\(month)月\(day)日（\(weekday)）" : "\(year)年\(month)月\(day)日（\(weekday)）"
        switch days {
        case ..<0: return Due(text: text, timing: .overdue, spoken: "\(spoken)、期限を過ぎています")
        case 0: return Due(text: "今日", timing: .today, spoken: "今日")
        case 1: return Due(text: "明日", timing: .upcoming, spoken: "明日")
        default: return Due(text: text, timing: .upcoming, spoken: spoken)
        }
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
