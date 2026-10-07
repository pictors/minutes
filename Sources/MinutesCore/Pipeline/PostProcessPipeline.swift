import Foundation
import Synchronization

/// 後処理の各ステップ（SPEC §8）。pipeline_runs に記録し、失敗ステップから再開できる。
public enum PipelineStep: String, CaseIterable, Sendable {
    case finalizeAudio = "finalize_audio"
    case transcribeFinal = "transcribe_final"
    case mergeTracks = "merge_tracks"
    case resolveSpeakers = "resolve_speakers"
    case summarize
    case store
    case export
    case notify

    /// 失敗したら会議全体を failed にするステップ。要約・書き出し・通知は本文の保存後なので、失敗しても会議は done にして個別に再実行する。
    public var isRequired: Bool {
        switch self {
        case .summarize, .export, .notify: false
        default: true
        }
    }

    public var title: String {
        switch self {
        case .finalizeAudio: "音声の確認"
        case .transcribeFinal: "文字起こし"
        case .mergeTracks: "トラックの統合"
        case .resolveSpeakers: "話者の対応付け"
        case .summarize: "要約"
        case .store: "保存"
        case .export: "書き出し・同期"
        case .notify: "通知"
        }
    }
}

public enum PipelineError: Error, LocalizedError {
    case meetingNotFound(String)
    case noAudio(String)
    case artifactMissing(String)
    case summaryUnavailable
    case summaryAlreadyRunning
    case localOnlyExport
    case staleSummary

    public var errorDescription: String? {
        switch self {
        case let .meetingNotFound(id): return "会議 \(id) が見つかりません"
        case let .noAudio(id): return "会議 \(id) の音声ファイルがありません"
        case let .artifactMissing(name): return "中間成果物 \(name) がありません（前のステップからやり直してください）"
        case .summaryUnavailable: return "要約にはクラウド OK の会議、確定文字起こし、要約プロバイダの設定が必要です"
        case .summaryAlreadyRunning: return "この会議は要約中です"
        case .localOnlyExport: return "ローカル専用の会議は書き出し・同期できません"
        case .staleSummary: return "要約中に本文が変更されました。要約を再実行してください"
        }
    }
}

/// パイプラインに差し込む実装（差し替え可能、SPEC §3.3）。
public struct PipelineProviders: Sendable {
    /// cloud_ok の会議で使う final プロバイダ（決定: ElevenLabs Scribe v2）。nil ならローカルのみ。
    public var cloud: (any BatchTranscriber)?
    /// local_only の会議、およびクラウド失敗時のフォールバック。
    public var local: any BatchTranscriber
    /// nil なら summarize をスキップする。
    public var summarizer: (any Summarizing)?
    public var exportDirectory: URL
    public var syncTargets: [any SyncTarget]
    public var learnKeyterms: Bool
    /// 英語の会議の要約の言語（設定。2026-10-07 決定: 既定は英語）。会議の言語が決まったときに会議ごとに記録する。
    public var englishSummaryLanguage: MeetingLanguage
    public var notify: (@Sendable (MeetingRecord, NotesRecord?) -> Void)?
    public var onProgress: (@Sendable (String, PipelineStep, String) -> Void)?

    public init(cloud: (any BatchTranscriber)?, local: any BatchTranscriber, summarizer: (any Summarizing)?, exportDirectory: URL, syncTargets: [any SyncTarget] = [], learnKeyterms: Bool = true, englishSummaryLanguage: MeetingLanguage = .en, notify: (@Sendable (MeetingRecord, NotesRecord?) -> Void)? = nil, onProgress: (@Sendable (String, PipelineStep, String) -> Void)? = nil) {
        self.cloud = cloud
        self.local = local
        self.summarizer = summarizer
        self.exportDirectory = exportDirectory
        self.syncTargets = syncTargets
        self.learnKeyterms = learnKeyterms
        self.englishSummaryLanguage = englishSummaryLanguage
        self.notify = notify
        self.onProgress = onProgress
    }
}

/// マージ済みトランスクリプト（中間成果物 merged.json）。
public struct MergedTranscript: Codable, Sendable, Equatable {
    public var speakers: [TranscriptDocument.Speaker]
    public var segments: [TranscriptDocument.Segment]
    public var providerDescription: String
}

public struct PipelineOutcome: Sendable, Equatable {
    public var meetingId: String
    public var executed: [PipelineStep]
    public var skipped: [PipelineStep]
    public var exportPath: String?
    /// 任意ステップ（要約・書き出し・通知）の失敗。会議は done になり、画面から個別にやり直せる。
    public var warnings: [PipelineStep: String] = [:]
}

