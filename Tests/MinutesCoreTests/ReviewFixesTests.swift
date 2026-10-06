import Foundation
import Synchronization
import Testing
@testable import MinutesCore

/// 2026-09-23 のレビュー修正の回帰テスト（armed 区間の除外、検索、アクション ID、発話単位の話者、保持、セッション）。
private final class CapturingTranscriber: BatchTranscriber, Sendable {
    let id = "capturing"
    let runsLocally = true
    /// 受け取った音声ファイル名 → 長さ（秒）。
    let durations = Mutex<[String: Double]>([:])

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let duration = try AudioFileTools.duration(of: request.audioURL)
        durations.withLock { $0[request.audioURL.lastPathComponent] = duration }
        let label: String? = request.diarize ? "speaker_0" : nil
        return TranscriptionResult(segments: [.init(start: 0, end: 1, text: "冒頭の発話", speakerLabel: label)], providerMeta: ["provider": id])
    }
}

/// 音声を検知した状態を返す録音の代役。
private final class ArmedFakeRecording: MeetingRecording, @unchecked Sendable {
    let options: RecordingOptions
    private(set) var startedAt: Date?
    let tappedProcesses: [AudioProcessInfo] = []
    let systemChunks: AsyncStream<AudioChunk>? = nil
    let micChunks: AsyncStream<AudioChunk>? = nil
    var onEvent: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (CaptureFailure) -> Void)?
    let active = Mutex(false)
    /// 録音の原点をこの秒数だけ過去にする（録音準備が長く続いた状態）。
    let startedSecondsAgo: TimeInterval

    init(options: RecordingOptions, startedSecondsAgo: TimeInterval = 0) {
        self.options = options
        self.startedSecondsAgo = startedSecondsAgo
    }

    func start() async throws {
        startedAt = Date().addingTimeInterval(-startedSecondsAgo)
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.1, count: 16_000), sampleRate: 16_000, to: options.outputDirectory.appendingPathComponent(RecordingSession.systemSTTName))
    }

    func finishRecording() throws {}

    func snapshot() -> RecordingSession.Snapshot {
        let level: Float = active.withLock { $0 } ? -20 : -120
        let stats = TrackStatsSnapshot(name: "system", sourceSampleRate: 48_000, sourceChannels: 2, archiveSampleRate: 48_000, receivedFrames: 0, receivedSeconds: 0, writtenSeconds: 0, firstChunkOffsetSeconds: nil, gapCount: 0, gapSeconds: 0, overlapCount: 0, overlapSeconds: 0, formatChanges: 0, lastRmsDb: level, intervalPeakRmsDb: level, activeSeconds: 0, lastChunkTimelineEnd: nil)
        return .init(elapsedSeconds: 1, system: stats, mic: nil, cpuPercent: 0, residentBytes: 0, tappedProcessCount: 0)
    }
}

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-fixes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func tone(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { 0.2 * Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
}

@Suite("レビュー修正（2026-09-23）")
struct ReviewFixesTests {
    @Test("録音準備中の区間を mic の文字起こしから除外し、時刻は録音原点のまま保つ")
    func micTrimmedByMeetingStart() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: tone(seconds: 12), sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.systemSTTName))
        try AudioFileTools.writeWAV(samples: tone(seconds: 12), sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.micSTTName))
        let store = try Store.inMemory()
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        // 録音（arm）の 10 秒後に会議が始まった
        let meeting = try store.createMeeting(MeetingRecord(title: "予定", startedAt: origin.addingTimeInterval(10), privacyMode: .localOnly, status: .finalizing, audioDir: audio.path, recordingStartedAt: origin))
        #expect(meeting.meetingStartOffsetSeconds == 10)
        let transcriber = CapturingTranscriber()
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: transcriber, summarizer: nil, exportDirectory: root.appendingPathComponent("export")))
        _ = try await pipeline.run(meetingId: meeting.id)
        let durations = transcriber.durations.withLock { $0 }
        #expect(abs((durations[RecordingSession.systemSTTName] ?? 0) - 12) < 0.05)
        #expect(abs((durations[RecordingSession.micSTTName] ?? 0) - 2) < 0.05)
        let finals = try store.segments(meetingId: meeting.id, source: .final)
        let mic = try #require(finals.first { $0.clusterLabel == TrackMerger.micSpeakerLabel })
        #expect(abs(mic.tStart - 10) < 0.001)
        #expect(abs(mic.tEnd - 11) < 0.001)
        let system = try #require(finals.first { $0.clusterLabel == "spk_0" })
        #expect(system.tStart == 0)
        // 一時ファイルは残らない
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("minutes-trim-") } ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("会議の開始時刻は録音原点より前に戻せず、原点は保持される")
    func meetingStartedAt() throws {
        let store = try Store.inMemory()
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = try store.createMeeting(MeetingRecord(title: "t", startedAt: origin, privacyMode: .cloudOk, status: .recording, recordingStartedAt: origin))
        try store.setMeetingStarted(id: meeting.id, at: origin.addingTimeInterval(-5))
        #expect(try store.meeting(id: meeting.id)?.startedAt == origin)
        try store.setMeetingStarted(id: meeting.id, at: origin.addingTimeInterval(42))
        let updated = try #require(try store.meeting(id: meeting.id))
        #expect(updated.recordingStartedAt == origin)
        #expect(abs(updated.meetingStartOffsetSeconds - 42) < 1)
        // 旧行（原点なし）は最初の呼び出しで原点を埋める
        let legacy = try store.createMeeting(MeetingRecord(title: "old", startedAt: origin, privacyMode: .cloudOk, status: .recording))
        try store.setMeetingStarted(id: legacy.id, at: origin.addingTimeInterval(7))
        #expect(try store.meeting(id: legacy.id)?.recordingStartedAt == origin)
    }

    @Test("armed から今すぐ開始するとカレンダー情報を保ち、確認待ちの設定では音声検知で止まる")
    func startNowAndConfirmation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.open(at: root.appendingPathComponent("db.sqlite"))
        let recordings = Mutex<[ArmedFakeRecording]>([])
        var configuration = SessionConfiguration(targetBundleIdentifiers: [], audioRootDirectory: root)
        configuration.liveTranscription = false
        configuration.includeMic = false
        configuration.monitorInterval = 0.05
        configuration.confirmBeforeAutoStart = true
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: CapturingTranscriber(), summarizer: nil, exportDirectory: root.appendingPathComponent("export")))
        let controller = MeetingSessionController(store: store, pipeline: pipeline, configuration: configuration, makeRecording: { options in
            let recording = ArmedFakeRecording(options: options)
            recordings.withLock { $0.append(recording) }
            return recording
        })
        let confirmations = Mutex(0)
        let events = Mutex<[String]>([])
        await controller.setHandlers(state: nil, live: nil, event: { message in events.withLock { $0.append(message) } })
        await controller.setConfirmationHandler { _ in confirmations.withLock { $0 += 1 } }
        try await controller.arm(.init(title: "週次定例", attendees: [Attendee(name: "田中")], privacyMode: .localOnly))
        #expect(await controller.state == .armed)
        // 音声を検知しても確認待ちのまま recording に入らない
        recordings.withLock { $0[0].active.withLock { $0 = true } }
        for _ in 0..<100 {
            if await controller.snapshot().awaitingStartConfirmation { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await controller.state == .armed)
        #expect(await controller.snapshot().awaitingStartConfirmation, "events: \(events.withLock { $0 })")
        #expect(confirmations.withLock { $0 } == 1)
        try await controller.startNow()
        #expect(await controller.state == .recording)
        let meeting = try #require(await controller.currentMeeting)
        #expect(meeting.title == "週次定例")
        #expect(meeting.attendees.map(\.name) == ["田中"])
        #expect(meeting.recordingStartedAt != nil)
        #expect(meeting.startedAt >= (meeting.recordingStartedAt ?? .distantFuture))
        #expect(!(await controller.snapshot().awaitingStartConfirmation))
        await controller.stop()
    }

    @Test("録音準備中の経過時間は 0 で、音声を検知してからは会議の開始から数える")
    func elapsedCountsFromMeetingStart() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.open(at: root.appendingPathComponent("db.sqlite"))
        let recordings = Mutex<[ArmedFakeRecording]>([])
        var configuration = SessionConfiguration(targetBundleIdentifiers: [], audioRootDirectory: root)
        configuration.liveTranscription = false
        configuration.includeMic = false
        configuration.monitorInterval = 0.05
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: CapturingTranscriber(), summarizer: nil, exportDirectory: root.appendingPathComponent("export")))
        let controller = MeetingSessionController(store: store, pipeline: pipeline, configuration: configuration, makeRecording: { options in
            // 録音準備が 10 分続いている
            let recording = ArmedFakeRecording(options: options, startedSecondsAgo: 600)
            recordings.withLock { $0.append(recording) }
            return recording
        })
        try await controller.arm(.init(title: "週次定例", privacyMode: .localOnly))
        #expect(await controller.state == .armed)
        #expect(await controller.snapshot().elapsedSeconds == 0)
        recordings.withLock { $0[0].active.withLock { $0 = true } }
        for _ in 0..<100 {
            if await controller.state == .recording { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await controller.state == .recording)
        // 録音の原点（10 分前）ではなく、音声を検知した時刻から数える
        let elapsed = await controller.snapshot().elapsedSeconds
        #expect(elapsed >= 0 && elapsed < 5, "elapsed: \(elapsed)")
        await controller.stop()
    }

    @Test("検索はタイトル・参加者にもヒットし、会議ごとに前後 1 件を付けてまとめる")
    func searchGroupsByMeeting() throws {
        let store = try Store.inMemory()
        let titled = try store.createMeeting(MeetingRecord(title: "請求書レビュー", startedAt: Date(), attendees: [Attendee(name: "山田太郎")], privacyMode: .cloudOk, status: .done))
        let spoken = try store.createMeeting(MeetingRecord(title: "定例", startedAt: Date().addingTimeInterval(-3600), privacyMode: .cloudOk, status: .done))
        _ = try store.appendSegments([
            SegmentRecord(meetingId: spoken.id, source: .final, tStart: 0, tEnd: 1, clusterLabel: "spk_0", text: "おはようございます"),
            SegmentRecord(meetingId: spoken.id, source: .final, tStart: 1, tEnd: 2, clusterLabel: "spk_0", text: "請求書の再発行をお願いします"),
            SegmentRecord(meetingId: spoken.id, source: .final, tStart: 2, tEnd: 3, clusterLabel: "spk_1", text: "承知しました"),
            SegmentRecord(meetingId: spoken.id, source: .final, tStart: 3, tEnd: 4, clusterLabel: "spk_1", text: "請求書は来週送ります"),
        ])
        let results = try store.search("請求書")
        #expect(results.map(\.meeting.id) == [titled.id, spoken.id])
        #expect(results[0].titleMatched)
        #expect(results[0].segmentHits.isEmpty)
        #expect(!results[1].titleMatched)
        #expect(results[1].segmentHits.map(\.segment.text) == ["請求書の再発行をお願いします", "請求書は来週送ります"])
        #expect(results[1].segmentHits[0].context.map(\.text) == ["おはようございます", "請求書の再発行をお願いします", "承知しました"])
        #expect(results[1].segmentHits[1].context.map(\.text) == ["承知しました", "請求書は来週送ります"])
        // 参加者名でもヒット、会議数の上限
        #expect(try store.search("山田").first?.titleMatched == true)
        #expect(try store.search("請求書", meetingLimit: 1).count == 1)
        #expect(try store.search("お").count == 1)
    }

    @Test("アクションは保存時に ID を持ち、再要約でも完了状態と手動アクションを保つ")
    func actionIdentity() throws {
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "t", startedAt: Date(), privacyMode: .cloudOk, status: .done))
        let segments = try store.appendSegments([SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 1, clusterLabel: "me", text: "本文")])
        let id = Int(try #require(segments.first?.id))
        let fingerprint = try PipelineFingerprint.encoded(store.summaryInput(meetingId: meeting.id))
        let summary = MinutesSummary(summaryMd: "要約", decisions: [], actionItems: [
            .init(text: "資料を送る", owner: "me", kind: .ownCommitment, due: nil, evidence: [id]),
            .init(text: "見積を確認", owner: "田中", kind: .theirTask, due: "2026-10-01", evidence: [id]),
        ], openQuestions: [], keytermsLearned: [])
        try store.saveGeneratedSummary(meetingId: meeting.id, summary: summary, model: "m", inputFingerprint: fingerprint)
        var notes = try #require(try store.notes(meetingId: meeting.id))
        #expect(notes.inputFingerprint == fingerprint)
        let ids = notes.actionItems.compactMap(\.id)
        #expect(ids.count == 2 && Set(ids).count == 2)
        // 完了 → 手動追加 → 再要約（文言が同じものは ID と完了を引き継ぎ、手動は残る）
        notes = try store.setActionCompletion(meetingId: meeting.id, action: notes.actionItems[0], done: true)
        notes = try store.addManualAction(meetingId: meeting.id, text: "議事録を共有", due: "2026-09-30")
        #expect(notes.actionItems.count == 3)
        #expect(notes.actionItems[2].manual == true && notes.actionItems[2].id != nil)
        let regenerated = MinutesSummary(summaryMd: "要約 2", decisions: [], actionItems: [
            .init(text: "資料を送る", owner: "me", kind: .ownCommitment, due: nil, evidence: [id]),
            .init(text: "新しいタスク", owner: "me", kind: .ownCommitment, due: nil, evidence: [id]),
        ], openQuestions: [], keytermsLearned: [])
        try store.saveGeneratedSummary(meetingId: meeting.id, summary: regenerated, model: "m", inputFingerprint: fingerprint)
        let after = try #require(try store.notes(meetingId: meeting.id))
        #expect(after.actionItems.map(\.text) == ["資料を送る", "新しいタスク", "議事録を共有"])
        #expect(after.actionItems[0].id == ids[0])
        #expect(after.actionItems[0].done == true)
        #expect(after.actionItems[1].id != nil && after.actionItems[1].done == nil)
        #expect(after.actionItems[2].manual == true)
        // ID で完了を切り替え、削除できる
        let toggled = try store.setActionCompletion(meetingId: meeting.id, action: after.actionItems[2], done: true)
        #expect(toggled.actionItems[2].done == true)
        let removed = try store.removeAction(meetingId: meeting.id, actionId: after.actionItems[2].id!)
        #expect(removed.actionItems.count == 2)
    }

    @Test("発話単位の話者変更はクラスタの再割当・再認識で上書きされず、要約入力にも反映される")
    func perSegmentSpeakerOverride() throws {
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "t", startedAt: Date(), privacyMode: .cloudOk, status: .done))
        try store.saveTranscript(meetingId: meeting.id, segments: [
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 1, clusterLabel: "spk_0", text: "a"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 1, tEnd: 2, clusterLabel: "spk_0", text: "b"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 2, tEnd: 3, clusterLabel: "spk_1", text: "c"),
        ], speakers: [SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_0"), SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_1")])
        let speakers = try store.speakers(meetingId: meeting.id)
        let spk1 = try #require(speakers.first { $0.clusterLabel == "spk_1" })
        let second = try #require(try store.segments(meetingId: meeting.id, source: .final)[1].id)
        try store.overrideSegmentSpeaker(segmentId: second, meetingId: meeting.id, speakerId: spk1.id)
        #expect(try store.segments(meetingId: meeting.id, source: .final)[1].speakerId == spk1.id)
        // クラスタ全体の割当・再認識でも個別指定は残る
        try store.assignSpeaker(meetingId: meeting.id, clusterLabel: "spk_0", personId: nil, displayName: "田中")
        try store.assignSpeaker(meetingId: meeting.id, clusterLabel: "spk_1", personId: nil, displayName: "佐藤")
        try store.replaceSpeakers(meetingId: meeting.id, with: [SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_0"), SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_1")])
        let segments = try store.segments(meetingId: meeting.id, source: .final)
        #expect(segments[1].speakerId == spk1.id)
        #expect(segments[0].speakerId == speakers.first { $0.clusterLabel == "spk_0" }?.id)
        let input = try store.summaryInput(meetingId: meeting.id)
        #expect(input.segments.map(\.speaker) == ["spk_0", "spk_1", "spk_1"])
        #expect(input.speakerNames["spk_1"] == "佐藤")
        // 新しい名前の話者行を作って割り当て、自動割当に戻せる
        let manual = try store.findOrCreateManualSpeaker(meetingId: meeting.id, personId: nil, displayName: "鈴木")
        #expect(manual.clusterLabel.hasPrefix("manual_"))
        try store.overrideSegmentSpeaker(segmentId: second, meetingId: meeting.id, speakerId: manual.id)
        #expect(try store.findOrCreateManualSpeaker(meetingId: meeting.id, personId: nil, displayName: "鈴木").id == manual.id)
        try store.overrideSegmentSpeaker(segmentId: second, meetingId: meeting.id, speakerId: nil)
        #expect(try store.segments(meetingId: meeting.id, source: .final)[1].speakerId == speakers.first { $0.clusterLabel == "spk_0" }?.id)
        // 別の会議の話者は指定できない
        let other = try store.createMeeting(MeetingRecord(title: "o", startedAt: Date(), privacyMode: .cloudOk, status: .done))
        let foreign = try store.findOrCreateManualSpeaker(meetingId: other.id, personId: nil, displayName: "x")
        #expect(throws: StoreError.self) { try store.overrideSegmentSpeaker(segmentId: second, meetingId: meeting.id, speakerId: foreign.id) }
    }

    @Test("保持期限: 管理下の会議フォルダは成果物ごと削除し、外部フォルダは音声だけ消す")
    func retentionRemovesManagedFolder() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let managedRoot = root.appendingPathComponent("audio", isDirectory: true)
        func makeMeeting(_ directory: URL) throws -> MeetingRecord {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0]).write(to: directory.appendingPathComponent(RecordingSession.systemArchiveName))
            try Data("{}".utf8).write(to: directory.appendingPathComponent(PostProcessPipeline.systemArtifact))
            let ended = Date().addingTimeInterval(-40 * 86_400)
            let meeting = try store.createMeeting(MeetingRecord(title: directory.lastPathComponent, startedAt: ended.addingTimeInterval(-3600), endedAt: ended, privacyMode: .cloudOk, status: .done, audioDir: directory.path))
            _ = try store.logExport(meetingId: meeting.id, target: "local_export", status: .ok)
            return meeting
        }
        let managed = try makeMeeting(managedRoot.appendingPathComponent("01MANAGED", isDirectory: true))
        let external = try makeMeeting(root.appendingPathComponent("recordings/weekly", isDirectory: true))
        let report = try AudioRetention.purge(store: store, retentionDays: 30, managedRoot: managedRoot)
        #expect(Set(report.purgedMeetingIds) == [managed.id, external.id])
        #expect(!FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("01MANAGED").path))
        let externalDirectory = root.appendingPathComponent("recordings/weekly")
        #expect(FileManager.default.fileExists(atPath: externalDirectory.appendingPathComponent(PostProcessPipeline.systemArtifact).path))
        #expect(!FileManager.default.fileExists(atPath: externalDirectory.appendingPathComponent(RecordingSession.systemArchiveName).path))
        #expect(try store.meeting(id: managed.id)?.audioDir == nil)
    }

    @Test("区間読み込みと声のサンプル抽出はファイル全体を読まない")
    func rangedAudioLoad() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("system_16k.wav")
        try AudioFileTools.writeWAV(samples: tone(seconds: 3), sampleRate: 16_000, to: wav)
        let slice = try AudioFileTools.loadMono16k(wav, from: 1, to: 2)
        #expect(abs(slice.count - 16_000) <= 2)
        #expect(try AudioFileTools.loadMono16k(wav, from: 5).isEmpty)
        let full = try AudioFileTools.loadMono16k(wav)
        #expect(abs(full.count - 48_000) <= 2)
        let meetingId = "m"
        let segments = [
            SegmentRecord(meetingId: meetingId, source: .final, tStart: 0, tEnd: 2, clusterLabel: "spk_0", text: "短い"),
            SegmentRecord(meetingId: meetingId, source: .final, tStart: 0.5, tEnd: 2.9, clusterLabel: "spk_0", text: "長い"),
        ]
        // 5 秒未満しかないので候補なし、maximumSeconds を下げれば抽出できる
        #expect(try VoiceSampleExtractor.extract(clusterLabel: "spk_0", segments: segments, audioURL: wav, outputURL: root.appendingPathComponent("v.wav"), meetingId: meetingId) == nil)
    }

    @Test("書き出しフォルダの削除と、タイトル変更後の旧フォルダの掃除")
    func exportFolderCleanup() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "旧タイトル", startedAt: Date(timeIntervalSince1970: 1_800_000_000), privacyMode: .cloudOk, status: .done))
        _ = try store.appendSegments([SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 1, clusterLabel: "me", text: "本文")])
        let exportDirectory = root.appendingPathComponent("export")
        let syncDirectory = root.appendingPathComponent("sync")
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: CapturingTranscriber(), summarizer: nil, exportDirectory: exportDirectory, syncTargets: [LocalDirectorySyncTarget(destination: syncDirectory)]))
        try await pipeline.refreshExport(meetingId: meeting.id)
        let oldName = MeetingExporter.folderName(meeting: meeting)
        #expect(FileManager.default.fileExists(atPath: exportDirectory.appendingPathComponent(oldName).path))
        try store.updateMeetingTitle(id: meeting.id, title: "新タイトル")
        try await pipeline.refreshExport(meetingId: meeting.id)
        let renamed = try #require(try store.meeting(id: meeting.id))
        let newName = MeetingExporter.folderName(meeting: renamed)
        #expect(newName != oldName)
        for directory in [exportDirectory, syncDirectory] {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(newName).path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(oldName).path))
        }
        let removed = try await pipeline.removeExportedFiles(meetingId: meeting.id)
        #expect(removed.count == 2)
        #expect(!FileManager.default.fileExists(atPath: exportDirectory.appendingPathComponent(newName).path))
        #expect(!FileManager.default.fileExists(atPath: syncDirectory.appendingPathComponent(newName).path))
    }

    @Test("要約の 1 行目を一覧の副題にする")
    func summaryPreview() throws {
        #expect(Store.summaryPreview("## 結論\n\n- **リリースは 10/1** に決定\n- 予算は保留") == "リリースは 10/1 に決定")
        #expect(Store.summaryPreview("1. 最初の項目\n2. 次") == "最初の項目")
        #expect(Store.summaryPreview("   \n") == nil)
        #expect(Store.summaryPreview(String(repeating: "あ", count: 200))?.count == 121)
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "t", startedAt: Date(), privacyMode: .cloudOk, status: .done))
        try store.upsertNotes(NotesRecord(meetingId: meeting.id, summaryMd: "# 見出し\n本文の要約"))
        let snapshot = try store.writer.read { db in try Store.fetchSummaryPreviews(db, meetingIds: [meeting.id]) }
        #expect(snapshot[meeting.id] == "本文の要約")
    }

    @Test("keyterms は新しい順に返す")
    func keytermOrder() throws {
        let store = try Store.inMemory()
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO keyterms(term, source, created_at) VALUES ('古い語', 'learned', '2026-01-01T00:00:00Z'), ('新しい語', 'learned', '2026-09-01T00:00:00Z')")
        }
        #expect(try store.keyterms() == ["新しい語", "古い語"])
        #expect(try store.keytermRecords().map(\.term) == ["新しい語", "古い語"])
    }

    @Test("人物の改名は会議の話者名に反映され、削除は割当名を残す")
    func peopleManagement() throws {
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "t", startedAt: Date(), privacyMode: .cloudOk, status: .done))
        let person = try store.findOrCreatePerson(name: "たなか", email: "t@example.com")
        try store.assignSpeaker(meetingId: meeting.id, clusterLabel: "spk_0", personId: person.id, displayName: person.name)
        try store.renamePerson(id: person.id, name: "田中")
        #expect(try store.speakers(meetingId: meeting.id).first?.displayName == "田中")
        try store.addVoiceSample(personId: person.id, sample: VoiceSample(path: "/tmp/x.wav", duration: 5, meetingId: meeting.id))
        let paths = try store.deletePerson(id: person.id)
        #expect(paths == ["/tmp/x.wav"])
        let speaker = try #require(try store.speakers(meetingId: meeting.id).first)
        #expect(speaker.personId == nil && speaker.displayName == "田中")
    }
}

