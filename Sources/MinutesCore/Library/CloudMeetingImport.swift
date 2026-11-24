import Foundation

/// サーバーの会議（iPhone・Apple Watch で録って、サーバーで文字起こしと要約をしたもの）を、この Mac の会議として取り込む（SPEC §4.5）。
/// 音声・文字起こし・要約を落として、外部の録音の取り込み（`AudioImport`）と同じ形の会議にする（音声全体を 1 本の system トラック）。
/// - 文字起こしと要約はサーバーのものをそのまま使い、この Mac ではやり直さない（`MeetingRecord.cloudProcessed`、`PostProcessPipeline`）。
/// - 同じ録音は二重に取り込まない（`cloud_imports`。会議を Mac で消しても取り込み直さない）。
/// - 一度きりの取り込み。あとで iPhone で直した題名や話者の名前は届かず、Mac で直した内容もサーバーへ戻さない。
public enum CloudMeetingImport {
    /// 取り込む録音の出どころ（サーバーの一覧には、この Mac の Minutes クラウドの文字起こしの録音なども出る）。
    public static let platforms: [String: MeetingPlatform] = ["iphone": .iphone, "watch": .watch]

    public struct Failure: Sendable, Equatable {
        public var recordingID: String
        public var message: String
    }

    public struct Report: Sendable {
        public var imported: [MeetingRecord] = []
        /// 取り込めなかった録音（覚えておき、間をあけて試し直す）
        public var failures: [Failure] = []
        /// サーバーでまだ処理中の録音（次の取り込みで見る）
        public var pending = 0
        /// 途中でやめた理由（回線・ログイン切れなど。残りは次の取り込みで続ける）
        public var interruption: String?

        public init() {}
    }

    public enum ImportError: LocalizedError, Equatable {
        case unreadableAudio(String)
        case tooShort

        public var errorDescription: String? {
            switch self {
            case let .unreadableAudio(detail): "サーバーの音声を読めません（\(detail)）"
            case .tooShort: "音声が短すぎます"
            }
        }
    }

    /// サーバーの一覧を読み、まだ取り込んでいない会議を取り込む。会議と後処理の依頼を作るだけで、後処理は呼び出し側が始める（`PostProcessingQueue.start()`）。
    /// 一覧を読めなければ投げる。途中の回線・ログイン切れは `interruption` に残してそこでやめ、1 つの録音だけの誤りは覚えて次へ進む。
    /// 音声全体を読み込むので、main の外で呼ぶ。同じプロセスで同時に 2 つ走らせない（呼び出し側が 1 つにする）。
    public static func pull(client: MinutesCloudClient, store: Store, audioRoot: URL, now: Date = Date()) async throws -> Report {
        let recordings = try await client.recordings()
        let skip = try store.cloudRecordingsToSkip(now: now)
        var report = Report()
        // 一覧は新しい順。古い順に取り込む
        for recording in recordings.reversed() {
            guard let platform = recording.source.flatMap({ platforms[$0] }) else { continue }
            guard recording.status == "done" else {
                if !recording.isFinished { report.pending += 1 }
                continue
            }
            guard !skip.contains(recording.id) else { continue }
            do {
                try Task.checkCancellation()
                if let meeting = try await importRecording(recording, platform: platform, client: client, store: store, audioRoot: audioRoot) {
                    report.imported.append(meeting)
                }
            } catch {
                if stopsPull(error) {
                    report.interruption = error.localizedDescription
                    break
                }
                try? store.recordCloudImportFailure(recordingId: recording.id, error: error.localizedDescription, now: now)
                report.failures.append(Failure(recordingID: recording.id, message: error.localizedDescription))
            }
        }
        return report
    }

    /// 取り込み全体をやめる誤り（回線・ログイン切れ・サーバーの混雑・中止）。録音ごとの失敗としては覚えない。
    static func stopsPull(_ error: Error) -> Bool {
        if error is CancellationError || error is URLError { return true }
        guard let cloud = error as? MinutesCloudError else { return false }
        if case .notSignedIn = cloud { return true }
        guard let status = cloud.status else { return false }
        return status == 401 || status == 429 || status >= 500
    }