public final class PostProcessPipeline: Sendable {
    public static let systemArtifact = "final_system.json"
    public static let micArtifact = "final_mic.json"
    public static let mergedArtifact = "merged.json"
    public static let summaryArtifact = "summary.json"

    public let store: Store
    public let providers: PipelineProviders
    private let summaryMeetings = Mutex<Set<String>>([])

    public init(store: Store, providers: PipelineProviders) {
        self.store = store
        self.providers = providers
    }

    /// 既存会議の要約だけを更新する。編集済み本文と安定した DB id を使い、音声は不要。
    /// 旧プロバイダの要約や、キーなしでスキップした会議もこの経路で移行できる。
    public func regenerateSummary(meetingId: String) async throws {
        let lease = try store.acquireMeetingLease(meetingId)
        defer { withExtendedLifetime(lease) {} }
        guard summaryMeetings.withLock({ $0.insert(meetingId).inserted }) else { throw PipelineError.summaryAlreadyRunning }
        defer { summaryMeetings.withLock { _ = $0.remove(meetingId) } }
        guard let meeting = try store.meeting(id: meetingId) else { throw PipelineError.meetingNotFound(meetingId) }
        let segments = try store.segments(meetingId: meetingId, source: .final)
        guard meeting.privacy == .cloudOk, meeting.meetingStatus == .done, !segments.isEmpty,
              let summarizer = providers.summarizer else { throw PipelineError.summaryUnavailable }
        let input = try summaryInput(meeting)
        // 話者をすべて背景の声として除外すると、渡す本文がなくなる
        guard !input.segments.isEmpty else { throw PipelineError.summaryUnavailable }
        let run = try store.recordRun(meetingId: meetingId, step: PipelineStep.summarize.rawValue, status: .running)
        do {
            let summary = try await summarizer.summarize(input)
            guard let current = try store.meeting(id: meetingId), current.privacy == .cloudOk else { throw PipelineError.summaryUnavailable }
            let inputFingerprint = try PipelineFingerprint.encoded(input)
            guard try PipelineFingerprint.encoded(summaryInput(current)) == inputFingerprint else { throw PipelineError.staleSummary }
            let artifact = SummaryArtifact(summary: summary, model: summarizer.modelDescription, inputFingerprint: inputFingerprint)
            try store.invalidateRuns(meetingId: meetingId, steps: [.store, .export])
            if let directory = current.audioDirectoryURL {
                try JSONCoding.encoder().encode(artifact).write(to: directory.appendingPathComponent(Self.summaryArtifact), options: .atomic)
            }
            try saveSummary(artifact, meeting: current)
            let fingerprint = try current.audioDirectoryURL.map { try stepFingerprint(.summarize, meeting: current, directory: $0) }
            try store.finishRun(run, status: .ok, provider: artifact.model, fingerprint: fingerprint)
        } catch {
            _ = try? store.finishRun(run, status: .failed, error: error.localizedDescription)
            throw error
        }
        _ = try await export(meeting: meeting)
    }

    /// force / 入力変更は依存する下流すべてを、処理前に永続的に無効化する。
    @discardableResult
    public func run(meetingId: String, force: Set<PipelineStep> = []) async throws -> PipelineOutcome {
        let lease = try store.acquireMeetingLease(meetingId)
        let outcome = try await run(meetingId: meetingId, force: force, lease: lease)
        // CLI で完了した場合も、アプリ側の待機・失敗依頼を残さない。
        try store.finishPostProcessing(meetingId: meetingId, lease: lease)
        return outcome
    }

