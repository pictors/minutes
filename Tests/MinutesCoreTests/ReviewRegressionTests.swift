import AVFoundation
import Foundation
import GRDB
import Synchronization
import Testing
@testable import MinutesCore

private struct PipelineFixture {
    let root: URL
    let store: Store
    let meeting: MeetingRecord
    let audio: URL
    init(privacy: PrivacyMode = .cloudOk) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-regression-" + UUID().uuidString)
        audio = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.1, count: 16_000), sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.systemSTTName))
        store = try Store.inMemory()
        meeting = try store.createMeeting(MeetingRecord(title: "テスト会議", startedAt: Date(), privacyMode: privacy, status: .finalizing, audioDir: audio.path))
    }
    func pipeline(local: any BatchTranscriber = FakeTranscriber(id: "local", runsLocally: true, segments: [.init(start: 0, end: 1, text: "認識結果")]), summarizer: (any Summarizing)? = FakeSummarizer(), targets: [any SyncTarget] = []) -> PostProcessPipeline {
        PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: local, summarizer: summarizer, exportDirectory: root.appendingPathComponent("external-export"), syncTargets: targets))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class SwitchableTranscriber: BatchTranscriber, Sendable {
    let id = "switchable"
    let runsLocally = true
    let fail = Mutex(false)
    let calls = Mutex(0)
    let text = Mutex("最初の本文")
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        calls.withLock { $0 += 1 }
        if fail.withLock({ $0 }) { throw PipelineError.noAudio("injected failure") }
        return TranscriptionResult(segments: [.init(start: 0, end: 1, text: text.withLock { $0 }, speakerLabel: "speaker_0")], providerMeta: ["provider": id])
    }
}

private final class CountingSummary: Summarizing, Sendable {
    let calls = Mutex(0)
    let modelDescription: String
    init(_ model: String = "fixture / prompt v1") { modelDescription = model }
    func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
        calls.withLock { $0 += 1 }
        let first = try #require(input.segments.first)
        return MinutesSummary(summaryMd: first.text, decisions: [.init(text: first.text, evidence: [first.id])], actionItems: [.init(text: "やること", owner: "me", kind: .ownCommitment, due: nil, evidence: [first.id])], openQuestions: [], keytermsLearned: [])
    }
}

private final class CountingTarget: SyncTarget, Sendable {
    let id: String
    let calls: Mutex<Int>
    let fail: Bool
    let beforeUpload: (@Sendable () throws -> Void)?
    init(id: String = "external", fail: Bool = false, beforeUpload: (@Sendable () throws -> Void)? = nil) {
        self.id = id; self.calls = Mutex(0); self.fail = fail; self.beforeUpload = beforeUpload
    }
    func upload(folder: URL, manifest: ExportManifest) async throws -> SyncReceipt {
        calls.withLock { $0 += 1 }
        try beforeUpload?()
        if fail { throw PipelineError.noAudio("offline") }
        return SyncReceipt(targetId: id, location: folder.path, checksum: manifest.checksum, uploadedAt: Date())
    }
}

@Suite("レビュー6項目の回帰")
struct ReviewRegressionTests {
    @Test("音声保持期限後も DB の話者名・メモ・完了チェックだけで再書き出し・同期できる")
    func refreshExportAfterRetention() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let transcriber = SwitchableTranscriber()
        let summary = CountingSummary()
        let syncDirectory = f.root.appendingPathComponent("sync")
        let pipeline = f.pipeline(local: transcriber, summarizer: summary, targets: [LocalDirectorySyncTarget(destination: syncDirectory)])
        try await pipeline.run(meetingId: f.meeting.id)
        let calls = (transcriber.calls.withLock { $0 }, summary.calls.withLock { $0 })
        let segments = try f.store.segments(meetingId: f.meeting.id, source: .final)
        let speaker = try #require(try f.store.speakers(meetingId: f.meeting.id).first)
        try f.store.assignSpeaker(meetingId: f.meeting.id, clusterLabel: speaker.clusterLabel, personId: nil, displayName: "佐藤")
        let action = try #require(try f.store.notes(meetingId: f.meeting.id)?.actionItems.first)
        _ = try f.store.setActionCompletion(meetingId: f.meeting.id, action: action, done: true)
        try f.store.updateUserNotes(meetingId: f.meeting.id, markdown: "音声削除後のメモ")
        try FileManager.default.removeItem(at: f.audio)
        try f.store.clearAudioDirectory(id: f.meeting.id)

