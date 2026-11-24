import AVFoundation
import Foundation
@testable import MinutesCore
import Synchronization
import Testing

/// 呼ばれたら失敗にする文字起こし（取り込んだ会議は、この Mac から音声を送らない）。
private final class ForbiddenTranscriber: BatchTranscriber, Sendable {
    let id: String
    let runsLocally: Bool
    let calls = Mutex(0)

    init(id: String, runsLocally: Bool) {
        self.id = id
        self.runsLocally = runsLocally
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        calls.withLock { $0 += 1 }
        throw TranscriptionError.unsupportedAudio("取り込んだ会議を文字起こしし直そうとした")
    }
}

/// 呼ばれたら失敗にする要約。
private final class ForbiddenSummarizer: Summarizing, Sendable {
    let calls = Mutex(0)
    var modelDescription: String { "forbidden" }

    func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
        calls.withLock { $0 += 1 }
        throw PipelineError.summaryUnavailable
    }
}

/// 会議の言語を変えたあとに、この Mac で文字起こしし直す手段。
private final class RetranscribingTranscriber: BatchTranscriber, Sendable {
    let id = "retranscribe-fixture"
    let runsLocally = true
    let languages = Mutex<[String]>([])

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        languages.withLock { $0.append(request.language) }
        return TranscriptionResult(segments: [.init(start: 0, end: 2, text: "Let's fix the release date.", speakerLabel: "speaker_0")], providerMeta: ["provider": id])
    }
}

/// テスト用のサーバーの中身（道ごとの答えと、呼ばれた回数）。
private final class CloudRoutes: Sendable {
    typealias Answer = (status: Int, headers: [String: String], body: Data)
    let answers = Mutex<[String: Answer]>([:])
    let hits = Mutex<[String: Int]>([:])

    func set(_ path: String, _ answer: Answer) { answers.withLock { $0[path] = answer } }
    func hitCount(_ path: String) -> Int { hits.withLock { $0[path] ?? 0 } }

    func client() -> MinutesCloudClient {
        let base = StubURLProtocol.host { [self] request in
            hits.withLock { $0[request.path, default: 0] += 1 }
            return answers.withLock { $0[request.path] } ?? (404, ["content-type": "application/json"], Data(#"{"error":"not_found"}"#.utf8))
        }
        return MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "test-token" })
    }
}

