import Foundation

/// 会議時間の集計（メニューバーの「概要」）。録音中の会議は現在時刻までを数え、日をまたぐ会議は開始日に数える。
public enum MeetingTimeStats {
    public struct Entry: Sendable, Equatable {
        public var meeting: MeetingRecord
        public var seconds: TimeInterval
    }

    public struct Day: Sendable, Equatable {
        /// その日の 0 時
        public var start: Date
        /// 開始順
        public var entries: [Entry]
        public var total: TimeInterval { entries.reduce(0) { $0 + $1.seconds } }
    }

    public struct Week: Sendable, Equatable {
        public var start: Date
        /// 週の初日から 7 日分（週の始まりは Calendar に従う）
        public var days: [Day]
        public var total: TimeInterval { days.reduce(0) { $0 + $1.total } }
        /// 前週の合計。今週なら前週の同じ経過時点まで（途中の週どうしを比べる）。
        public var previousTotal: TimeInterval
        /// 前週比（-0.12 = 12% 減）。前週が 0 なら nil。
        public var change: Double? { previousTotal > 0 ? total / previousTotal - 1 : nil }
    }

    /// 会議の長さ。終了していない会議は録音中・終了待ちに限り現在時刻まで数える（失敗して終了時刻がない会議は 0）。
    public static func seconds(of meeting: MeetingRecord, now: Date) -> TimeInterval {
        let end: Date
        if let endedAt = meeting.endedAt {
            end = endedAt
        } else if meeting.meetingStatus == .recording || meeting.meetingStatus == .finalizing {
            end = now
        } else {
            end = meeting.startedAt
        }
        return max(0, end.timeIntervalSince(meeting.startedAt))
    }

    /// `day` と同じ日に開始した会議（開始順）。
    public static func day(_ day: Date, meetings: [MeetingRecord], now: Date, calendar: Calendar = .current) -> Day {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let entries = meetings
            .filter { $0.startedAt >= start && $0.startedAt < end }
            .sorted { $0.startedAt < $1.startedAt }
            .map { Entry(meeting: $0, seconds: seconds(of: $0, now: now)) }
        return Day(start: start, entries: entries)
    }

    /// `date` を含む週。
    public static func week(containing date: Date, meetings: [MeetingRecord], now: Date, calendar: Calendar = .current) -> Week {
        let interval = calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86_400)
        let days = (0..<7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: interval.start) ?? interval.start.addingTimeInterval(Double(offset) * 86_400)
            return self.day(day, meetings: meetings, now: now, calendar: calendar)
        }
        let previousStart = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start) ?? interval.start.addingTimeInterval(-7 * 86_400)
        // 今週は「前週の同じ経過時点」まで。過去の週は前週全体と比べる。
        let elapsed = interval.contains(now) ? now.timeIntervalSince(interval.start) : interval.duration
        let previousEnd = previousStart.addingTimeInterval(elapsed)
        let previousTotal = meetings
            .filter { $0.startedAt >= previousStart && $0.startedAt < previousEnd }
            .reduce(0) { $0 + seconds(of: $1, now: now) }
        return Week(start: interval.start, days: days, previousTotal: previousTotal)
    }
}