@Suite("タグ・参加者・マイクデバイス（2026-09-24）")
struct TagsAttendeesDevicesTests {
    @Test("タグは正規化して保存し、タグ別フィルタ・件数・検索・書き出しに反映される")
    func tags() throws {
        let store = try Store.inMemory()
        let a = try store.createMeeting(MeetingRecord(title: "A", startedAt: Date(), privacyMode: .cloudOk, status: .done, tags: [" 顧客X ", "定例", "顧客X", ""]))
        let b = try store.createMeeting(MeetingRecord(title: "B", startedAt: Date().addingTimeInterval(-60), privacyMode: .cloudOk, status: .done))
        #expect(try store.meeting(id: a.id)?.tags == ["顧客X", "定例"])
        #expect(try store.meeting(id: b.id)?.tags == [])
        try store.setMeetingTags(id: b.id, tags: ["定例"])
        #expect(try store.listMeetings(.tag("定例")).map(\.id) == [a.id, b.id])
        #expect(try store.listMeetings(.tag("顧客X")).map(\.id) == [a.id])
        #expect(try store.listMeetings(.tag("なし")).isEmpty)
        #expect(try store.tagCounts() == [TagCount(tag: "定例", count: 2), TagCount(tag: "顧客X", count: 1)])
        // タグでも検索にヒットする
        #expect(try store.search("顧客X").map(\.meeting.id) == [a.id])
        #expect(try store.search("顧客X").first?.titleMatched == true)
        // 外すと一覧・件数から消える
        try store.setMeetingTags(id: a.id, tags: [])
        #expect(try store.tagCounts() == [TagCount(tag: "定例", count: 1)])
        // 書き出しの frontmatter
        let meeting = try #require(try store.meeting(id: b.id))
        let bundle = try MeetingExporter.build(.init(meeting: meeting, speakers: [], segments: [], notes: nil, providerDescription: "x"))
        #expect(String(decoding: bundle.files[0].data, as: UTF8.self).contains("tags: [\"定例\"]"))
    }

