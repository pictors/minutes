import Foundation
import GRDB
import Testing
@testable import MinutesCore

private struct DeletionFixture {
    let root: URL
    let store: Store
    let meeting: MeetingRecord
    let audio: URL

    init(status: MeetingStatus = .done) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-deletion-" + UUID().uuidString)
        audio = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: audio.appendingPathComponent("test.wav"))
        store = try Store.open(at: root.appendingPathComponent("test.sqlite"))
        meeting = try store.createMeeting(MeetingRecord(title: "削除テスト", startedAt: Date(), privacyMode: .localOnly, status: status, audioDir: audio.path))
        try store.upsertNotes(NotesRecord(meetingId: meeting.id, userNotesMd: "残すべきメモ"))
    }

    var pendingCount: Int {
        get throws { try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_audio_deletions") ?? 0 } }
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("会議削除の排他と復旧")
struct MeetingDeletionTests {
    @Test("実行中の別 Store のロックがあれば、完了済み会議でも DB と音声を残す")
    func heldLease() throws {
        let f = try DeletionFixture(); defer { f.cleanup() }
        let other = try Store.open(at: f.root.appendingPathComponent("test.sqlite"))
        let lease = try other.acquireMeetingLease(f.meeting.id)
        try withExtendedLifetime(lease) { () throws -> Void in
            #expect(throws: StoreError.self) { try f.store.deleteMeeting(id: f.meeting.id) }
            #expect(try f.store.meeting(id: f.meeting.id) != nil)
            #expect(try f.store.notes(meetingId: f.meeting.id)?.userNotesMd == "残すべきメモ")
            #expect(FileManager.default.fileExists(atPath: f.audio.path))
            #expect(try f.pendingCount == 0)
        }
    }

    @Test("ロック所有者がなくても recording / finalizing の削除を拒否", arguments: [MeetingStatus.recording, .finalizing])
    func activeStatus(status: MeetingStatus) throws {
        let f = try DeletionFixture(status: status); defer { f.cleanup() }
        #expect(throws: StoreError.self) { try f.store.deleteMeeting(id: f.meeting.id) }
        #expect(try f.store.meeting(id: f.meeting.id)?.meetingStatus == status)
        #expect(FileManager.default.fileExists(atPath: f.audio.path))
        #expect(try f.pendingCount == 0)
    }

    @Test("DB 削除失敗では会議・関連データ・音声をすべて維持する")
    func databaseFailure() throws {
        let f = try DeletionFixture(); defer { f.cleanup() }
        try f.store.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_delete BEFORE DELETE ON meetings BEGIN SELECT RAISE(ABORT, 'fixture refusal'); END")
        }
        #expect(throws: DatabaseError.self) { try f.store.deleteMeeting(id: f.meeting.id) }
        #expect(try f.store.meeting(id: f.meeting.id) != nil)
        #expect(try f.store.notes(meetingId: f.meeting.id)?.userNotesMd == "残すべきメモ")
        #expect(try Data(contentsOf: f.audio.appendingPathComponent("test.wav")) == Data("synthetic audio".utf8))
        #expect(try f.pendingCount == 0)
    }

    @Test("音声削除失敗は DB に残り、再起動後に残ったファイルだけ清掃できる")
    func retryAfterFileFailure() throws {
        let f = try DeletionFixture(); defer { f.cleanup() }
        do {
            let lease = try f.store.acquireMeetingLease(f.meeting.id)
            #expect(throws: StoreError.self) {
                try f.store.performMeetingDeletion(id: f.meeting.id, lease: lease) { _ in throw CocoaError(.fileWriteNoPermission) }
            }
            #expect(try f.store.meeting(id: f.meeting.id) == nil)
            #expect(try f.store.notes(meetingId: f.meeting.id) == nil)
            #expect(FileManager.default.fileExists(atPath: f.audio.path))
            #expect(try f.pendingCount == 1)
        }
        let reopened = try Store.open(at: f.root.appendingPathComponent("test.sqlite"))
        #expect(try reopened.retryPendingAudioDeletions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.audio.path))
        #expect(try f.pendingCount == 0)
        #expect(try reopened.retryPendingAudioDeletions().isEmpty)
    }

    @Test("削除成功時は音声・FTS・関連データと清掃記録を残さない")
    func completeDeletion() throws {
        let f = try DeletionFixture(); defer { f.cleanup() }
        _ = try f.store.appendSegments([.init(meetingId: f.meeting.id, source: .final, tStart: 0, tEnd: 1, text: "検索に残さない")])
        _ = try f.store.recordRun(meetingId: f.meeting.id, step: "export", status: .ok)
        _ = try f.store.logExport(meetingId: f.meeting.id, target: "fixture", status: .ok)
        try f.store.deleteMeeting(id: f.meeting.id)
        #expect(try f.store.meeting(id: f.meeting.id) == nil)
        #expect(try f.store.segments(meetingId: f.meeting.id, source: .final).isEmpty)
        #expect(try f.store.search("検索に残さない").isEmpty)
        #expect(try f.store.search("残すべきメモ").isEmpty)
        #expect(try f.store.runs(meetingId: f.meeting.id).isEmpty)
        #expect(try f.store.exportLog(meetingId: f.meeting.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.audio.path))
        #expect(try f.pendingCount == 0)
    }
}