    /// 永続ジョブの claim とパイプライン実行の間で、会議ロックを解放しない。
    @discardableResult
    func run(meetingId: String, force: Set<PipelineStep> = [], lease: MeetingLease) async throws -> PipelineOutcome {
        try store.validateMeetingLease(lease, meetingId: meetingId)
        defer { withExtendedLifetime(lease) {} }
        guard var meeting = try store.meeting(id: meetingId) else { throw PipelineError.meetingNotFound(meetingId) }
        guard let directory = meeting.audioDirectoryURL else { throw PipelineError.noAudio(meetingId) }
        var completed = false
        defer { if !completed { try? store.setMeetingStatus(id: meetingId, status: .failed) } }
        if meeting.meetingStatus != .finalizing {
            try store.setMeetingStatus(id: meetingId, status: .finalizing)
        }
        if let first = PipelineStep.allCases.first(where: { force.contains($0) }) {
            try store.invalidateRuns(meetingId: meetingId, steps: downstream(first))
        }
        var executed: [PipelineStep] = []
        var skipped: [PipelineStep] = []
        var exportPath: String?
        var warnings: [PipelineStep: String] = [:]

        for step in PipelineStep.allCases {
            try Task.checkCancellation()
            guard let current = try store.meeting(id: meetingId) else { throw PipelineError.meetingNotFound(meetingId) }
            meeting = current
            let fingerprint = try stepFingerprint(step, meeting: meeting, directory: directory)
            if let latest = try store.latestRun(meetingId: meetingId, step: step.rawValue),
               latest.runStatus == .ok, latest.fingerprint == fingerprint, step != .notify {
                skipped.append(step)
                continue
            }
            try store.invalidateRuns(meetingId: meetingId, steps: downstream(step))
            let run = try store.recordRun(meetingId: meetingId, step: step.rawValue, status: .running)
            providers.onProgress?(meetingId, step, "開始")
            do {
                try clearArtifacts(for: step, directory: directory)
                let provider: String?
                switch step {
                case .finalizeAudio: provider = try finalizeAudio(meeting: meeting, directory: directory)
                case .transcribeFinal: provider = try await transcribeFinal(meeting: meeting, directory: directory)
                case .mergeTracks: provider = try mergeTracks(meeting: meeting, directory: directory)
                case .resolveSpeakers: provider = try resolveSpeakers(meeting: meeting, directory: directory)
                case .summarize: provider = try await summarize(meeting: meeting, directory: directory)
                case .store: provider = try storeResults(meeting: meeting, directory: directory)
                case .export:
                    let result = try await export(meeting: meeting)
                    exportPath = result.path
                    provider = result.provider
                case .notify:
                    let notes = try store.notes(meetingId: meetingId)
                    providers.notify?(meeting, notes)
                    provider = nil
                }
                let savedFingerprint = try stepFingerprint(step, meeting: try store.meeting(id: meetingId) ?? meeting, directory: directory)
                try store.finishRun(run, status: .ok, provider: provider, fingerprint: savedFingerprint)
                executed.append(step)
                providers.onProgress?(meetingId, step, "完了")
            } catch {
                _ = try? store.finishRun(run, status: .failed, error: error.localizedDescription)
                providers.onProgress?(meetingId, step, "失敗: \(error.localizedDescription)")
                if step.isRequired || error is CancellationError {
                    _ = try? store.setMeetingStatus(id: meetingId, status: .failed)
                    throw error
                }
                // 本文は保存済み。要約・書き出しの失敗は警告として残し、後続ステップと完了扱いを続ける。
                warnings[step] = error.localizedDescription
            }
        }
        try store.setMeetingStatus(id: meetingId, status: .done)
        completed = true
        return PipelineOutcome(meetingId: meetingId, executed: executed, skipped: skipped, exportPath: exportPath, warnings: warnings)
    }

    /// ローカル専用に切り替えたときなどに、書き出しフォルダと同期先のコピーを消す。削除したパスを返す。
    public func removeExportedFiles(meetingId: String) async throws -> [String] {
        let lease = try store.acquireMeetingLease(meetingId)
        defer { withExtendedLifetime(lease) {} }
        guard let meeting = try store.meeting(id: meetingId) else { throw PipelineError.meetingNotFound(meetingId) }
        var removed = try MeetingExporter.removeFolders(for: meeting, in: providers.exportDirectory)
        for target in providers.syncTargets {
            removed += try await target.remove(meeting: meeting)
        }
        return removed
    }

    // MARK: - Steps

    /// 保存済み本文・話者・メモから書き出しと同期だけを更新する。音声・STT・要約には依存しない。
    @discardableResult
    public func refreshExport(meetingId: String) async throws -> String? {
        let lease = try store.acquireMeetingLease(meetingId)
        defer { withExtendedLifetime(lease) {} }
        guard let meeting = try store.meeting(id: meetingId) else { throw PipelineError.meetingNotFound(meetingId) }
        guard meeting.meetingStatus != .recording, meeting.meetingStatus != .finalizing else { throw StoreError.meetingBusy(meetingId) }
        let run = try store.recordRun(meetingId: meetingId, step: PipelineStep.export.rawValue, status: .running)
        do {
            let result = try await export(meeting: meeting)
            let current = try store.meeting(id: meetingId) ?? meeting
            try store.finishRun(run, status: .ok, provider: result.provider, fingerprint: exportFingerprint(current))
            return result.path
        } catch {
            try? store.finishRun(run, status: .failed, error: error.localizedDescription)
            throw error
        }
    }