private func jsonAnswer(_ object: Any, status: Int = 200) -> CloudRoutes.Answer {
    (status, ["content-type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
}

private func recordingObject(id: String, source: String, status: String = "done", title: String? = nil, summaryError: String? = nil) -> [String: Any] {
    [
        "id": id, "client_id": "\(source)-\(id.prefix(8))", "source": source, "title": title ?? NSNull(),
        "started_at": "2026-11-20T01:00:00.000Z", "time_zone": "Asia/Tokyo", "language": NSNull(), "status": status, "error": NSNull(),
        "duration_seconds": status == "done" ? 3.0 : NSNull(), "detected_language": status == "done" ? "ja" : NSNull(),
        "speaker_count": 2, "audio_bytes": 12_000, "audio_expires_at": "2026-12-20T01:00:00.000Z", "audio_deleted": false,
        "summary_model": "claude", "summary_error": summaryError ?? NSNull(), "summarize": true, "diarize": true, "group": NSNull(),
        "created_at": "2026-11-20T01:00:00.000Z", "completed_at": "2026-11-20T01:01:00.000Z",
    ]
}

private struct CloudFixture {
    static let watchID = "11111111-1111-4111-8111-111111111111"
    static let phoneID = "22222222-2222-4222-8222-222222222222"
    static let start = Date(timeIntervalSince1970: 1_795_050_000)

    let root: URL
    let store: Store
    let routes = CloudRoutes()
    var audioRoot: URL { root.appendingPathComponent("audio") }
    var exportRoot: URL { root.appendingPathComponent("export") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-cloud-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try Store.open(at: root.appendingPathComponent("test.sqlite"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// iPhone・Watch の録音と同じ形の音声（ADTS の AAC、16 kHz mono 32 kbps）。
    func adts(seconds: Int = 3) throws -> Data {
        let url = root.appendingPathComponent("device-\(UUID().uuidString).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try #require(file?.processingFormat)
        for second in 0..<seconds {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            for i in 0..<16_000 { buffer.floatChannelData![0][i] = 0.2 * sin(Float(second * 16_000 + i) * 2 * .pi * 330 / 16_000) }
            try file?.write(from: buffer)
        }
        file = nil  // 閉じる
        return try Data(contentsOf: url)
    }

    /// サーバーの文字起こし（発話の番号は 10 から。番号が位置と同じだと、付け替えの誤りに気づけない）。
    func transcript(id: String, title: String? = "架空の定例", language: String = "ja") -> TranscriptDocument {
        TranscriptDocument(
            meeting: .init(id: id, title: title, startedAt: Self.start, durationSeconds: 3),
            provider: "elevenlabs.scribe_v2", language: language,
            speakers: [
                .init(label: "spk_0", name: "佐藤", providerLabel: "speaker_0", track: "system"),
                .init(label: "spk_1", name: nil, providerLabel: "speaker_1", track: "system"),
            ],
            segments: [
                .init(id: 10, track: "system", tStart: 0, tEnd: 1.2, speaker: "spk_0", text: "おはようございます。新機能のリリース日を決めましょう。"),
                .init(id: 11, track: "system", tStart: 1.3, tEnd: 2.4, speaker: "spk_1", text: "来週の金曜日でお願いします。"),
                .init(id: 12, track: "system", tStart: 2.5, tEnd: 2.9, speaker: "spk_0", text: "わかりました。"),
            ])
    }

    var summary: MinutesSummary {
        MinutesSummary(
            summaryMd: "- リリース日を決めた",
            decisions: [.init(text: "リリースは来週の金曜日", evidence: [11])],
            actionItems: [.init(text: "告知文を用意する", owner: "spk_1", kind: .theirTask, due: nil, evidence: [11, 12])],
            openQuestions: [], keytermsLearned: [])
    }

    /// 1 つの録音の文字起こし・要約・音声をサーバーに置く。
    func serve(id: String, transcript: TranscriptDocument? = nil, summary: MinutesSummary?, audio: Data) throws {
        let encoder = JSONCoding.encoder()
        routes.set("/v1/recordings/\(id)/transcript", (200, ["content-type": "application/json"], try encoder.encode(transcript ?? self.transcript(id: id))))
        if let summary { routes.set("/v1/recordings/\(id)/summary", (200, ["content-type": "application/json"], try encoder.encode(summary))) }
        routes.set("/v1/recordings/\(id)/audio", (200, ["content-type": "audio/aac"], audio))
    }

    func list(_ recordings: [[String: Any]]) { routes.set("/v1/recordings", jsonAnswer(["recordings": recordings])) }

    /// Watch で録った会議が 1 つ、サーバーにできている。
    func serveWatchMeeting() throws {
        try serve(id: Self.watchID, summary: summary, audio: try adts())
        list([recordingObject(id: Self.watchID, source: "watch", title: "架空の定例")])
    }

    func pull(now: Date = Date()) async throws -> CloudMeetingImport.Report {
        try await CloudMeetingImport.pull(client: routes.client(), store: store, audioRoot: audioRoot, now: now)
    }

    /// 取り込んだ会議の後処理を終わりまで走らせる。
    func process(_ providers: PipelineProviders) async {
        let queue = PostProcessingQueue(store: store, pipeline: PostProcessPipeline(store: store, providers: providers))
        await queue.start()
        await queue.waitUntilIdle()
    }

    func audioDirectories() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: audioRoot.path)) ?? []
    }
}

@Suite("サーバーの会議の取り込み（iPhone・Apple Watch、SPEC §4.5）")
struct CloudMeetingImportTests {
    @Test("iPhone・Watch の会議を取り込み、文字起こしと要約はサーバーのものを使う（この Mac の手段は呼ばない）")
    func importsAndUsesServerResults() async throws {
        let f = try CloudFixture(); defer { f.cleanup() }
        try f.serve(id: CloudFixture.watchID, summary: f.summary, audio: try f.adts())
        f.list([
            // この Mac の Minutes クラウドの文字起こしの録音と、まだ処理中の録音は取り込まない
            recordingObject(id: "33333333-3333-4333-8333-333333333333", source: "mac"),
            recordingObject(id: CloudFixture.phoneID, source: "iphone", status: "transcribing"),
            recordingObject(id: CloudFixture.watchID, source: "watch", title: "架空の定例"),
        ])

        let report = try await f.pull()
        #expect(report.imported.count == 1 && report.pending == 1 && report.failures.isEmpty && report.interruption == nil)
        let meeting = try #require(report.imported.first)
        #expect(meeting.title == "架空の定例" && meeting.meetingPlatform == .watch)
        #expect(meeting.cloudRecordingId == CloudFixture.watchID && meeting.cloudProcessed)
        #expect(meeting.meetingStatus == .finalizing && meeting.privacy == .cloudOk)
        #expect(meeting.language == "ja" && meeting.summaryLanguage == "ja")
        #expect(meeting.recordingStartedAt == meeting.startedAt)
        let directory = try #require(meeting.audioDirectoryURL)
        #expect(abs(try AudioFileTools.duration(of: directory.appendingPathComponent(RecordingSession.systemSTTName)) - 3) < 0.2)
        #expect(abs(try AudioFileTools.duration(of: directory.appendingPathComponent(RecordingSession.systemArchiveName)) - 3) < 0.2)
        #expect(try f.store.postProcessingJobs().map(\.meetingId) == [meeting.id])
        #expect(f.routes.hitCount("/v1/recordings/\(CloudFixture.phoneID)/transcript") == 0)

        let cloud = ForbiddenTranscriber(id: "forbidden-cloud", runsLocally: false)
        let local = ForbiddenTranscriber(id: "forbidden-local", runsLocally: true)
        let summarizer = ForbiddenSummarizer()
        let notified = Mutex(0)
        await f.process(PipelineProviders(cloud: cloud, local: local, summarizer: summarizer, exportDirectory: f.exportRoot,
                                          notify: { _, _ in notified.withLock { $0 += 1 } }))

        let done = try #require(try f.store.meeting(id: meeting.id))
        #expect(done.meetingStatus == .done && done.cloudProcessed)
        #expect(cloud.calls.withLock { $0 } == 0 && local.calls.withLock { $0 } == 0 && summarizer.calls.withLock { $0 } == 0)
        // 取り込んだ会議は知らせない
        #expect(notified.withLock { $0 } == 0)

        // 本文はサーバーの区切りのまま。iPhone で付けた話者の名前も届く
        let segments = try f.store.segments(meetingId: meeting.id, source: .final)
        #expect(segments.map(\.text) == ["おはようございます。新機能のリリース日を決めましょう。", "来週の金曜日でお願いします。", "わかりました。"])
        #expect(segments.map(\.clusterLabel) == ["spk_0", "spk_1", "spk_0"])
        let speakers = try f.store.speakers(meetingId: meeting.id)
        #expect(speakers.first { $0.clusterLabel == "spk_0" }?.displayName == "佐藤")
        #expect(speakers.first { $0.clusterLabel == "spk_1" }?.displayName == nil)

        // 要約はサーバーのもの。根拠は DB の発話の ID に付け替わる
        let notes = try #require(try f.store.notes(meetingId: meeting.id))
        #expect(notes.summaryMd == "- リリース日を決めた" && notes.model == PostProcessPipeline.cloudSummaryModel)
        let ids = segments.compactMap { $0.id.map(Int.init) }
        #expect(notes.decisions.map(\.evidence) == [[ids[1]]])
        #expect(notes.actionItems.map(\.evidence) == [[ids[1], ids[2]]])
        #expect(notes.actionItems.first?.owner == "spk_1")

        // 検索と書き出し（P5 の完了条件）
        #expect(try f.store.search("リリース日").map(\.meeting.id) == [meeting.id])
        #expect(try f.store.search("告知文").first?.notesMatched == true)
        let exported = try #require(FileManager.default.enumerator(at: f.exportRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "meeting.md" })
        let markdown = try String(contentsOf: exported, encoding: .utf8)
        #expect(markdown.contains("リリースは来週の金曜日") && markdown.contains("来週の金曜日でお願いします。") && markdown.contains("platform: watch"))

        // 手順の記録に、サーバーのものを使ったことが残る
        #expect(try f.store.latestRun(meetingId: meeting.id, step: PipelineStep.transcribeFinal.rawValue)?.provider == "cloud: elevenlabs.scribe_v2")
        #expect(try f.store.latestRun(meetingId: meeting.id, step: PipelineStep.summarize.rawValue)?.provider == "cloud: minutes.cloud")
    }

    @Test("同じ録音は二重に取り込まない。Mac で消した会議も取り込み直さない")
    func importsOnce() async throws {
        let f = try CloudFixture(); defer { f.cleanup() }
        try f.serveWatchMeeting()
        let first = try await f.pull()
        let meeting = try #require(first.imported.first)
        #expect(try await f.pull().imported.isEmpty)
        #expect(try f.store.listMeetings(.all, limit: 10).count == 1 && f.audioDirectories().count == 1)
        #expect(f.routes.hitCount("/v1/recordings/\(CloudFixture.watchID)/audio") == 1)

        // 後処理を終えてから消す
        await f.process(PipelineProviders(cloud: nil, local: ForbiddenTranscriber(id: "local", runsLocally: true), summarizer: nil, exportDirectory: f.exportRoot))
        try f.store.deleteMeeting(id: meeting.id)
        #expect(try f.store.listMeetings(.all, limit: 10).isEmpty)
        #expect(try await f.pull().imported.isEmpty)
        #expect(try f.store.listMeetings(.all, limit: 10).isEmpty)
        #expect(try f.store.cloudImport(recordingId: CloudFixture.watchID)?.importStatus == .imported)
        #expect(f.routes.hitCount("/v1/recordings/\(CloudFixture.watchID)/audio") == 1)
    }

    @Test("ほかの取り込みが先に終えていたら、会議もフォルダも作らない")
    func losesRaceCleanly() async throws {
        let f = try CloudFixture(); defer { f.cleanup() }
        try f.serveWatchMeeting()
        let directory = f.audioRoot.appendingPathComponent("EARLIER")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let earlier = MeetingRecord(title: "先に取り込んだ会議", startedAt: CloudFixture.start, platform: .watch, privacyMode: .cloudOk, status: .finalizing,
                                    audioDir: directory.path, cloudRecordingId: CloudFixture.watchID, cloudProcessed: true)
        #expect(try f.store.createCloudMeeting(earlier) != nil)
        // 同じ録音の 2 つ目は書かない
        var second = earlier
        second.id = ULID.generate()
        #expect(try f.store.createCloudMeeting(second) == nil)
        #expect(try f.store.listMeetings(.all, limit: 10).map(\.title) == ["先に取り込んだ会議"])
        #expect(try await f.pull().imported.isEmpty)
        #expect(f.audioDirectories() == ["EARLIER"])
    }

    @Test("取り込めなかった録音は覚えて、間をあけて試す（定期の取り込みで落とし直さない）")
    func remembersFailures() async throws {
        let f = try CloudFixture(); defer { f.cleanup() }
        try f.serve(id: CloudFixture.watchID, summary: f.summary, audio: Data("音声ではない".utf8))
        try f.serve(id: CloudFixture.phoneID, transcript: f.transcript(id: CloudFixture.phoneID, title: nil), summary: nil, audio: try f.adts())
        f.list([recordingObject(id: CloudFixture.phoneID, source: "iphone", summaryError: "summary_failed"), recordingObject(id: CloudFixture.watchID, source: "watch")])
        let now = Date(timeIntervalSince1970: 1_795_100_000)

        // 1 つが読めなくても、ほかの録音は取り込む
        let report = try await f.pull(now: now)
        #expect(report.failures.map(\.recordingID) == [CloudFixture.watchID] && report.interruption == nil)
        #expect(report.imported.map(\.title) == ["iPhone の録音"])
        #expect(report.imported.first?.meetingPlatform == .iphone)
        #expect(f.audioDirectories().count == 1)
        let failed = try #require(try f.store.cloudImport(recordingId: CloudFixture.watchID))
        #expect(failed.importStatus == .failed && failed.attempts == 1 && failed.meetingId == nil)
        // 要約が失敗した録音は、要約を取りに行かない
        #expect(f.routes.hitCount("/v1/recordings/\(CloudFixture.phoneID)/summary") == 0)

        // すぐの取り込みでは試さない。10 分たてば試す
        #expect(try await f.pull(now: now.addingTimeInterval(300)).failures.isEmpty)
        #expect(f.routes.hitCount("/v1/recordings/\(CloudFixture.watchID)/audio") == 1)
        #expect(try await f.pull(now: now.addingTimeInterval(601)).failures.count == 1)
        #expect(try f.store.cloudImport(recordingId: CloudFixture.watchID)?.attempts == 2)
        // 2 回目のあとは 20 分
        #expect(try await f.pull(now: now.addingTimeInterval(601 + 900)).failures.isEmpty)
        #expect(CloudImportRecord.retryDelay(attempts: 1) == 600 && CloudImportRecord.retryDelay(attempts: 2) == 1200 && CloudImportRecord.retryDelay(attempts: 30) == 86_400)

        // サーバーに要約のない会議は、要約なしのまま done になる（この Mac の要約の手段は呼ばない）
        let summarizer = ForbiddenSummarizer()
        await f.process(PipelineProviders(cloud: nil, local: ForbiddenTranscriber(id: "local", runsLocally: true), summarizer: summarizer, exportDirectory: f.exportRoot))
        let meeting = try #require(try f.store.listMeetings(.all, limit: 10).first)
        #expect(meeting.meetingStatus == .done && summarizer.calls.withLock { $0 } == 0)
        #expect(try f.store.notes(meetingId: meeting.id)?.summaryMd == nil)
        #expect(try f.store.latestRun(meetingId: meeting.id, step: PipelineStep.summarize.rawValue)?.provider == "skipped (サーバーの要約なし)")
    }

    @Test("サーバーの混雑やログイン切れでは途中でやめ、録音の失敗としては覚えない")
    func stopsOnTransientErrors() async throws {
        let f = try CloudFixture(); defer { f.cleanup() }
        try f.serveWatchMeeting()
        f.routes.set("/v1/recordings/\(CloudFixture.watchID)/transcript", jsonAnswer(["error": "unavailable"], status: 503))
        let report = try await f.pull()
        #expect(report.imported.isEmpty && report.failures.isEmpty && report.interruption != nil)
        #expect(try f.store.cloudImport(recordingId: CloudFixture.watchID) == nil)
        #expect(f.audioDirectories().isEmpty)

        // 一覧を読めないときは投げる
        f.routes.set("/v1/recordings", jsonAnswer(["error": "unauthorized"], status: 401))
        await #expect(throws: MinutesCloudError.self) { _ = try await f.pull() }
        #expect(CloudMeetingImport.stopsPull(URLError(.notConnectedToInternet)) && CloudMeetingImport.stopsPull(MinutesCloudError.notSignedIn))
        #expect(!CloudMeetingImport.stopsPull(MinutesCloudError.http(status: 404, code: "not_found", requestID: nil)))
        #expect(!CloudMeetingImport.stopsPull(CloudMeetingImport.ImportError.tooShort))
    }

    @Test("サーバーの文字起こしがなくなっていたら失敗にする（音声をこの Mac の手段へ送り直さない）")
    func failsWithoutServerTranscript() async throws {
        let f = try CloudFixture(); defer { f.cleanup() }
        try f.serveWatchMeeting()
        let meeting = try #require(try await f.pull().imported.first)
        let directory = try #require(meeting.audioDirectoryURL)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(PostProcessPipeline.cloudTranscriptArtifact))
        let cloud = ForbiddenTranscriber(id: "forbidden-cloud", runsLocally: false)
        let local = ForbiddenTranscriber(id: "forbidden-local", runsLocally: true)
        await f.process(PipelineProviders(cloud: cloud, local: local, summarizer: nil, exportDirectory: f.exportRoot))
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .failed)
        #expect(cloud.calls.withLock { $0 } == 0 && local.calls.withLock { $0 } == 0)
    }

    @Test("会議の言語を変えると、そこからはこの Mac の手段で文字起こしと要約をやり直す")
    func languageChangeReleasesToMac() async throws {
        let f = try CloudFixture(); defer { f.cleanup() }
        try f.serveWatchMeeting()
        let meeting = try #require(try await f.pull().imported.first)
        await f.process(PipelineProviders(cloud: nil, local: ForbiddenTranscriber(id: "local", runsLocally: true), summarizer: ForbiddenSummarizer(), exportDirectory: f.exportRoot))
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .done)

        // 会議の画面で言語を変えるのと同じ手順
        try f.store.prepareRetranscription(meetingId: meeting.id)
        try f.store.setMeetingLanguage(id: meeting.id, language: .en, detected: false)
        #expect(try f.store.meeting(id: meeting.id)?.cloudProcessed == false)
        try f.store.requestPostProcessing(meetingId: meeting.id, reprocess: true)
        let transcriber = RetranscribingTranscriber()
        let notified = Mutex(0)
        await f.process(PipelineProviders(cloud: nil, local: transcriber, summarizer: FakeSummarizer(), exportDirectory: f.exportRoot,
                                          notify: { _, _ in notified.withLock { $0 += 1 } }))

        let done = try #require(try f.store.meeting(id: meeting.id))
        #expect(done.meetingStatus == .done && !done.cloudProcessed)
        // 元の録音の ID は残る
        #expect(done.cloudRecordingId == CloudFixture.watchID)
        #expect(transcriber.languages.withLock { $0 } == ["en"])
        #expect(try f.store.segments(meetingId: meeting.id, source: .final).map(\.text) == ["Let's fix the release date."])
        #expect(try f.store.notes(meetingId: meeting.id)?.model == "fake / prompt v0")
        #expect(notified.withLock { $0 } == 1)
        // 取り込み直しはしない
        #expect(try await f.pull().imported.isEmpty)
    }

    @Test("根拠の付け替えは、時刻と文言が同じ発話を順に対応させる（Mac で直した文言は元の文言で合わせる）")
    func evidenceMap() {
        func row(_ id: Int64, _ start: Double, _ end: Double, _ text: String, original: String? = nil) -> SegmentRecord {
            var record = SegmentRecord(meetingId: "m", source: .final, tStart: start, tEnd: end, clusterLabel: "spk_0", text: text)
            record.id = id
            record.originalText = original ?? text
            return record
        }
        let segments: [TranscriptDocument.Segment] = [
            .init(id: 7, track: "system", tStart: 0, tEnd: 1, speaker: "spk_0", text: "はい"),
            .init(id: 8, track: "system", tStart: 1, tEnd: 2, speaker: "spk_0", text: "決めましょう"),
            .init(id: 9, track: "system", tStart: 2, tEnd: 3, speaker: "spk_0", text: "なくなった発話"),
        ]
        let rows = [row(101, 0, 1, "はい"), row(102, 1, 2, "決めましょう（直した）", original: "決めましょう")]
        #expect(PostProcessPipeline.evidenceMap(from: segments, to: rows) == [7: 101, 8: 102])
        let summary = MinutesSummary(summaryMd: "", decisions: [.init(text: "d", evidence: [8, 9])], actionItems: [], openQuestions: [], keytermsLearned: [])
        #expect(summary.remappingEvidence(PostProcessPipeline.evidenceMap(from: segments, to: rows)).decisions.first?.evidence == [102])
    }

    @Test("音声の種類は中身から決める")
    func audioExtension() throws {
        let f = try CloudFixture(); defer { f.cleanup() }
        func ext(_ bytes: [UInt8]) throws -> String {
            let url = f.root.appendingPathComponent(UUID().uuidString)
            try Data(bytes).write(to: url)
            return CloudMeetingImport.audioExtension(of: url)
        }
        #expect(try ext([0xFF, 0xF1, 0x60, 0x40]) == "aac")
        #expect(try ext([0, 0, 0, 0x1C] + Array("ftypM4A ".utf8)) == "m4a")
        #expect(try ext(Array("RIFF".utf8) + [0, 0, 0, 0]) == "wav")
        #expect(try ext(Array("fLaC".utf8)) == "flac")
        #expect(try ext([]) == "aac")
    }
}
