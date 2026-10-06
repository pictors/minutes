import Foundation
import MinutesCore
import Testing

@Suite("Store（GRDB / FTS）")
struct StoreTests {
    func makeMeeting(_ store: Store, title: String = "週次定例", startedAt: Date = Date(), status: MeetingStatus = .recording) throws -> MeetingRecord {
        try store.createMeeting(MeetingRecord(title: title, startedAt: startedAt, platform: .meet, attendees: [Attendee(name: "田中", email: "tanaka@example.com")], privacyMode: .cloudOk, status: status, audioDir: "/tmp/x"))
    }

    @Test("会議の作成・取得・状態更新・ISO 8601 日時")
    func meetings() throws {
        let store = try Store.inMemory()
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = try makeMeeting(store, startedAt: started)
        let fetched = try #require(try store.meeting(id: meeting.id))
        #expect(fetched.title == "週次定例")
        #expect(fetched.attendees == [Attendee(name: "田中", email: "tanaka@example.com")])
        #expect(fetched.meetingPlatform == .meet)
        #expect(abs(fetched.startedAt.timeIntervalSince(started)) < 1)
        try store.setMeetingStatus(id: meeting.id, status: .done, endedAt: started.addingTimeInterval(3600))
        let updated = try #require(try store.meeting(id: meeting.id))
        #expect(updated.meetingStatus == .done)
        #expect(updated.endedAt != nil)
        #expect(try store.listMeetings(.status(.done)).count == 1)
        #expect(try store.listMeetings(.unprocessed).isEmpty)
        #expect(ULID.timestamp(of: meeting.id).map { abs($0.timeIntervalSinceNow) < 5 } == true)
    }

    @Test("today / thisWeek フィルタ")
    func filters() throws {
        let store = try Store.inMemory()
        _ = try makeMeeting(store, title: "今日", startedAt: Date())
        _ = try makeMeeting(store, title: "先月", startedAt: Date().addingTimeInterval(-40 * 86_400))
        let stored = try store.writer.read { db in try String.fetchAll(db, sql: "SELECT started_at FROM meetings ORDER BY started_at") }
        #expect(stored.allSatisfy { $0.hasSuffix("Z") && $0.contains("T") }, "ISO 8601 で保存される: \(stored)")
        #expect(try store.listMeetings(.today).map(\.title) == ["今日"])
        #expect(try store.listMeetings(.thisWeek).map(\.title) == ["今日"])
        #expect(try store.listMeetings(.all).count == 2)
    }