    /// 1 つの録音を会議にする。すでに取り込み済み（ほかの取り込みが先に終えた）なら nil。
    static func importRecording(_ recording: MinutesCloudRecording, platform: MeetingPlatform, client: MinutesCloudClient, store: Store, audioRoot: URL) async throws -> MeetingRecord? {
        let document = try await client.transcript(recordingID: recording.id)
        var summary: MinutesSummary?
        if recording.summaryError == nil {
            do {
                summary = try await client.summary(recordingID: recording.id)
            } catch let error as MinutesCloudError where error.status == 404 {
                summary = nil
            }
        }
        let id = ULID.generate()
        let directory = audioRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let download = directory.appendingPathComponent("cloud_audio.download")
            try await client.downloadAudio(recordingID: recording.id, to: download)
            // AVAudioFile は拡張子で読み方を決めるので、中身に合う名前にしてから読む
            let source = directory.appendingPathComponent("cloud_audio." + audioExtension(of: download))
            try FileManager.default.moveItem(at: download, to: source)
            let samples: [Float]
            do { samples = try AudioFileTools.loadMono16k(source) } catch { throw ImportError.unreadableAudio(error.localizedDescription) }
            let duration = Double(samples.count) / AudioFileTools.sttSampleRate
            guard duration >= AudioImport.minimumDuration else { throw ImportError.tooShort }
            // 外部の録音の取り込みと同じ 2 つのファイル（文字起こし用の WAV と、保存・再生用の m4a）
            try AudioFileTools.writeWAV(samples: samples, sampleRate: AudioFileTools.sttSampleRate,
                                        to: directory.appendingPathComponent(RecordingSession.systemSTTName))
            try AudioFileTools.writeAAC(samples: samples, sampleRate: AudioFileTools.sttSampleRate,
                                        to: directory.appendingPathComponent(RecordingSession.systemArchiveName), bitrate: AudioImport.archiveBitrate)
            try FileManager.default.removeItem(at: source)

            let encoder = JSONCoding.encoder()
            try encoder.encode(document).write(to: directory.appendingPathComponent(PostProcessPipeline.cloudTranscriptArtifact), options: .atomic)
            if let summary {
                try encoder.encode(summary).write(to: directory.appendingPathComponent(PostProcessPipeline.cloudSummaryArtifact), options: .atomic)
            }

            let startedAt = recording.startedAt ?? document.meeting.startedAt ?? recording.createdAt ?? Date()
            // サーバーは会議の言語で要約を書く。言語を入れておかないと、後処理が自分で決め直す
            let language = MeetingLanguage(code: document.language) ?? MeetingLanguage(code: recording.detectedLanguage) ?? .ja
            let record = MeetingRecord(
                id: id,
                title: title(document: document, recording: recording, platform: platform),
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(duration),
                platform: platform,
                privacyMode: .cloudOk,
                status: .finalizing,
                audioDir: directory.path,
                // 録音の原点と会議の開始を同じにする（外部の録音の取り込みと同じ）
                recordingStartedAt: startedAt,
                language: language,
                summaryLanguage: language,
                cloudRecordingId: recording.id,
                cloudProcessed: true
            )
            guard let created = try store.createCloudMeeting(record) else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            return created
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 題名は文字起こしの会議の名前（iPhone で直した名前はここにも書かれる）、なければ録音の名前。どちらもなければ録った機器の名前。
    static func title(document: TranscriptDocument, recording: MinutesCloudRecording, platform: MeetingPlatform) -> String {
        for candidate in [document.meeting.title, recording.title] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { return trimmed }
        }
        return platform == .watch ? "Apple Watch の録音" : "iPhone の録音"
    }

    /// 音声の種類を先頭の数バイトから決める。iPhone・Watch の録音は ADTS の AAC（.aac）。
    static func audioExtension(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "aac" }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 12)) ?? Data())
        if head.count >= 8, head[4..<8].elementsEqual("ftyp".utf8) { return "m4a" }
        if head.starts(with: "RIFF".utf8) { return "wav" }
        if head.starts(with: "fLaC".utf8) { return "flac" }
        if head.starts(with: "ID3".utf8) { return "mp3" }
        return "aac"
    }
}