    /// 1. 両トラックの STT 用 WAV が揃っているか確認する（欠けていればアーカイブから作る）。
    func finalizeAudio(meeting: MeetingRecord, directory: URL) throws -> String? {
        let manifestURL = directory.appendingPathComponent(RecordingManifest.fileName)
        let manifest = FileManager.default.fileExists(atPath: manifestURL.path)
            ? try RecordingManifest.read(from: directory) : nil
        let pairs = [
            (RecordingSession.systemArchiveName, RecordingSession.systemSTTName),
            (RecordingSession.micArchiveName, RecordingSession.micSTTName),
        ]
        let expectedURL = directory.appendingPathComponent("expected-tracks.json")
        let expected = FileManager.default.fileExists(atPath: expectedURL.path)
            ? try JSONCoding.decoder().decode([String].self, from: Data(contentsOf: expectedURL)) : []
        var available = 0
        for (archive, stt) in pairs {
            let sttURL = directory.appendingPathComponent(stt)
            let archiveURL = directory.appendingPathComponent(archive)
            let exists = FileManager.default.fileExists(atPath: sttURL.path) || FileManager.default.fileExists(atPath: archiveURL.path)
            let track = stt == RecordingSession.systemSTTName ? "system" : "mic"
            guard exists || expected.contains(track) else { continue }
            if (try? AudioFileTools.duration(of: sttURL)) ?? 0 <= 0 {
                _ = try InterruptedWAVRecovery.repair(sttURL)
            }
            if let duration = try? AudioFileTools.duration(of: sttURL), duration > 0 {
                if let stats = manifest?.tracks[track] {
                    try RecordingAudioValidation.validate(stats: stats, fileDuration: duration, recordingDuration: manifest?.durationSeconds)
                }
                available += 1
            } else if let duration = try? AudioFileTools.duration(of: archiveURL), duration > 0 {
                let samples = try AudioFileTools.loadMono16k(archiveURL)
                guard !samples.isEmpty else { throw PipelineError.noAudio(track) }
                try AudioFileTools.writeWAV(samples: samples, sampleRate: AudioFileTools.sttSampleRate, to: sttURL)
                if let stats = manifest?.tracks[track] {
                    try RecordingAudioValidation.validate(stats: stats, fileDuration: Double(samples.count) / AudioFileTools.sttSampleRate, recordingDuration: manifest?.durationSeconds)
                }
                available += 1
            } else {
                throw PipelineError.noAudio("\(meeting.id) / \(track)（破損または空の音声）")
            }
        }
        guard available > 0 else { throw PipelineError.noAudio(meeting.id) }
        return Self.interruptionNote(manifest)
    }

