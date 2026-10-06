import Foundation
import MinutesCore
import Observation
import Synchronization
import Testing

/// Observation の通知を受けたか（通知は @Sendable のクロージャから来る）。
private final class ChangeFlag: Sendable {
    let changed = Mutex(false)
}

/// メニューバーのパネルと会議詳細の集計（会議時間・発言時間）、テーマ設定。
@Suite("パネルの集計とテーマ設定")
struct PanelDataTests {
    /// 月曜始まり・UTC の暦（実行環境のロケールに依存させない）。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // 2026-09-21 は月曜
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func meeting(_ title: String, start: Date, minutes: Double?, status: MeetingStatus = .done) -> MeetingRecord {
        MeetingRecord(title: title, startedAt: start, endedAt: minutes.map { start.addingTimeInterval($0 * 60) }, privacyMode: .cloudOk, status: status)
    }

    @Test("会議の長さ: 録音中は現在時刻まで、終了時刻のない失敗は 0")
    func meetingSeconds() {
        let now = date(24, 10, 30)
        #expect(MeetingTimeStats.seconds(of: meeting("済", start: date(24, 9), minutes: 45), now: now) == 45 * 60)
        #expect(MeetingTimeStats.seconds(of: meeting("録音中", start: date(24, 10), minutes: nil, status: .recording), now: now) == 30 * 60)
        #expect(MeetingTimeStats.seconds(of: meeting("失敗", start: date(24, 10), minutes: nil, status: .failed), now: now) == 0)
    }

    @Test("今日の会議は開始順、ほかの日は含めない")
    func today() {
        let now = date(24, 18)
        let meetings = [
            meeting("午後", start: date(24, 15), minutes: 30),
            meeting("午前", start: date(24, 9), minutes: 60),
            meeting("昨日", start: date(23, 9), minutes: 60),
        ]
        let day = MeetingTimeStats.day(now, meetings: meetings, now: now, calendar: calendar)
        #expect(day.entries.map(\.meeting.title) == ["午前", "午後"])
        #expect(day.total == 90 * 60)
    }

    @Test("週の 7 日分と前週の同じ経過時点までとの比較")
    func week() {
        let now = date(24, 12) // 水曜 12:00
        let meetings = [
            meeting("今週月", start: date(21, 10), minutes: 60),
            meeting("今週水", start: date(24, 9), minutes: 30),
            meeting("前週月", start: date(14, 10), minutes: 60),
            meeting("前週水朝", start: date(17, 9), minutes: 30),
            // 前週の水曜 12:00 より後は比較に含めない
            meeting("前週水夕", start: date(17, 16), minutes: 120),
        ]
        let week = MeetingTimeStats.week(containing: now, meetings: meetings, now: now, calendar: calendar)
        #expect(week.start == date(21, 0))
        #expect(week.days.count == 7)
        #expect(week.days.map { $0.entries.count } == [1, 0, 0, 1, 0, 0, 0])
        #expect(week.total == 90 * 60)
        #expect(week.previousTotal == 90 * 60)
        #expect(week.change == 0)
        // 過去の週は前週全体と比べる
        let last = MeetingTimeStats.week(containing: date(16, 12), meetings: meetings, now: now, calendar: calendar)
        #expect(last.total == 210 * 60)
        #expect(last.previousTotal == 0)
        #expect(last.change == nil)
    }

    @Test("発言時間: 話者の割当と発話単位の変更を反映し、多い順")
    func talkTimes() {
        let meetingId = "m1"
        let spk0 = SpeakerRecord(id: "s0", meetingId: meetingId, clusterLabel: "spk_0", displayName: "佐藤")
        let me = SpeakerRecord(id: "me", meetingId: meetingId, clusterLabel: TrackMerger.micSpeakerLabel)
        var moved = SegmentRecord(meetingId: meetingId, source: .final, tStart: 20, tEnd: 28, clusterLabel: "spk_0", text: "c")
        moved.speakerId = "me"
        let segments = [
            SegmentRecord(meetingId: meetingId, source: .final, tStart: 0, tEnd: 5, clusterLabel: TrackMerger.micSpeakerLabel, text: "a"),
            SegmentRecord(meetingId: meetingId, source: .final, tStart: 5, tEnd: 20, clusterLabel: "spk_0", text: "b"),
            moved,
            SegmentRecord(meetingId: meetingId, source: .final, tStart: 30, tEnd: 32, clusterLabel: "spk_1", text: "d"),
            // 同じ長さなら先に話した順
            SegmentRecord(meetingId: meetingId, source: .final, tStart: 32, tEnd: 34, clusterLabel: "spk_2", text: "e"),
        ]
        let times = MeetingDetailModel.talkTimes(segments: segments, speakers: [spk0, me])
        #expect(times.map(\.id) == ["s0", "me", "spk_1", "spk_2"])
        #expect(times.map(\.seconds) == [15, 13, 2, 2])
        #expect(times[2].speaker == nil && times[2].clusterLabel == "spk_1")
    }

    /// 会議を開くたびに詳細全体を描き直さないための前提（Observation は等しい値の代入を通知しない）。
    @Test("会議詳細: 同じ内容の読み直し（監視の初回値など）では画面に変更を通知せず、内容が変わったときだけ通知する")
    @MainActor
    func detailSkipsIdenticalReload() throws {
        let store = try Store.inMemory()
        let created = try store.createMeeting(meeting("詳細", start: Date(), minutes: 30))
        let saved = try store.replaceSegments(meetingId: created.id, source: .final, with: [
            SegmentRecord(meetingId: created.id, source: .final, tStart: 0, tEnd: 1, clusterLabel: "spk_0", text: "最初の本文"),
        ])
        let detail = MeetingDetailModel(store: store, pipeline: nil, meetingId: created.id, notesDraft: UserNotesDraft { _ in }, voicesDirectory: FileManager.default.temporaryDirectory)
        detail.reload()
        let flag = ChangeFlag()
        withObservationTracking { _ = detail.segments } onChange: { flag.changed.withLock { $0 = true } }
        detail.reload()
        #expect(flag.changed.withLock { $0 } == false)
        try store.updateSegmentText(id: try #require(saved.first?.id), text: "直した本文")
        detail.reload()
        #expect(flag.changed.withLock { $0 })
        #expect(detail.segments.first?.text == "直した本文")
    }

    @Test("テーマは JSON に往復し、未知の値やキーなしはシステムに戻す（ほかの設定は保つ）")
    func appearance() throws {
        var settings = AppSettings()
        settings.appearance = .dark
        let decoded = try JSONCoding.decoder().decode(AppSettings.self, from: JSONCoding.encoder().encode(settings))
        #expect(decoded.appearance == .dark)
        let unknown = try JSONCoding.decoder().decode(AppSettings.self, from: Data("{\"appearance\": \"sepia\", \"include_mic\": false}".utf8))
        #expect(unknown.appearance == .system)
        #expect(unknown.includeMic == false)
        #expect(try JSONCoding.decoder().decode(AppSettings.self, from: Data("{}".utf8)).appearance == .system)
    }

    @Test("since フィルタは指定時刻以降に開始した会議")
    func sinceFilter() throws {
        let store = try Store.inMemory()
        let now = Date()
        _ = try store.createMeeting(meeting("最近", start: now.addingTimeInterval(-3600), minutes: 30))
        _ = try store.createMeeting(meeting("先月", start: now.addingTimeInterval(-40 * 86_400), minutes: 30))
        #expect(try store.listMeetings(.since(now.addingTimeInterval(-7 * 86_400))).map(\.title) == ["最近"])
    }
}
