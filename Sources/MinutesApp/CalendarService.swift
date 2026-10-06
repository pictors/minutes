import EventKit
import Foundation
import MinutesCore

/// カレンダー上の会議候補（SPEC §6.1）。
struct CalendarCandidate: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var attendees: [Attendee]
    var organizer: String?
    var meetingURL: URL?
    var platform: MeetingPlatform
    var calendarIdentifier: String

    var pendingInfo: PendingMeetingInfo {
        PendingMeetingInfo(title: title, platform: platform, calendarEventId: id, calendarTitle: title, attendees: attendees, privacyMode: .cloudOk, calendarEndDate: endDate)
    }
}

/// EventKit ラッパ。Google カレンダーは macOS のカレンダーに追加済みである前提（アプリ側で OAuth は持たない）。
@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private(set) var authorized = false

    static func extractMeetingURL(from texts: [String?]) -> (URL, MeetingPlatform)? {
        let patterns: [(String, MeetingPlatform)] = [
            (#"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(\?[^\s<>"']*)?"#, .meet),
            (#"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"']+"#, .teams),
            (#"https://teams\.live\.com/meet/[^\s<>"']+"#, .teams),
        ]
        for text in texts.compactMap({ $0 }) {
            for (pattern, platform) in patterns {
                if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]), let url = URL(string: String(text[range])) {
                    return (url, platform)
                }
            }
        }
        return nil
    }

    func requestAccess() async -> Bool {
        do {
            authorized = try await store.requestFullAccessToEvents()
        } catch {
            authorized = false
        }
        return authorized
    }

    func calendars() -> [EKCalendar] {
        store.calendars(for: .event).sorted { $0.title < $1.title }
    }

    /// now − before 〜 now + after に開始し、Meet / Teams のリンクを含むイベント。
    func candidates(now: Date = Date(), before: TimeInterval = 10 * 60, after: TimeInterval = 10 * 60, calendarIdentifiers: [String] = []) -> [CalendarCandidate] {
        guard authorized else { return [] }
        let calendars = calendarIdentifiers.isEmpty ? nil : store.calendars(for: .event).filter { calendarIdentifiers.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-before - 4 * 3600), end: now.addingTimeInterval(after), calendars: calendars)
        return store.events(matching: predicate).compactMap { event in
            let start = event.startDate ?? now
            guard (event.endDate ?? start) > now, start <= now.addingTimeInterval(after) else { return nil }
            // 終日予定、取り消し済み、自分が辞退した予定は録音候補にしない（マイクを無駄に開かない）
            guard !event.isAllDay, event.status != .canceled else { return nil }
            if let me = event.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return nil }
            guard let (url, platform) = CalendarService.extractMeetingURL(from: [event.url?.absoluteString, event.notes, event.location]) else { return nil }
            let attendees = (event.attendees ?? []).compactMap { participant -> Attendee? in
                let name = participant.name ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                let email = participant.url.scheme == "mailto" ? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") : nil
                return Attendee(name: name, email: email)
            }
            return CalendarCandidate(
                id: event.eventIdentifier ?? event.calendarItemIdentifier,
                title: event.title ?? "会議",
                startDate: start,
                endDate: event.endDate ?? start.addingTimeInterval(3600),
                attendees: attendees,
                organizer: event.organizer?.name,
                meetingURL: url,
                platform: platform,
                calendarIdentifier: event.calendar.calendarIdentifier
            )
        }.sorted { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
    }
}