    /// 録音中の途切れ（無音で補った時間）を pipeline_runs に残す（SPEC §4.3）。
    /// ふだんの小さな欠落（合計 5 秒未満）は書かない。途切れたまま終わって末尾を埋めた場合は短くても書く。
    static func interruptionNote(_ manifest: RecordingManifest?) -> String? {
        guard let manifest else { return nil }
        let notes = manifest.tracks.keys.sorted().compactMap { track -> String? in
            guard let stats = manifest.tracks[track], stats.gapSeconds >= 5 || (stats.tailPaddingSeconds ?? 0) > 0 else { return nil }
            return String(format: "%@: 途切れ %.0f 秒を無音で補完", track, stats.gapSeconds)
        }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    /// 2. privacy_mode に従ってプロバイダを選び、トラックごとに final を作る。クラウド失敗時は Local にフォールバック。
    /// system と mic は同時に送る（G3。順に送ると会議の終了から議事録までが 2 本分かかる）。
    func transcribeFinal(meeting: MeetingRecord, directory: URL) async throws -> String? {
        var keyterms = try store.keyterms()
        for attendee in meeting.attendees where !keyterms.contains(attendee.name) { keyterms.append(attendee.name) }
        let language = try resolveLanguage(meeting)
        let job = TrackTranscriptionJob(meeting: meeting, directory: directory, keyterms: keyterms, language: language,
                                        manifest: try? RecordingManifest.read(from: directory))
        async let system = transcribeTrack(job, track: "system", sttName: RecordingSession.systemSTTName, artifact: PostProcessPipeline.systemArtifact, diarize: true)
        async let mic = transcribeTrack(job, track: "mic", sttName: RecordingSession.micSTTName, artifact: PostProcessPipeline.micArtifact, diarize: false)
        let notes = try await [system, mic].compactMap { $0 }
        return ([language == .ja ? nil : "language: \(language.rawValue)\(meeting.language == nil ? " (detected)" : "")"].compactMap { $0 } + notes).joined(separator: "; ")
    }

    /// 文字起こしの言語を決める。録音中に選んだ・会議の詳細で変えた言語があればそれ、なければ（自動）
    /// 日本語のライブ字幕の文字の種類から判定する（判定できなければ日本語）。要約の言語がまだなければ設定から決める。
    func resolveLanguage(_ meeting: MeetingRecord) throws -> MeetingLanguage {
        var detected = meeting.languageDetected
        let language: MeetingLanguage
        if let chosen = MeetingLanguage(code: meeting.language) {
            language = chosen
        } else {
            let live = try store.segments(meetingId: meeting.id, source: .live).map(\.text)
            language = MeetingLanguageDetector.detect(live) ?? .ja
            detected = true
        }
        let summary = MeetingLanguage(code: meeting.summaryLanguage) ?? (language == .en ? providers.englishSummaryLanguage : .ja)
        if meeting.language != language.rawValue || meeting.languageDetected != detected || meeting.summaryLanguage != summary.rawValue {
            try store.setMeetingLanguage(id: meeting.id, language: language, detected: detected, summaryLanguage: summary)
        }
        return language
    }

    private struct TrackTranscriptionJob: Sendable {
        var meeting: MeetingRecord
        var directory: URL
        var keyterms: [String]
        var language: MeetingLanguage
        var manifest: RecordingManifest?
    }

    /// 1 トラック分の final を作って成果物に書き、pipeline_runs に残す説明を返す（音声がなければ nil）。
    private func transcribeTrack(_ job: TrackTranscriptionJob, track: String, sttName: String, artifact: String, diarize: Bool) async throws -> String? {
        let meeting = job.meeting
        var audioURL = job.directory.appendingPathComponent(sttName)
        let artifactURL = job.directory.appendingPathComponent(artifact)
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        if FileManager.default.fileExists(atPath: artifactURL.path) { return "\(track): cached" }
        // 一度も音声が届かず、停止時に全体を無音で作ったトラックは送らない（無音への幻覚と送信費を避ける。SPEC §4.3）。
        if let stats = job.manifest?.tracks[track], stats.receivedFrames == 0, (stats.tailPaddingSeconds ?? 0) > 0 {
            return "\(track): skipped (録音中に音声が届かなかった)"
        }
        var timeOffset = 0.0
        var temporaryDirectory: URL?
        defer { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
        // 録音準備中（会議開始前）の自分の声は会議の一部ではない。送信前に切り落とし、時刻は録音原点に戻す。
        let micOffset = meeting.meetingStartOffsetSeconds
        if track == TrackMerger.micTrack, micOffset >= 1 {
            let samples = try AudioFileTools.loadMono16k(audioURL, from: micOffset)
            guard samples.count >= Int(AudioFileTools.sttSampleRate) else { return "\(track): skipped (会議開始後の音声なし)" }
            let trimDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-trim-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: trimDirectory, withIntermediateDirectories: true)
            let trimmed = trimDirectory.appendingPathComponent(sttName)
            try AudioFileTools.writeWAV(samples: samples, sampleRate: AudioFileTools.sttSampleRate, to: trimmed)
            temporaryDirectory = trimDirectory
            audioURL = trimmed
            timeOffset = micOffset
        }
        let request = TranscriptionRequest(audioURL: audioURL, language: job.language.rawValue, diarize: diarize, keyterms: job.keyterms, knownSpeakers: [])
        var result: TranscriptionResult
        let note: String
        guard let current = try store.meeting(id: meeting.id) else { throw PipelineError.meetingNotFound(meeting.id) }
        try Task.checkCancellation()
        if current.privacy == .localOnly || providers.cloud == nil {
            result = try await providers.local.transcribe(request)
            note = "\(track): \(providers.local.id)"
        } else if let cloud = providers.cloud {
            do {
                result = try await cloud.transcribe(request)
                note = "\(track): \(cloud.id)" + (UploadTiming.note(from: result.providerMeta).map { " (\($0))" } ?? "")
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                Log.transcription.error("cloud transcription failed, falling back to local: \(error.localizedDescription, privacy: .public)")
                providers.onProgress?(meeting.id, .transcribeFinal, "\(cloud.id) 失敗 → \(providers.local.id) にフォールバック")
                result = try await providers.local.transcribe(request)
                note = "\(track): \(providers.local.id) (fallback: \(Log.preview(error.localizedDescription, limit: 80)))"
            }
        } else {
            throw PipelineError.noAudio(meeting.id)
        }
        result.providerMeta["track"] = track
        if timeOffset > 0 {
            result = result.shifted(by: timeOffset)
            result.providerMeta["start_offset_seconds"] = String(format: "%.3f", timeOffset)
        }
        try JSONCoding.encoder().encode(result).write(to: artifactURL, options: .atomic)
        return note
    }

    /// 3. mic（me）と system を時刻でマージする。
    func mergeTracks(meeting: MeetingRecord, directory: URL) throws -> String? {
        let decoder = JSONCoding.decoder()
        func load(_ name: String) throws -> TranscriptionResult? {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try decoder.decode(TranscriptionResult.self, from: Data(contentsOf: url))
        }
        let system = try load(PostProcessPipeline.systemArtifact)
        let mic = try load(PostProcessPipeline.micArtifact)
        guard system != nil || mic != nil else { throw PipelineError.artifactMissing(PostProcessPipeline.systemArtifact) }
        let output = TrackMerger.merge(TrackMerger.Input(system: system, mic: mic))
        let providerDescription = [system?.providerMeta["provider"], mic?.providerMeta["provider"]].compactMap { $0 }.first ?? "unknown"
        let merged = MergedTranscript(speakers: output.speakers, segments: output.segments, providerDescription: providerDescription)
        try JSONCoding.encoder().encode(merged).write(to: directory.appendingPathComponent(PostProcessPipeline.mergedArtifact), options: .atomic)
        return nil
    }

    /// 4. クラスタ → 人の対応付け（SPEC §5.4）。Phase 1 は人間の割当を引き継ぐだけ（DOM / 声の登録は Phase 3）。
    /// 相手側の話者の音量もここで測る（背景の声の候補）。
    func resolveSpeakers(meeting: MeetingRecord, directory: URL) throws -> String? {
        let merged = try loadMerged(directory)
        let records = merged.segments.map { segment in
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: segment.tStart, tEnd: segment.tEnd, clusterLabel: segment.speaker, text: segment.text, confidence: segment.confidence)
        }
        let speakers = merged.speakers.map { SpeakerRecord(meetingId: meeting.id, clusterLabel: $0.label, displayName: $0.name) }
        let hasEdits = try store.segments(meetingId: meeting.id, source: .final).contains { $0.originalText == nil || $0.text != $0.originalText }
        try store.saveTranscript(meetingId: meeting.id, segments: records, speakers: speakers)
        measureSpeakerLevels(meeting: meeting, directory: directory)
        if hasEdits { return "編集済み本文を維持（再認識結果は履歴に保存）" }
        let existing = try store.speakers(meetingId: meeting.id)
        let carried = merged.speakers.filter { speaker in existing.contains { $0.clusterLabel == speaker.label && $0.displayName != nil } }
        return carried.isEmpty ? "manual" : "manual (carried \(carried.count) assignments)"
    }