    @Test("セグメントの追加は id が採番され、置き換えは冪等")
    func segments() throws {
        let store = try Store.inMemory()
        let meeting = try makeMeeting(store)
        let inserted = try store.appendSegments([
            SegmentRecord(meetingId: meeting.id, source: .live, tStart: 0, tEnd: 1, clusterLabel: "me", text: "おはようございます"),
            SegmentRecord(meetingId: meeting.id, source: .live, tStart: 1, tEnd: 2, text: "今日の議題は"),
        ])
        #expect(inserted.compactMap(\.id) == [1, 2])
        let finals = try store.replaceSegments(meetingId: meeting.id, source: .final, with: [
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 2, clusterLabel: "spk_0", text: "今日の議題はリリース日です"),
        ])
        #expect(finals.count == 1)
        #expect(finals[0].id != nil)
        _ = try store.replaceSegments(meetingId: meeting.id, source: .final, with: finals)
        #expect(try store.segments(meetingId: meeting.id, source: .final).count == 1)
        #expect(try store.segments(meetingId: meeting.id, source: .live).count == 2)
        let display = try store.displaySegments(meetingId: meeting.id)
        #expect(display.source == .final)
        try store.setMeetingStatus(id: meeting.id, status: .done)
        try store.deleteMeeting(id: meeting.id)
        #expect(try store.segments(meetingId: meeting.id, source: .live).isEmpty)
    }

    @Test("日本語の全文検索（trigram）と 2 文字以下の LIKE フォールバック、前後 1 件の snippet")
    func search() throws {
        let store = try Store.inMemory()
        let meeting = try makeMeeting(store)
        _ = try store.appendSegments([
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 1, clusterLabel: "spk_0", text: "おはようございます"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 1, tEnd: 2, clusterLabel: "spk_0", text: "新機能のリリース日について確認したいです"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 2, tEnd: 3, clusterLabel: "spk_1", text: "来週の金曜日でお願いします"),
        ])
        let results = try store.search("リリース日")
        #expect(results.count == 1)
        let hit = try #require(results.first?.segmentHits.first)
        #expect(hit.segment.text.contains("リリース日"))
        #expect(hit.context.map(\.text) == ["おはようございます", "新機能のリリース日について確認したいです", "来週の金曜日でお願いします"])
        #expect(try store.search("金曜").first?.segmentHits.first?.segment.text == "来週の金曜日でお願いします")
        #expect(try store.search("議題").isEmpty)
        #expect(try store.search("   ").isEmpty)
        // notes も検索対象
        try store.upsertNotes(NotesRecord(meetingId: meeting.id, summaryMd: "請求書の再発行を来月初めに行う"))
        let noteResults = try store.search("請求書")
        #expect(noteResults.count == 1)
        #expect(noteResults[0].notesMatched)
        #expect(noteResults[0].segmentHits.isEmpty)
    }

    @Test("話者の割当はクラスタ全体に反映され、置き換えても引き継がれる")
    func speakers() throws {
        let store = try Store.inMemory()
        let meeting = try makeMeeting(store)
        _ = try store.replaceSegments(meetingId: meeting.id, source: .final, with: [
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 1, clusterLabel: "spk_0", text: "a"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 1, tEnd: 2, clusterLabel: "spk_0", text: "b"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 2, tEnd: 3, clusterLabel: "me", text: "c"),
        ])
        try store.replaceSpeakers(meetingId: meeting.id, with: [
            SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_0"),
            SpeakerRecord(meetingId: meeting.id, clusterLabel: "me"),
        ])
        let person = try store.findOrCreatePerson(name: "田中", email: "Tanaka@example.com")
        #expect(try store.findOrCreatePerson(name: "田中", email: "tanaka@example.com").id == person.id)
        try store.assignSpeaker(meetingId: meeting.id, clusterLabel: "spk_0", personId: person.id, displayName: "田中")
        let speakers = try store.speakers(meetingId: meeting.id)
        let spk0 = try #require(speakers.first { $0.clusterLabel == "spk_0" })
        #expect(spk0.displayName == "田中")
        #expect(spk0.personId == person.id)
        let segments = try store.segments(meetingId: meeting.id, source: .final)
        #expect(segments.filter { $0.clusterLabel == "spk_0" }.allSatisfy { $0.speakerId == spk0.id })
        #expect(segments.first { $0.clusterLabel == "me" }?.speakerId != spk0.id)
        // 再度置き換えても割当が残る
        try store.replaceSpeakers(meetingId: meeting.id, with: [SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_0"), SpeakerRecord(meetingId: meeting.id, clusterLabel: "me")])
        #expect(try store.speakers(meetingId: meeting.id).first { $0.clusterLabel == "spk_0" }?.displayName == "田中")
        try store.addVoiceSample(personId: person.id, sample: VoiceSample(path: "/tmp/a.wav", duration: 6, meetingId: meeting.id))
        #expect(try store.person(id: person.id)?.voiceSamples.count == 1)
    }

    @Test("pipeline_runs / export_log / keyterms")
    func runsAndExports() throws {
        let store = try Store.inMemory()
        let meeting = try makeMeeting(store)
        let run = try store.recordRun(meetingId: meeting.id, step: "transcribe_final", status: .running)
        #expect(run.id != nil)
        try store.finishRun(run, status: .ok, provider: "elevenlabs.scribe_v2")
        let latest = try #require(try store.latestRun(meetingId: meeting.id, step: "transcribe_final"))
        #expect(latest.runStatus == .ok)
        #expect(latest.provider == "elevenlabs.scribe_v2")
        #expect(latest.finishedAt != nil)
        _ = try store.logExport(meetingId: meeting.id, target: "http_push", status: .pending)
        #expect(try store.pendingExports().count == 1)
        _ = try store.logExport(meetingId: meeting.id, target: "http_push", status: .ok, checksum: "abc")
        #expect(try store.pendingExports().isEmpty)
        #expect(try store.hasSuccessfulExport(meetingId: meeting.id))
        try store.addKeyterms(["Nimbus", " Nimbus ", "", "Minutes"], source: "learned")
        #expect(try store.keyterms() == ["Minutes", "Nimbus"])
    }

    @Test("ULID は 26 文字で時刻順に並ぶ")
    func ulid() {
        let a = ULID.generate(date: Date(timeIntervalSince1970: 1_700_000_000))
        let b = ULID.generate(date: Date(timeIntervalSince1970: 1_700_000_001))
        #expect(a.count == 26 && b.count == 26)
        #expect(a < b)
        #expect(ULID.timestamp(of: a).map { abs($0.timeIntervalSince1970 - 1_700_000_000) < 0.001 } == true)
    }
}
