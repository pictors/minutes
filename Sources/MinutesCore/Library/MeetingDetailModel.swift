import Foundation
import GRDB
import Observation

/// 会議詳細画面のデータと操作。DB の変更（後処理の完了、CLI の再処理、別画面の編集）を監視で反映し、
/// View は表示だけを持つ。Store / パイプラインを直接呼ぶのはここまで。
@MainActor
@Observable
public final class MeetingDetailModel {
    public struct Snapshot: Sendable, Equatable {
        public var meeting: MeetingRecord?
        public var source: SegmentSource = .live
        public var segments: [SegmentRecord] = []
        public var speakers: [SpeakerRecord] = []
        public var notes: NotesRecord?
        public var runs: [PipelineRunRecord] = []
        public var job: PostProcessingJob?
        /// 現在の本文・話者名・タイトルのハッシュ。notes.inputFingerprint と違えば要約が古い。
        public var currentSummaryFingerprint: String?
    }

    /// 後処理の進行表示用。
    public struct StepProgress: Sendable, Equatable, Identifiable {
        public var step: PipelineStep
        public var status: PipelineRunStatus?
        public var error: String?
        public var id: String { step.rawValue }
    }

    public let meetingId: String
    public let notesDraft: UserNotesDraft
    private let store: Store
    private let pipeline: PostProcessPipeline?
    private let voicesDirectory: URL

    public private(set) var meeting: MeetingRecord?
    public private(set) var source: SegmentSource = .live
    public private(set) var segments: [SegmentRecord] = []
    public private(set) var speakers: [SpeakerRecord] = []
    public private(set) var notes: NotesRecord?
    public private(set) var runs: [PipelineRunRecord] = []
    public private(set) var job: PostProcessingJob?
    public private(set) var isSummarizing = false
    public private(set) var isExporting = false
    public private(set) var isSavingVoiceSample = false
    public private(set) var summaryStale = false
    public var error: String?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var exportRefreshPending = false
    @ObservationIgnored private var levelMeasurementStarted = false
    @ObservationIgnored private var segmentsById: [Int64: SegmentRecord] = [:]
    /// 最後に反映した内容。読み込み済みかの判定と、同じ内容の再反映（監視の初回値は直前の reload と同じ）の省略に使う。
    @ObservationIgnored private var appliedSnapshot: Snapshot?

    public init(store: Store, pipeline: PostProcessPipeline?, meetingId: String, notesDraft: UserNotesDraft, voicesDirectory: URL) {
        self.store = store
        self.pipeline = pipeline
        self.meetingId = meetingId
        self.notesDraft = notesDraft
        self.voicesDirectory = voicesDirectory
    }

    // MARK: - Observation