@Suite("未保存メモの保持")
@MainActor
struct UserNotesDraftTests {
    @Test("要約・話者変更による再取得でも保存待ちの編集を維持して保存する")
    func pendingReload() throws {
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "メモ", startedAt: Date(), privacyMode: .localOnly, status: .done))
        try store.updateUserNotes(meetingId: meeting.id, markdown: "元のメモ")
        let draft = UserNotesDraft(delay: .seconds(60)) { try store.updateUserNotes(meetingId: meeting.id, markdown: $0) }
        draft.receivePersisted("元のメモ")
        draft.edit("入力した新しいメモ")
        draft.receivePersisted(try store.notes(meetingId: meeting.id)?.userNotesMd ?? "")
        #expect(draft.text == "入力した新しいメモ")
        #expect(draft.isDirty)
        // 画面離脱時の flush も同じ下書きを保存する。
        draft.flush()
        #expect(try store.notes(meetingId: meeting.id)?.userNotesMd == "入力した新しいメモ")
        #expect(!draft.isDirty)
        #expect(draft.saveError == nil)
    }

    @Test("保存に失敗しても再取得で編集を失わず、同じ内容を再試行できる")
    func retryFailedSave() {
        var fail = true
        var saved: String?
        let draft = UserNotesDraft(delay: .seconds(60)) { text in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            saved = text
        }
        draft.edit("保存待ち")
        draft.flush()
        #expect(draft.saveError != nil)
        #expect(draft.isDirty)
        draft.receivePersisted("古い DB の値")
        #expect(draft.text == "保存待ち")
        fail = false
        draft.flush()
        #expect(saved == "保存待ち")
        #expect(!draft.isDirty)
        #expect(draft.saveError == nil)
    }

    @Test("連続入力は最後の編集だけを自動保存し、取得した値は保存し直さない")
    func debounce() async throws {
        var saved: [String] = []
        let draft = UserNotesDraft(delay: .milliseconds(20)) { saved.append($0) }
        draft.receivePersisted("取得した値")
        draft.edit("途")
        draft.edit("途中")
        draft.edit("最後の編集")
        for _ in 0..<100 {
            if !draft.isDirty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(saved == ["最後の編集"])
        #expect(!draft.isDirty)
    }

    @Test("アクションのチェック操作は並行して保存されたメモと要約を上書きしない")
    func actionCompletionPreservesFreshNotes() throws {
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "アクション", startedAt: Date(), privacyMode: .localOnly, status: .done))
        let action = MinutesSummary.ActionItem(text: "確認", owner: "me", kind: .ownCommitment, due: nil, evidence: [], done: false)
        var summary = MinutesSummary(summaryMd: "古い要約", decisions: [], actionItems: [action], openQuestions: [], keytermsLearned: [])
        try store.upsertNotes(NotesRecord(meetingId: meeting.id, summary: summary, model: "old", userNotesMd: "古いメモ"))
        summary.summaryMd = "更新された要約"
        try store.upsertNotes(NotesRecord(meetingId: meeting.id, summary: summary, model: "new", userNotesMd: "入力を保存したメモ"))
        let notes = try store.setActionCompletion(meetingId: meeting.id, action: action, done: true)
        #expect(notes.userNotesMd == "入力を保存したメモ")
        #expect(notes.summaryMd == "更新された要約")
        #expect(notes.model == "new")
        #expect(notes.actionItems.first?.done == true)
        #expect(try store.search("入力を保存したメモ").first?.notesMatched == true)
    }
}