        let path = try #require(try await pipeline.refreshExport(meetingId: f.meeting.id))
        let directory = URL(fileURLWithPath: path)
        let markdown = try String(contentsOf: directory.appendingPathComponent("meeting.md"), encoding: .utf8)
        #expect(markdown.contains("佐藤: 最初の本文"))
        #expect(markdown.contains("音声削除後のメモ"))
        #expect(markdown.contains("- [x] やること"))
        #expect(try String(contentsOf: syncDirectory.appendingPathComponent(directory.lastPathComponent).appendingPathComponent("meeting.md"), encoding: .utf8) == markdown)
        _ = try ExportManifest.verify(directory: directory)
        #expect(transcriber.calls.withLock { $0 } == calls.0)
        #expect(summary.calls.withLock { $0 } == calls.1)
        #expect(try f.store.meeting(id: f.meeting.id)?.meetingStatus == .done)
        #expect(try f.store.meeting(id: f.meeting.id)?.audioDir == nil)
        #expect(try f.store.segments(meetingId: f.meeting.id, source: .final).map(\.id) == segments.map(\.id))
        #expect(try f.store.latestRun(meetingId: f.meeting.id, step: "export")?.runStatus == .ok)
    }

    @Test("再書き出し専用経路でも local_only はファイル・同期・API を実行しない")
    func refreshExportRespectsPrivacy() async throws {
        let f = try PipelineFixture(privacy: .localOnly); defer { f.cleanup() }
        try f.store.setMeetingStatus(id: f.meeting.id, status: .done)
        let target = CountingTarget()
        let transcriber = SwitchableTranscriber()
        let summary = CountingSummary()
        let pipeline = f.pipeline(local: transcriber, summarizer: summary, targets: [target])
        #expect(try await pipeline.refreshExport(meetingId: f.meeting.id) == nil)
        #expect(target.calls.withLock { $0 } == 0)
        #expect(summary.calls.withLock { $0 } == 0)
        #expect(transcriber.calls.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("external-export").path))
    }

    @Test("再書き出しは会議ロックと録音中ステータスを保護する")
    func refreshExportRespectsLease() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let pipeline = f.pipeline()
        await #expect(throws: StoreError.self) { try await pipeline.refreshExport(meetingId: f.meeting.id) }
        try f.store.setMeetingStatus(id: f.meeting.id, status: .done)
        let lease = try f.store.acquireMeetingLease(f.meeting.id)
        defer { withExtendedLifetime(lease) {} }
        await #expect(throws: StoreError.self) { try await pipeline.refreshExport(meetingId: f.meeting.id) }
        #expect(try f.store.runs(meetingId: f.meeting.id).isEmpty)
    }

    @Test("書き出し失敗を呼び出し元と履歴に返し、完了済みの会議データは維持")
    func refreshExportFailure() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        try f.store.setMeetingStatus(id: f.meeting.id, status: .done)
        let blockedDirectory = f.root.appendingPathComponent("blocked-export")
        try Data("既存ファイル".utf8).write(to: blockedDirectory)
        let pipeline = PostProcessPipeline(store: f.store, providers: PipelineProviders(cloud: nil, local: SwitchableTranscriber(), summarizer: nil, exportDirectory: blockedDirectory))
        await #expect(throws: (any Error).self) { try await pipeline.refreshExport(meetingId: f.meeting.id) }
        #expect(try f.store.latestRun(meetingId: f.meeting.id, step: "export")?.runStatus == .failed)
        #expect(try f.store.meeting(id: f.meeting.id)?.meetingStatus == .done)
        #expect(try Data(contentsOf: blockedDirectory) == Data("既存ファイル".utf8))
    }

    @Test("local_only は任意の書き出し先・同期先・pending 再送をすべて抑止")
    func localOnlyExports() async throws {
        let f = try PipelineFixture(privacy: .localOnly); defer { f.cleanup() }
        let target = CountingTarget()
        let summary = CountingSummary()
        let pipeline = f.pipeline(summarizer: summary, targets: [target])
        let result = try await pipeline.run(meetingId: f.meeting.id)
        #expect(result.exportPath == nil)
        #expect(target.calls.withLock { $0 } == 0)
        #expect(summary.calls.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("external-export").path))
        #expect(throws: PipelineError.self) { try pipeline.writeExportFolder(meetingId: f.meeting.id) }
        try f.store.logExport(meetingId: f.meeting.id, target: target.id, status: .pending)
        _ = await pipeline.retryPendingExports()
        #expect(target.calls.withLock { $0 } == 0)
        #expect(try !f.store.hasSuccessfulExport(meetingId: f.meeting.id))
    }

    @Test("cloud_ok の失敗分も local_only 変更後は再送しない")
    func retryChecksCurrentPrivacy() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let target = CountingTarget(fail: true)
        let pipeline = f.pipeline(targets: [target])
        try await pipeline.run(meetingId: f.meeting.id)
        #expect(target.calls.withLock { $0 } == 1)
        var meeting = try #require(try f.store.meeting(id: f.meeting.id))
        meeting.privacy = .localOnly
        try f.store.updateMeeting(meeting)
        _ = await pipeline.retryPendingExports()
        #expect(target.calls.withLock { $0 } == 1)
    }

    @Test("同期先ごとに最新 privacy を再確認")
    func privacyBetweenTargets() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let first = CountingTarget(id: "first", beforeUpload: {
            var m = try #require(try f.store.meeting(id: f.meeting.id)); m.privacy = .localOnly; try f.store.updateMeeting(m)
        })
        let second = CountingTarget(id: "second")
        try await f.pipeline(targets: [first, second]).run(meetingId: f.meeting.id)
        #expect(first.calls.withLock { $0 } == 1)
        #expect(second.calls.withLock { $0 } == 0)
    }

    @Test("強制上流処理が失敗しても下流の成功記録を再利用しない")
    func forceInvalidatesBeforeFailure() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let transcriber = SwitchableTranscriber()
        let pipeline = f.pipeline(local: transcriber, summarizer: CountingSummary())
        try await pipeline.run(meetingId: f.meeting.id)
        transcriber.fail.withLock { $0 = true }
        await #expect(throws: PipelineError.self) { try await pipeline.run(meetingId: f.meeting.id, force: [.transcribeFinal]) }
        for step in [PipelineStep.mergeTracks, .summarize, .store, .export] {
            #expect(try f.store.latestRun(meetingId: f.meeting.id, step: step.rawValue)?.runStatus == .invalidated)
        }
        transcriber.fail.withLock { $0 = false }
        transcriber.text.withLock { $0 = "更新した本文" }
        let retried = try await pipeline.run(meetingId: f.meeting.id)
        #expect(retried.executed == Array(PipelineStep.allCases.dropFirst()))
        #expect(try f.store.notes(meetingId: f.meeting.id)?.summaryMd == "更新した本文")
        let content = try String(contentsOfFile: #require(retried.exportPath) + "/meeting.md", encoding: .utf8)
        #expect(content.contains("更新した本文"))
        #expect(try await pipeline.run(meetingId: f.meeting.id).executed == [.notify])
    }

    @Test("音声・プロバイダ・プロンプト設定の変更を検知")
    func changedInputs() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        try await f.pipeline().run(meetingId: f.meeting.id)
        let changedProvider = FakeTranscriber(id: "new-model", runsLocally: true, segments: [.init(start: 0, end: 1, text: "別モデルの本文")])
        let summary = CountingSummary("new summary / prompt v2")
        let pipeline = f.pipeline(local: changedProvider, summarizer: summary)
        let changed = try await pipeline.run(meetingId: f.meeting.id)
        #expect(changed.executed.first == .transcribeFinal)
        let next = f.pipeline(local: changedProvider, summarizer: CountingSummary("new summary / prompt v3"))
        #expect(try await next.run(meetingId: f.meeting.id).executed.first == .summarize)
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.2, count: 32_000), sampleRate: 16_000, to: f.audio.appendingPathComponent(RecordingSession.systemSTTName))
        #expect(try await next.run(meetingId: f.meeting.id).executed.first == .finalizeAudio)
    }

    @Test("store/全STT再処理でも編集・ID・メモ・チェックと生成元を保持")
    func editedTranscriptSurvives() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let originalSummary = CountingSummary("original / prompt v1")
        let pipeline = f.pipeline(summarizer: originalSummary)
        try await pipeline.run(meetingId: f.meeting.id)
        let segment = try #require(try f.store.segments(meetingId: f.meeting.id, source: .final).first)
        let id = try #require(segment.id)
        // 別会議の挿入で SQLite の ID がずれる条件
        let other = try f.store.createMeeting(MeetingRecord(title: "別会議", startedAt: Date(), privacyMode: .localOnly, status: .done))
        try f.store.appendSegments([.init(meetingId: other.id, source: .final, tStart: 0, tEnd: 1, text: "別")])
        try f.store.updateSegmentText(id: id, text: "人が編集した本文")
        var notes = try #require(try f.store.notes(meetingId: f.meeting.id))
        var actions = notes.actionItems; actions[0].done = true
        notes.actionItemsJson = String(decoding: try JSONCoding.encoder().encode(actions), as: UTF8.self)
        notes.userNotesMd = "手書きメモ"
        try f.store.upsertNotes(notes)
        try await pipeline.run(meetingId: f.meeting.id, force: [.store])
        #expect(try f.store.segments(meetingId: f.meeting.id, source: .final).first?.id == id)
        #expect(try f.store.notes(meetingId: f.meeting.id)?.summaryMd == "人が編集した本文")
        let split = FakeTranscriber(id: "split", runsLocally: true, segments: [.init(start: 0, end: 0.4, text: "分割A"), .init(start: 0.4, end: 1, text: "分割B")])
        try await f.pipeline(local: split, summarizer: originalSummary).run(meetingId: f.meeting.id, force: [.transcribeFinal])
        let current = try f.store.segments(meetingId: f.meeting.id, source: .final)
        #expect(current.count == 1)
        #expect(current.first?.id == id)
        #expect(current.first?.text == "人が編集した本文")
        #expect(current.first?.originalText == "認識結果")
        let updated = try #require(try f.store.notes(meetingId: f.meeting.id))
        #expect(updated.userNotesMd == "手書きメモ")
        #expect(updated.actionItems.first?.done == true)
        #expect(updated.decisions.first?.evidence == [Int(id)])
        #expect(updated.model == "original / prompt v1")
        #expect(try await f.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_revisions WHERE meeting_id = ?", arguments: [f.meeting.id]) } == 2)
        // 設定が違っていても store 自体は成果物が持つ生成元を使う。
        _ = try f.pipeline(summarizer: CountingSummary("different")).storeResults(meeting: f.meeting, directory: f.audio)
        #expect(try f.store.notes(meetingId: f.meeting.id)?.model == "original / prompt v1")
    }

    @Test("編集のない認識結果が分割されても旧 deep link は元の発話を参照")
    func retiredSegmentLinks() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        try await f.pipeline().run(meetingId: f.meeting.id)
        let old = try #require(try f.store.segments(meetingId: f.meeting.id, source: .final).first)
        let split = FakeTranscriber(id: "split", runsLocally: true, segments: [.init(start: 0, end: 0.4, text: "分割A"), .init(start: 0.4, end: 1, text: "分割B")])
        try await f.pipeline(local: split).run(meetingId: f.meeting.id)
        let oldId = try #require(old.id)
        let oldRow = try #require(try f.store.segment(id: oldId, meetingId: f.meeting.id))
        #expect(!oldRow.isCurrent)
        #expect(oldRow.text == old.text)
        #expect(try f.store.segments(meetingId: f.meeting.id, source: .final).count == 2)
        #expect(try f.store.search("認識結果").flatMap(\.segmentHits).isEmpty)
    }

    @Test("中断だけを復旧し、別プロセス相当のロック所有者は保護")
    func recoveryAndOwnership() throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let url = f.root.appendingPathComponent("test.sqlite")
        let store = try Store.open(at: url)
        let recording = try store.createMeeting(MeetingRecord(title: "中断", startedAt: Date(), privacyMode: .localOnly, status: .recording, audioDir: f.audio.path))
        let active = try store.createMeeting(MeetingRecord(title: "稼働中", startedAt: Date(), privacyMode: .cloudOk, status: .finalizing))
        let lease = try store.acquireMeetingLease(active.id)
        try store.recordRun(meetingId: recording.id, step: "transcribe_final", status: .running)
        try store.recordRun(meetingId: active.id, step: "summarize", status: .running)
        try withExtendedLifetime(lease) {
            let reopened = try Store.open(at: url)
            #expect(try reopened.meeting(id: recording.id)?.meetingStatus == .failed)
            #expect(try reopened.latestRun(meetingId: recording.id, step: "transcribe_final")?.runStatus == .failed)
            #expect(try reopened.meeting(id: active.id)?.meetingStatus == .finalizing)
            #expect(try reopened.latestRun(meetingId: active.id, step: "summarize")?.runStatus == .running)
            #expect(throws: StoreError.self) { try reopened.acquireMeetingLease(active.id) }
        }
        #expect(FileManager.default.fileExists(atPath: f.audio.appendingPathComponent(RecordingSession.systemSTTName).path))
    }

    @Test("破損/空/欠落トラックは finalize で検出、AAC があれば WAV を復元")
    func validateAudio() throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let pipeline = f.pipeline()
        let wav = f.audio.appendingPathComponent(RecordingSession.systemSTTName)
        try Data().write(to: wav)
        #expect(throws: PipelineError.self) { try pipeline.finalizeAudio(meeting: f.meeting, directory: f.audio) }
        try AudioFileTools.writeAAC(samples: Array(repeating: 0.2, count: 16_000), sampleRate: 16_000, to: f.audio.appendingPathComponent(RecordingSession.systemArchiveName), bitrate: 32_000)
        _ = try pipeline.finalizeAudio(meeting: f.meeting, directory: f.audio)
        #expect(try AudioFileTools.duration(of: wav) > 0.9)
        try JSONCoding.encoder().encode(["system", "mic"]).write(to: f.audio.appendingPathComponent("expected-tracks.json"))
        #expect(throws: PipelineError.self) { try pipeline.finalizeAudio(meeting: f.meeting, directory: f.audio) }
    }

    @Test("所有プロセスの強制終了でロックを解放し再起動後に復旧")
    func killedOwnerRecovery() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let url = f.root.appendingPathComponent("crash.sqlite")
        let store = try Store.open(at: url)
        let meeting = try store.createMeeting(MeetingRecord(title: "crash", startedAt: Date(), privacyMode: .localOnly, status: .recording, audioDir: f.audio.path))
        let lockDir = url.appendingPathExtension("locks")
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        let lock = lockDir.appendingPathComponent(PipelineFingerprint.hash(Data(meeting.id.utf8)) + ".lock")
        let marker = f.root.appendingPathComponent("owner-ready")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,pathlib; f=open(sys.argv[1], 'w'); fcntl.flock(f, fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).touch(); sys.stdin.read()", lock.path, marker.path]
        let input = Pipe()
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate() }; try? input.fileHandleForWriting.close() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try store.recoverInterruptedMeetings().isEmpty)
        child.terminate()
        child.waitUntilExit()
        let reopened = try Store.open(at: url)
        #expect(try reopened.meeting(id: meeting.id)?.meetingStatus == .failed)
        #expect(try reopened.latestRun(meetingId: meeting.id, step: "recovery")?.runStatus == .failed)
    }

    @Test("v1 DB の既存 ID・編集を保護し、中断会議を復旧")
    func legacyMigration() throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let url = f.root.appendingPathComponent("legacy.sqlite")
        let db = try DatabaseQueue(path: url.path)
        try StoreSchema.migrator().migrate(db, upTo: "v1_initial")
        let old = MeetingRecord(title: "旧DB", startedAt: Date(), privacyMode: .localOnly, status: .recording, audioDir: f.audio.path)
        try db.write { database in
            // v1 の列だけで挿入する（現行レコードには後の版で追加した列がある）
            try database.execute(sql: "INSERT INTO meetings(id, title, started_at, privacy_mode, status, audio_dir, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                 arguments: [old.id, old.title, Store.isoString(old.startedAt), old.privacyMode, old.status, old.audioDir, Store.isoString(old.createdAt), Store.isoString(old.updatedAt)])
            try database.execute(sql: "INSERT INTO segments(id, meeting_id, source, t_start, t_end, text) VALUES (41, ?, 'final', 0, 1, '旧版で編集した本文')", arguments: [old.id])
            try database.execute(sql: "INSERT INTO pipeline_runs(meeting_id, step, status) VALUES (?, 'store', 'running')", arguments: [old.id])
        }
        let store = try Store.open(at: url)
        #expect(try store.meeting(id: old.id)?.meetingStatus == .failed)
        #expect(try store.latestRun(meetingId: old.id, step: "store")?.runStatus == .failed)
        let current = try store.replaceSegments(meetingId: old.id, source: .final, with: [.init(meetingId: old.id, source: .final, tStart: 0, tEnd: 1, text: "再認識本文")])
        #expect(current.first?.id == 41)
        #expect(current.first?.text == "旧版で編集した本文")
    }

    @Test("要約失敗後も確定文字起こしを保持し、成功済みSTTから再開")
    func resumeAfterSummaryFailure() async throws {
        struct FailingSummary: Summarizing {
            let modelDescription = "failing"
            func summarize(_ input: SummaryInput) async throws -> MinutesSummary { throw PipelineError.summaryUnavailable }
        }
        let f = try PipelineFixture(); defer { f.cleanup() }
        let transcriber = SwitchableTranscriber()
        // 要約の失敗は警告として残し、本文が保存済みの会議は done にする（書き出しも要約なしで進む）。
        let first = try await f.pipeline(local: transcriber, summarizer: FailingSummary()).run(meetingId: f.meeting.id)
        #expect(first.warnings[.summarize] != nil)
        #expect(first.executed.contains(.export))
        #expect(try f.store.meeting(id: f.meeting.id)?.meetingStatus == .done)
        #expect(try f.store.latestRun(meetingId: f.meeting.id, step: "summarize")?.runStatus == .failed)
        #expect(try f.store.notes(meetingId: f.meeting.id)?.summaryMd == nil)
        #expect(try f.store.segments(meetingId: f.meeting.id, source: .final).count == 1)
        let pipeline = f.pipeline(local: transcriber, summarizer: FakeSummarizer())
        let outcome = try await pipeline.run(meetingId: f.meeting.id)
        #expect(outcome.executed.first == .summarize)
        #expect(outcome.warnings.isEmpty)
        #expect(transcriber.calls.withLock { $0 } == 1)
        #expect(try f.store.notes(meetingId: f.meeting.id)?.summaryMd != nil)
    }

    @Test("要約生成中の編集を検出して古い要約を保存しない")
    func rejectSummaryAfterConcurrentEdit() async throws {
        struct EditingSummary: Summarizing {
            let modelDescription = "fixture"
            let store: Store
            func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
                try store.updateSegmentText(id: Int64(input.segments[0].id), text: "生成中に編集")
                return try await FakeSummarizer().summarize(input)
            }
        }
        let f = try PipelineFixture(); defer { f.cleanup() }
        let pipeline = f.pipeline(summarizer: EditingSummary(store: f.store))
        let outcome = try await pipeline.run(meetingId: f.meeting.id)
        #expect(outcome.warnings[.summarize]?.contains("本文が変更") == true)
        #expect(try f.store.notes(meetingId: f.meeting.id) == nil)
        #expect(try f.store.segments(meetingId: f.meeting.id, source: .final).first?.text == "生成中に編集")
    }

    @Test("同期先設定の変更も書き出しを無効化")
    func changedSyncDirectory() async throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        try await f.pipeline(targets: [LocalDirectorySyncTarget(destination: f.root.appendingPathComponent("first"))]).run(meetingId: f.meeting.id)
        let pipeline = f.pipeline(targets: [LocalDirectorySyncTarget(destination: f.root.appendingPathComponent("second"))])
        #expect(try await pipeline.run(meetingId: f.meeting.id).executed == [.export, .notify])
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("second").path))
    }

    @Test("close 前の WAV ヘッダを復旧し、元の音声ファイルを保持")
    func interruptedWAV() throws {
        let f = try PipelineFixture(); defer { f.cleanup() }
        let wav = f.audio.appendingPathComponent(RecordingSession.systemSTTName)
        var data = try Data(contentsOf: wav)
        data.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        data.replaceSubrange(40..<44, with: [0, 0, 0, 0])
        try data.write(to: wav)
        #expect(try InterruptedWAVRecovery.repair(wav))
        #expect(try AudioFileTools.duration(of: wav) > 0.9)
        #expect(try Data(contentsOf: wav.appendingPathExtension("interrupted")) == data)
        #expect(try !InterruptedWAVRecovery.repair(wav))
    }

    @Test("時計を進めるだけで起動済みブラウザを arm し、停止/再起動後に重複しない")
    func scheduledArm() throws {
        let store = try Store.inMemory()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Mutex(instant)
        let scheduler = AutoRecordingScheduler(store: store, now: { clock.withLock { $0 } })
        let start = instant.addingTimeInterval(600)
        let end = start.addingTimeInterval(3600)
        #expect(try !scheduler.claim(eventId: "event", start: start, end: end, enabled: true, appRunning: true, idle: true))
        clock.withLock { $0 = start.addingTimeInterval(-300) }
        #expect(try !scheduler.claim(eventId: "event", start: start, end: end, enabled: true, appRunning: true, idle: false))
        #expect(try scheduler.claim(eventId: "event", start: start, end: end, enabled: true, appRunning: true, idle: true))
        let afterRestart = AutoRecordingScheduler(store: store, now: { start })
        #expect(try !afterRestart.claim(eventId: "event", start: start, end: end, enabled: true, appRunning: true, idle: true))
        let tomorrow = start.addingTimeInterval(86_400)
        clock.withLock { $0 = tomorrow }
        #expect(try scheduler.claim(eventId: "event", start: tomorrow, end: tomorrow.addingTimeInterval(3600), enabled: true, appRunning: true, idle: true))
    }
}