    /// 会議・本文・話者・メモ・処理履歴・ジョブをまとめて監視する。View の `.task` から呼び、キャンセルで止まる。
    /// 読み込み済みなら読み直さない（画面を出す前に `reload()` しておけば、最初の描画から内容が出る）。
    public func observe() async {
        observation?.cancel()
        if appliedSnapshot == nil { reload() }
        let store = store
        let meetingId = meetingId
        do {
            for try await snapshot in Self.observation(store: store, meetingId: meetingId).values(in: store.writer) {
                apply(snapshot)
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    nonisolated static func observation(store: Store, meetingId: String) -> ValueObservation<ValueReducers.Fetch<Snapshot>> {
        ValueObservation.tracking { db in try Self.fetch(db, meetingId: meetingId) }
    }

    nonisolated static func fetch(_ db: Database, meetingId: String) throws -> Snapshot {
        var snapshot = Snapshot()
        snapshot.meeting = try MeetingRecord.fetchOne(db, key: meetingId)
        let final = try Store.fetchSegments(db, meetingId: meetingId, source: .final)
        if final.isEmpty {
            snapshot.source = .live
            snapshot.segments = try Store.fetchSegments(db, meetingId: meetingId, source: .live)
        } else {
            snapshot.source = .final
            snapshot.segments = final
        }
        snapshot.speakers = try Store.fetchSpeakers(db, meetingId: meetingId)
        snapshot.notes = try NotesRecord.fetchOne(db, key: meetingId)
        snapshot.runs = try PipelineRunRecord.filter(Column("meeting_id") == meetingId).order(Column("id")).fetchAll(db)
        snapshot.job = try PostProcessingJob.fetchOne(db, key: meetingId)
        if snapshot.notes?.inputFingerprint != nil, snapshot.meeting != nil {
            snapshot.currentSummaryFingerprint = try? PipelineFingerprint.encoded(Store.fetchSummaryInput(db, meetingId: meetingId))
        }
        return snapshot
    }

    /// 同期的に読み直す（監視の初回値が来る前や、操作直後の即時反映用）。
    public func reload() {
        if let snapshot = try? store.writer.read({ db in try Self.fetch(db, meetingId: meetingId) }) {
            apply(snapshot)
        }
    }

    private func apply(_ snapshot: Snapshot) {
        guard snapshot != appliedSnapshot else { return }
        appliedSnapshot = snapshot
        meeting = snapshot.meeting
        source = snapshot.source
        segments = snapshot.segments
        segmentsById = Dictionary(uniqueKeysWithValues: snapshot.segments.compactMap { record in record.id.map { ($0, record) } })
        speakers = snapshot.speakers
        notes = snapshot.notes
        runs = snapshot.runs
        job = snapshot.job
        notesDraft.receivePersisted(snapshot.notes?.userNotesMd ?? "")
        if let saved = snapshot.notes?.inputFingerprint, let current = snapshot.currentSummaryFingerprint {
            summaryStale = saved != current
        } else {
            summaryStale = false
        }
        measureSpeakerLevelsIfNeeded()
    }

    /// 話者の音量を測る前（2026-10-05 より前）に処理した会議は、音声が残っていれば開いたときに一度だけ測る。
    /// 後処理の途中は後処理が測るので触らない。
    private func measureSpeakerLevelsIfNeeded() {
        guard !levelMeasurementStarted, source == .final, !isProcessing, let meeting, meeting.meetingStatus == .done,
              let directory = meeting.audioDirectoryURL else { return }
        let remote = speakers.filter { BackgroundVoices.isRemoteCluster($0.clusterLabel) }
        guard !remote.isEmpty, remote.allSatisfy({ $0.levelDb == nil }) else { return }
        levelMeasurementStarted = true
        let store = store
        let meetingId = meetingId
        Task.detached(priority: .utility) {
            do {
                try BackgroundVoices.measureAndStore(store: store, meetingId: meetingId, audioDirectory: directory)
            } catch {
                Log.audio.error("speaker levels failed for \(meetingId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Derived

    public var canSummarize: Bool {
        meeting?.meetingStatus == .done && meeting?.privacy == .cloudOk && !segments.isEmpty && source == .final
    }

    public var isProcessing: Bool { job?.jobStatus == .queued || job?.jobStatus == .running }

    public var finalProviderName: String? {
        runs.last(where: { $0.step == PipelineStep.transcribeFinal.rawValue && $0.runStatus == .ok })?.provider
    }

    /// 音声が保持期限で削除されている（再生・再認識ができない）。
    public var audioPurged: Bool {
        guard let meeting else { return false }
        return meeting.audioDir == nil && meeting.meetingStatus == .done
    }

    /// 完了後に失敗したままの任意ステップ（要約・書き出し）。同じステップの成功が後にあれば消える。
    public var pendingWarnings: [StepProgress] {
        guard meeting?.meetingStatus == .done else { return [] }
        return [PipelineStep.summarize, .export].compactMap { step in
            guard let latest = runs.last(where: { $0.step == step.rawValue && ($0.runStatus == .ok || $0.runStatus == .failed) }), latest.runStatus == .failed else { return nil }
            return StepProgress(step: step, status: .failed, error: latest.error)
        }
    }

    /// 後処理中の各ステップの状態（待機・実行中の会議に表示）。
    public var stepProgress: [StepProgress] {
        PipelineStep.allCases.filter { $0 != .notify }.map { step in
            let latest = runs.last { $0.step == step.rawValue && $0.runStatus != .invalidated }
            return StepProgress(step: step, status: latest?.runStatus, error: latest?.error)
        }
    }

    public func segment(id: Int64) -> SegmentRecord? {
        segmentsById[id] ?? (try? store.segment(id: id, meetingId: meetingId)) ?? nil
    }

    public func speaker(for segment: SegmentRecord) -> SpeakerRecord? {
        MeetingDetailModel.speaker(for: segment, in: speakers)
    }

    /// 発話の話者: 発話単位の変更（speaker_id）を優先し、なければクラスタの話者。
    nonisolated public static func speaker(for segment: SegmentRecord, in speakers: [SpeakerRecord]) -> SpeakerRecord? {
        segment.speaker(in: speakers)
    }

    /// 背景の声として除外した話者の発話か（本文では折りたたむ）。
    public func isExcluded(_ segment: SegmentRecord) -> Bool {
        BackgroundVoices.isExcluded(segment, speakers: speakers)
    }

    /// 背景の声の候補（話者 id → いちばん長く話した相手側の話者との差 dB）。確定した文字起こしのときだけ。
    public var backgroundCandidates: [String: Double] {
        guard source == .final else { return [:] }
        return BackgroundVoices.candidates(speakers: speakers, segments: segments)
    }

    /// 話者ごとの発言時間（詳細の「話者」カード）。
    public struct TalkTime: Sendable, Equatable, Identifiable {
        public var speaker: SpeakerRecord?
        /// 話者レコードがない発話のクラスタラベル
        public var clusterLabel: String?
        public var seconds: Double
        public var id: String { speaker?.id ?? clusterLabel ?? "?" }
    }

    public var talkTimes: [TalkTime] { MeetingDetailModel.talkTimes(segments: segments, speakers: speakers) }

    /// 発言時間の多い順（同じなら先に話した順）。話者の割当と発話単位の変更を反映する。
    nonisolated public static func talkTimes(segments: [SegmentRecord], speakers: [SpeakerRecord]) -> [TalkTime] {
        var order: [String] = []
        var totals: [String: TalkTime] = [:]
        for segment in segments {
            let speaker = speaker(for: segment, in: speakers)
            let key = speaker?.id ?? segment.clusterLabel ?? "?"
            let duration = max(0, segment.tEnd - segment.tStart)
            if totals[key] == nil {
                order.append(key)
                totals[key] = TalkTime(speaker: speaker, clusterLabel: speaker == nil ? segment.clusterLabel : nil, seconds: 0)
            }
            totals[key]?.seconds += duration
        }
        return order.enumerated()
            .compactMap { index, key in totals[key].map { (index, $0) } }
            .sorted { $0.1.seconds != $1.1.seconds ? $0.1.seconds > $1.1.seconds : $0.0 < $1.0 }
            .map(\.1)
    }

    /// 割当元のクラスタを持つ話者（"manual_" の個別割当用は除く）。
    public var clusterSpeakers: [SpeakerRecord] {
        speakers.filter { !$0.clusterLabel.hasPrefix("manual_") }
    }

    /// 再生位置に対応する発話（二分探索）。
    public func segmentId(at time: Double) -> Int64? {
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let segment = segments[mid]
            if time < segment.tStart { high = mid - 1 } else if time >= segment.tEnd { low = mid + 1 } else { return segment.id }
        }
        return nil
    }

    // MARK: - Mutations

    public func rename(_ title: String) {
        do { try store.updateMeetingTitle(id: meetingId, title: title) } catch { self.error = "タイトルを保存できません: \(error.localizedDescription)" }
        reload()
        if meeting?.meetingStatus == .done, meeting?.privacy == .cloudOk { refreshExport() }
    }

    /// 参加者を差し替える。次の文字起こしの keyterms・話者候補・書き出しに反映される（要約は「古い」表示になる）。
    public func updateAttendees(_ attendees: [Attendee]) {
        let cleaned = attendees
            .map { Attendee(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), email: $0.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().isEmpty == false ? $0.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil) }
            .filter { !$0.name.isEmpty }
        do { try store.updateMeetingAttendees(id: meetingId, attendees: cleaned) } catch { self.error = "参加者を保存できません: \(error.localizedDescription)" }
        reload()
        if meeting?.meetingStatus == .done, meeting?.privacy == .cloudOk { refreshExport() }
    }

    public func setTags(_ tags: [String]) {
        do { try store.setMeetingTags(id: meetingId, tags: tags) } catch { self.error = "タグを保存できません: \(error.localizedDescription)" }
        reload()
        if meeting?.meetingStatus == .done, meeting?.privacy == .cloudOk { refreshExport() }
    }

    public func addTag(_ tag: String) {
        let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let current = meeting?.tags, !current.contains(cleaned) else { return }
        setTags(current + [cleaned])
    }

    public func removeTag(_ tag: String) {
        guard let current = meeting?.tags else { return }
        setTags(current.filter { $0 != tag })
    }

    public func commitEdit(segmentId: Int64, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != segmentsById[segmentId]?.text else { return }
        do { try store.updateSegmentText(id: segmentId, text: cleaned) } catch { self.error = "本文を保存できません: \(error.localizedDescription)" }
        reload()
    }

    /// クラスタ全体に反映し、声のサンプルを保存する（SPEC §5.4）。
    public func assign(speaker: SpeakerRecord, personId: String?, name: String?) {
        do { try store.assignSpeaker(meetingId: meetingId, clusterLabel: speaker.clusterLabel, personId: personId, displayName: name) } catch {
            self.error = "話者を保存できません: \(error.localizedDescription)"
            return
        }
        reload()
        if let personId, let directory = meeting?.audioDirectoryURL, speaker.clusterLabel != TrackMerger.micSpeakerLabel, !speaker.clusterLabel.hasPrefix("manual_") {
            saveVoiceSample(clusterLabel: speaker.clusterLabel, personId: personId, directory: directory)
        }
        if meeting?.meetingStatus == .done { refreshExport() }
    }

    private func saveVoiceSample(clusterLabel: String, personId: String, directory: URL) {
        let audioURL = directory.appendingPathComponent(RecordingSession.systemSTTName)
        let outputURL = voicesDirectory.appendingPathComponent("\(personId)/\(meetingId).wav")
        let candidates = segments
        let store = store
        let meetingId = meetingId
        isSavingVoiceSample = true
        Task.detached(priority: .utility) {
            let outcome: Result<VoiceSample?, Error> = Result {
                try VoiceSampleExtractor.extract(clusterLabel: clusterLabel, segments: candidates, audioURL: audioURL, outputURL: outputURL, meetingId: meetingId)
            }
            await MainActor.run { [weak self] in
                self?.isSavingVoiceSample = false
                switch outcome {
                case let .success(sample):
                    if let sample {
                        do { try store.addVoiceSample(personId: personId, sample: sample) } catch { self?.error = "声のサンプルを記録できません: \(error.localizedDescription)" }
                    }
                case let .failure(error):
                    self?.error = "声のサンプルを保存できません: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 1 発話だけ別の話者にする。`speakerId == nil` で自動割当に戻す。
    public func overrideSpeaker(segmentId: Int64, speakerId: String?) {
        do { try store.overrideSegmentSpeaker(segmentId: segmentId, meetingId: meetingId, speakerId: speakerId) } catch {
            self.error = "話者を変更できません: \(error.localizedDescription)"
            return
        }
        reload()
        if meeting?.meetingStatus == .done { refreshExport() }
    }

    /// 1 発話を新しい名前（人物）に割り当てる。
    public func overrideSpeaker(segmentId: Int64, personName: String, email: String? = nil) {
        do {
            let person = try store.findOrCreatePerson(name: personName, email: email)
            let speaker = try store.findOrCreateManualSpeaker(meetingId: meetingId, personId: person.id, displayName: person.name)
            try store.overrideSegmentSpeaker(segmentId: segmentId, meetingId: meetingId, speakerId: speaker.id)
        } catch {
            self.error = "話者を変更できません: \(error.localizedDescription)"
            return
        }
        reload()
        if meeting?.meetingStatus == .done { refreshExport() }
    }

    /// 話者を背景の声として除外する（`excluded == false` で戻す）。要約は「古い」表示になり、書き出しは更新する。
    public func setExcluded(_ speaker: SpeakerRecord, excluded: Bool) {
        do { try store.setSpeakerExcluded(meetingId: meetingId, speakerId: speaker.id, excluded: excluded) } catch {
            self.error = "話者の除外を保存できません: \(error.localizedDescription)"
            return
        }
        reload()
        if meeting?.meetingStatus == .done { refreshExport() }
    }

    public func toggleAction(_ action: MinutesSummary.ActionItem, done: Bool) {
        do { _ = try store.setActionCompletion(meetingId: meetingId, action: action, done: done) } catch { self.error = "アクションを保存できません: \(error.localizedDescription)" }
        reload()
    }

    public func addAction(text: String, owner: String = "me", kind: MinutesSummary.ActionKind = .ownCommitment, due: String? = nil) {
        do { _ = try store.addManualAction(meetingId: meetingId, text: text, owner: owner, kind: kind, due: due) } catch { self.error = "アクションを追加できません: \(error.localizedDescription)" }
        reload()
    }

    public func updateAction(_ action: MinutesSummary.ActionItem, text: String? = nil, owner: String? = nil, kind: MinutesSummary.ActionKind? = nil, due: String?? = nil) {
        guard let id = action.id else { return }
        do { _ = try store.updateAction(meetingId: meetingId, actionId: id, text: text, owner: owner, kind: kind, due: due) } catch { self.error = "アクションを更新できません: \(error.localizedDescription)" }
        reload()
    }

    public func removeAction(_ action: MinutesSummary.ActionItem) {
        guard let id = action.id else { return }
        do { _ = try store.removeAction(meetingId: meetingId, actionId: id) } catch { self.error = "アクションを削除できません: \(error.localizedDescription)" }
        reload()
    }

    public func regenerateSummary() {
        guard let pipeline, !isSummarizing else { return }
        isSummarizing = true
        error = nil
        Task {
            defer { isSummarizing = false }
            do { try await pipeline.regenerateSummary(meetingId: meetingId) } catch { self.error = "要約を生成できません: \(error.localizedDescription)" }
            reload()
        }
    }

    /// 保存済みの本文・話者・メモから書き出しと同期だけを更新する。同期中の再変更は最後の内容でもう一度書き出す。
    public func refreshExport() {
        guard let pipeline else { return }
        notesDraft.flush()
        guard !notesDraft.isDirty else { return }
        exportRefreshPending = true
        guard !isExporting else { return }
        isExporting = true
        error = nil
        Task {
            defer { isExporting = false }
            repeat {
                exportRefreshPending = false
                do { try await pipeline.refreshExport(meetingId: meetingId) } catch {
                    self.error = "書き出しを更新できません: \(error.localizedDescription)"
                    break
                }
            } while exportRefreshPending
            reload()
        }
    }

    /// プライバシーを変える。cloud_ok へ切り替えたら要約を生成し、local_only へ戻すときは希望に応じて書き出しを消す。
    public func setPrivacy(_ mode: PrivacyMode, removeExports: Bool = false) {
        guard let meeting, mode != meeting.privacy else { return }
        do { try store.setPrivacyMode(id: meetingId, mode: mode) } catch {
            self.error = "プライバシーを変更できません: \(error.localizedDescription)"
            return
        }
        reload()
        switch mode {
        case .cloudOk:
            if self.meeting?.meetingStatus == .done { regenerateSummary() }
        case .localOnly:
            guard removeExports, let pipeline else { return }
            Task {
                do {
                    let removed = try await pipeline.removeExportedFiles(meetingId: meetingId)
                    if !removed.isEmpty { Log.audio.info("removed exports for \(self.meetingId, privacy: .public): \(removed.count, privacy: .public)") }
                } catch { self.error = "書き出しを削除できません: \(error.localizedDescription)" }
            }
        }
    }

    /// 書き出しフォルダ（この会議の分）。まだ書き出していなければ nil。
    public func exportFolderURL(in exportDirectory: URL) -> URL? {
        guard let meeting else { return nil }
        let url = exportDirectory.appendingPathComponent(MeetingExporter.folderName(meeting: meeting), isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func stop() {
        observation?.cancel()
        observation = nil
    }
}
