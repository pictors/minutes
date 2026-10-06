import Foundation

/// 起動・時刻経過・復帰・カレンダー更新が同時に来ても、同じ予定回を一度だけ開始する。
public struct AutoRecordingScheduler: Sendable {
    private let store: Store
    private let now: @Sendable () -> Date

    public init(store: Store, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func claim(eventId: String, start: Date, end: Date, enabled: Bool, appRunning: Bool, idle: Bool) throws -> Bool {
        let instant = now()
        guard enabled, appRunning, idle, start <= instant.addingTimeInterval(300), end > instant else { return false }
        // 繰り返し予定は EventKit の ID が同じことがあるので開始日時も含める。
        return try store.claimAutoRecording(occurrence: eventId + "/" + Store.isoString(start), expiresAt: end, now: instant)
    }
}