    @Test("参加者の更新は名前の空白を落とし、要約入力と書き出しに反映される")
    func attendees() throws {
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "t", startedAt: Date(), attendees: [Attendee(name: "田中")], privacyMode: .cloudOk, status: .done))
        try store.updateMeetingAttendees(id: meeting.id, attendees: [Attendee(name: " 田中 "), Attendee(name: "佐藤", email: "S@example.com")])
        let updated = try #require(try store.meeting(id: meeting.id))
        #expect(updated.attendees == [Attendee(name: " 田中 "), Attendee(name: "佐藤", email: "S@example.com")])
        #expect(try store.summaryInput(meetingId: meeting.id).attendees.count == 2)
        try store.updateMeetingAttendees(id: meeting.id, attendees: [])
        #expect(try store.meeting(id: meeting.id)?.attendees == [])
    }

    @Test("入力デバイスの一覧は既定入力を 1 つだけ印付けし、指定なしの録音設定は既定入力を使う")
    func inputDevices() {
        let devices = MicCapture.inputDevices()
        #expect(devices.filter(\.isDefault).count <= 1)
        #expect(Set(devices.map(\.uid)).count == devices.count)
        let capture = MicCapture(deviceUID: "")
        #expect(capture.deviceUID == nil)
        var options = RecordingOptions(outputDirectory: FileManager.default.temporaryDirectory)
        #expect(options.micDeviceUID == nil)
        options.micDeviceUID = "abc"
        #expect(options.micDeviceUID == "abc")
    }

    @Test("グローバルショートカットの設定は JSON に往復する")
    func shortcutSettings() throws {
        var settings = AppSettings()
        settings.globalShortcut = GlobalShortcut(keyCode: 15, carbonModifiers: 256 | 4096, display: "⌃⌘R")
        settings.micDevice = "BuiltInMicrophoneDevice"
        let data = try JSONCoding.encoder().encode(settings)
        let decoded = try JSONCoding.decoder().decode(AppSettings.self, from: data)
        #expect(decoded.globalShortcut == settings.globalShortcut)
        #expect(decoded.micDevice == "BuiltInMicrophoneDevice")
        // 旧設定（キーが足りない）は既定値で読める
        let legacy = try JSONCoding.decoder().decode(AppSettings.self, from: Data("{\"include_mic\": false, \"unknown_key\": 1}".utf8))
        #expect(legacy.globalShortcut == nil && legacy.micDevice == nil)
        #expect(legacy.includeMic == false && legacy.targetBundleIdentifiers == AppSettings.defaultTargetBundleIdentifiers)
        #expect(try JSONCoding.decoder().decode(AppSettings.self, from: Data("{}".utf8)) == AppSettings())
    }
}
