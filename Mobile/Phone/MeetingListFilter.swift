import Foundation

/// 一覧の絞り込み: 範囲（Mac のスマートフォルダと同じ言葉）、録った機器、会議の名前の検索。
/// iPhone が持つのは一覧の情報（題名・日時・状態・録った機器）だけなので、検索は会議の名前に当てる
/// （本文と要約は会議ごとにサーバーにあり、検索するにはサーバーの索引が要る）。
struct MeetingListFilter: Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case all, today, thisWeek, processing, failed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "すべて"
            case .today: "今日"
            case .thisWeek: "今週"
            case .processing: "処理中"
            case .failed: "失敗"
            }
        }
    }

    var scope: Scope = .all
    /// nil はどの機器でも
    var origin: MeetingOrigin?
    var query = ""

    /// 検索の語（空白で区切る。すべての語を含む会議だけ）
    var terms: [String] { TextSearch.terms(query) }

    /// 絞り込んでいるか（すべて・どの機器でも・検索なしなら false）
    var isActive: Bool { scope != .all || origin != nil || !terms.isEmpty }

    func matches(_ item: MeetingItem, recordingClientId: String?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if let origin, item.origin != origin { return false }
        switch scope {
        case .all:
            break
        case .today:
            if !calendar.isDate(item.startedAt, inSameDayAs: now) { return false }
        case .thisWeek:
            // Mac の「今週」と同じ: その週の始まりから
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            if item.startedAt < start { return false }
        case .processing:
            if Formatting.state(item, recordingClientId: recordingClientId)?.isBusy != true { return false }
        case .failed:
            if Formatting.state(item, recordingClientId: recordingClientId)?.isError != true { return false }
        }
        return TextSearch.matches(item.title ?? MeetingItem.untitled, terms: terms)
    }

    func apply(_ items: [MeetingItem], recordingClientId: String?, now: Date = Date(), calendar: Calendar = .current) -> [MeetingItem] {
        guard isActive else { return items }
        return items.filter { matches($0, recordingClientId: recordingClientId, now: now, calendar: calendar) }
    }

    /// その範囲に当てはまる会議の数（処理中・失敗のチップに添える）
    static func count(_ scope: Scope, in items: [MeetingItem], recordingClientId: String?) -> Int {
        let filter = MeetingListFilter(scope: scope)
        return items.count { filter.matches($0, recordingClientId: recordingClientId) }
    }
}