    /// 相手側の話者ごとの音量を測って保存する（背景の声の候補、`BackgroundVoices`）。音声を消す前のここで測る。
    /// 保存した本文（編集を残した世代を含む）の区間で測る。測れなくても本文の保存は止めない。
    func measureSpeakerLevels(meeting: MeetingRecord, directory: URL) {
        do {
            try BackgroundVoices.measureAndStore(store: store, meetingId: meeting.id, audioDirectory: directory)
        } catch {
            Log.audio.error("speaker levels failed for \(meeting.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// DB の編集済み本文と永続 ID を全要約経路で使う。
    func summaryInput(_ meeting: MeetingRecord) throws -> SummaryInput {
        try store.summaryInput(meetingId: meeting.id)
    }

    /// 5. 要約（local_only ではスキップ）。成果物にモデル・入力ハッシュを保存する。
    func summarize(meeting: MeetingRecord, directory: URL) async throws -> String? {
        guard let current = try store.meeting(id: meeting.id), current.privacy == .cloudOk else { return "skipped (local_only)" }
        guard let summarizer = providers.summarizer else { return "skipped (no summarizer)" }
        let input = try summaryInput(current)
        guard !input.segments.isEmpty else { return "skipped (empty transcript)" }
        let fingerprint = try PipelineFingerprint.encoded(input)
        let summary = try await summarizer.summarize(input)
        guard let latest = try store.meeting(id: meeting.id), latest.privacy == .cloudOk else { throw PipelineError.summaryUnavailable }
        guard try PipelineFingerprint.encoded(summaryInput(latest)) == fingerprint else { throw PipelineError.staleSummary }
        let artifact = SummaryArtifact(summary: summary, model: summarizer.modelDescription, inputFingerprint: fingerprint)
        try JSONCoding.encoder().encode(artifact).write(to: directory.appendingPathComponent(Self.summaryArtifact), options: .atomic)
        return artifact.model
    }

    /// 6. 本文は resolve_speakers で確定済み。store の再試行で編集を上書きしない。
    func storeResults(meeting: MeetingRecord, directory: URL) throws -> String? {
        let url = directory.appendingPathComponent(Self.summaryArtifact)
        if meeting.privacy == .cloudOk, FileManager.default.fileExists(atPath: url.path) {
            let artifact = try JSONCoding.decoder().decode(SummaryArtifact.self, from: Data(contentsOf: url))
            try saveSummary(artifact, meeting: meeting)
        }
        return "saved"
    }

    func saveSummary(_ artifact: SummaryArtifact, meeting: MeetingRecord) throws {
        guard try PipelineFingerprint.encoded(summaryInput(meeting)) == artifact.inputFingerprint else { throw PipelineError.staleSummary }
        try store.saveGeneratedSummary(meetingId: meeting.id, summary: artifact.summary, model: artifact.model, inputFingerprint: artifact.inputFingerprint)
        if providers.learnKeyterms { try store.addKeyterms(artifact.summary.keytermsLearned, source: "learned") }
    }

    /// 7. 会議フォルダを生成し、SyncTarget へ送る。同期失敗は pending として残す（再送は retryPendingExports）。
    func export(meeting: MeetingRecord) async throws -> (path: String?, provider: String) {
        guard try store.meeting(id: meeting.id)?.privacy == .cloudOk else { return (nil, "skipped (local_only)") }
        let folder = try writeExportFolder(meetingId: meeting.id)
        var statuses: [String] = ["local: ok"]
        for target in providers.syncTargets {
            guard try store.meeting(id: meeting.id)?.privacy == .cloudOk else { break }
            do {
                let receipt = try await target.upload(folder: folder.url, manifest: folder.manifest)
                try store.logExport(meetingId: meeting.id, target: target.id, status: .ok, checksum: receipt.checksum)
                statuses.append("\(target.id): ok")
            } catch {
                try store.logExport(meetingId: meeting.id, target: target.id, status: .pending, checksum: folder.manifest.checksum)
                statuses.append("\(target.id): pending (\(Log.preview(error.localizedDescription, limit: 60)))")
            }
        }
        try store.logExport(meetingId: meeting.id, target: "local_export", status: .ok, checksum: folder.manifest.checksum)
        return (folder.url.path, statuses.joined(separator: "; "))
    }

    /// DB の内容から書き出しフォルダを（再）生成する。
    public func writeExportFolder(meetingId: String) throws -> (url: URL, manifest: ExportManifest) {
        try store.withCloudExport(meetingId: meetingId) { input in
            let bundle = try MeetingExporter.build(input)
            try FileManager.default.createDirectory(at: providers.exportDirectory, withIntermediateDirectories: true)
            let url = try bundle.write(into: providers.exportDirectory)
            // タイトル変更で名前が変わった旧フォルダ（同じ id 末尾）を残さない
            _ = try? MeetingExporter.removeFolders(for: input.meeting, in: providers.exportDirectory, except: bundle.folderName)
            return (url, bundle.manifest)
        }
    }

    /// pending の同期を再送する（起動時と 10 分ごと、SPEC §9.1）。
    public func retryPendingExports() async -> [String] {
        var report: [String] = []
        guard let pending = try? store.pendingExports(), !pending.isEmpty else { return report }
        for entry in pending {
            guard let target = providers.syncTargets.first(where: { $0.id == entry.target }) else { continue }
            do {
                let lease = try store.acquireMeetingLease(entry.meetingId)
                defer { withExtendedLifetime(lease) {} }
                guard try store.meeting(id: entry.meetingId)?.privacy == .cloudOk else { continue }
                let folder = try writeExportFolder(meetingId: entry.meetingId)
                guard try store.meeting(id: entry.meetingId)?.privacy == .cloudOk else { continue }
                let receipt = try await target.upload(folder: folder.url, manifest: folder.manifest)
                try store.logExport(meetingId: entry.meetingId, target: target.id, status: .ok, checksum: receipt.checksum)
                report.append("\(entry.meetingId) → \(target.id): ok")
            } catch StoreError.meetingBusy {
                continue
            } catch {
                _ = try? store.logExport(meetingId: entry.meetingId, target: entry.target, status: .pending, checksum: entry.checksum)
                report.append("\(entry.meetingId) → \(entry.target): still pending (\(error.localizedDescription))")
            }
        }
        return report
    }

    /// 強制再実行するステップの中間成果物を消す（ステップ内のキャッシュ判定を無効にする）。
    func clearArtifacts(for step: PipelineStep, directory: URL) throws {
        let names: [String]
        switch step {
        case .transcribeFinal: names = [PostProcessPipeline.systemArtifact, PostProcessPipeline.micArtifact]
        case .mergeTracks: names = [PostProcessPipeline.mergedArtifact]
        case .summarize: names = [PostProcessPipeline.summaryArtifact]
        default: names = []
        }
        for name in names {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func downstream(_ step: PipelineStep) -> [PipelineStep] {
        Array(PipelineStep.allCases.drop(while: { $0 != step }))
    }

    /// 自ステップの成果物も含め、ファイル消失・改変を成功扱いにしない。
    func stepFingerprint(_ step: PipelineStep, meeting: MeetingRecord, directory: URL) throws -> String {
        var values = ["pipeline-v2", step.rawValue]
        func files(_ names: [String]) throws { for name in names { values.append(try PipelineFingerprint.file(directory.appendingPathComponent(name))) } }
        switch step {
        case .finalizeAudio:
            values.append("audio-quality-v1")
            try files([RecordingSession.systemArchiveName, RecordingSession.micArchiveName, RecordingSession.systemSTTName, RecordingSession.micSTTName, "expected-tracks.json", RecordingManifest.fileName])
        case .transcribeFinal:
            try files([RecordingSession.systemSTTName, RecordingSession.micSTTName, Self.systemArtifact, Self.micArtifact])
            values += [meeting.privacyMode, providers.local.cacheIdentity, providers.cloud?.cacheIdentity ?? "none", meeting.attendeesJson ?? "", try PipelineFingerprint.encoded(store.manualKeyterms()), String(format: "offset=%.3f", meeting.meetingStartOffsetSeconds)]
            // 日本語（言語を持つ前の会議を含む）は値を足さない。足すと既存の会議がすべて文字起こしし直しになる
            if meeting.meetingLanguage != .ja { values.append("language=\(meeting.meetingLanguage.rawValue)") }
        case .mergeTracks:
            try files([Self.systemArtifact, Self.micArtifact, Self.mergedArtifact])
        case .resolveSpeakers:
            try files([Self.mergedArtifact])
        case .summarize:
            values += [meeting.privacyMode, providers.summarizer?.cacheIdentity ?? "none", try PipelineFingerprint.encoded(summaryInput(meeting))]
            try files([Self.summaryArtifact])
        case .store:
            values += [meeting.privacyMode, try PipelineFingerprint.encoded(summaryInput(meeting))]
            try files([Self.summaryArtifact])
        case .export:
            return try exportFingerprint(meeting)
        case .notify: break
        }
        return try PipelineFingerprint.encoded(values)
    }

    private func exportFingerprint(_ meeting: MeetingRecord) throws -> String {
        var values = ["pipeline-v2", PipelineStep.export.rawValue, meeting.privacyMode,
                      try PipelineFingerprint.encoded(summaryInput(meeting)),
                      try PipelineFingerprint.encoded(store.notes(meetingId: meeting.id)), providers.exportDirectory.path]
        values += providers.syncTargets.map(\.cacheIdentity)
        if meeting.privacy == .cloudOk {
            let folder = providers.exportDirectory.appendingPathComponent(MeetingExporter.folderName(meeting: meeting))
            values.append(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) ? "exists" : "missing")
        }
        return try PipelineFingerprint.encoded(values)
    }

    func loadMerged(_ directory: URL) throws -> MergedTranscript {
        let url = directory.appendingPathComponent(PostProcessPipeline.mergedArtifact)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PipelineError.artifactMissing(PostProcessPipeline.mergedArtifact) }
        return try JSONCoding.decoder().decode(MergedTranscript.self, from: Data(contentsOf: url))
    }
}
