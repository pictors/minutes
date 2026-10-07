import Foundation

/// 録音開始前に分かっている会議情報（カレンダー候補または手動入力）。
public struct PendingMeetingInfo: Sendable, Equatable {
    public var title: String
    public var platform: MeetingPlatform?
    public var calendarEventId: String?
    public var calendarTitle: String?
    public var attendees: [Attendee]
    public var privacyMode: PrivacyMode
    public var calendarEndDate: Date?
    /// この録音だけ対象アプリを絞る（nil なら設定の一覧）。
    public var targetBundleIdentifiers: [String]?
    /// 会議の言語。nil は自動（ライブ字幕を `SessionConfiguration.liveLocale` で始め、会議のあとで判定する）。
    public var language: MeetingLanguage?

    public init(title: String, platform: MeetingPlatform? = nil, calendarEventId: String? = nil, calendarTitle: String? = nil, attendees: [Attendee] = [], privacyMode: PrivacyMode = .cloudOk, calendarEndDate: Date? = nil, targetBundleIdentifiers: [String]? = nil, language: MeetingLanguage? = nil) {
        self.title = title
        self.platform = platform
        self.calendarEventId = calendarEventId
        self.calendarTitle = calendarTitle
        self.attendees = attendees
        self.privacyMode = privacyMode
        self.calendarEndDate = calendarEndDate
        self.targetBundleIdentifiers = targetBundleIdentifiers
        self.language = language
    }
}

public struct SessionConfiguration: Sendable {
    public var targetBundleIdentifiers: [String]
    public var audioRootDirectory: URL
    public var allSystemAudio = false
    public var includeMic = true
    /// マイク入力デバイスの UID（nil = システムの既定）。
    public var micDeviceUID: String?
    public var liveTranscription = true
    /// 会議の言語が自動のときに、ライブ字幕を始めるロケール（日本語。英語の会議は ja-JP の出力の文字の種類で判定できる）。
    public var liveLocale = Locale(identifier: "ja-JP")
    /// 両トラックがこの秒数無音なら finalizing（SPEC §6.2: 3 分）
    public var silenceTimeout: TimeInterval = 180
    /// finalizing 中にこの秒数以内に音声が再開したら recording に戻す（SPEC §6.2: 1 分）
    public var resumeGrace: TimeInterval = 60
    /// armed のまま音声が来なければ諦める
    public var armedTimeout: TimeInterval = 20 * 60
    /// カレンダー終了時刻 + この秒数で終了（SPEC §6.2: 15 分）
    public var afterEventEndGrace: TimeInterval = 15 * 60
    public var silenceThresholdDb: Float = -50
    public var monitorInterval: TimeInterval = 5
    /// true なら armed 中に音声を検知しても自動で recording に入らず、確認（`startNow()`）を待つ（SPEC §6.2）。
    public var confirmBeforeAutoStart = false

    public init(targetBundleIdentifiers: [String], audioRootDirectory: URL) {
        self.targetBundleIdentifiers = targetBundleIdentifiers
        self.audioRootDirectory = audioRootDirectory
    }
}

public struct SessionSnapshot: Sendable, Equatable {
    public var state: SessionState
    public var meeting: MeetingRecord?
    public var tappedProcessNames: [String]
    /// 会議の経過時間。録音準備（armed）中は会議が始まっていないので 0、始まってからは会議の開始（音声の検知・今すぐ開始）から数える。
    public var elapsedSeconds: Double
    public var systemLevelDb: Float
    public var micLevelDb: Float
    public var lastError: String?
    /// armed 中に音声を検知したが、設定により開始の確認を待っている。
    public var awaitingStartConfirmation = false
    /// 音声が届いていないトラック（"system" / "mic"）。録音は続いている（SPEC §4.3）。
    public var interruptedTracks: [String] = []
    /// 録音中のライブ字幕の言語。
    public var liveLanguage: MeetingLanguage?
    /// ライブ字幕のモデルを用意している・用意できなかった（用意できていれば nil）。
    public var livePreparation: LivePreparation?
}

/// 会議 1 回分の録音・ライブ字幕・状態遷移。終了後は永続キューへ渡して次の録音を受け付ける。
public actor MeetingSessionController {
    public typealias StateHandler = @Sendable (SessionState, MeetingRecord?) -> Void
    public typealias LiveHandler = @Sendable (String, String, LiveSegment) -> Void
    public typealias EventHandler = @Sendable (String) -> Void
    /// 音声を検知したが確認待ち（confirmBeforeAutoStart）。UI は通知やボタンで `startNow()` を促す。
    public typealias ConfirmationHandler = @Sendable (MeetingRecord?) -> Void

    private let store: Store
    private let postProcessingQueue: PostProcessingQueue
    public let configuration: SessionConfiguration
    private var machine = SessionStateMachine()
    private var stateHandler: StateHandler?
    private var liveHandler: LiveHandler?
    private var eventHandler: EventHandler?
    private var confirmationHandler: ConfirmationHandler?
    private var awaitingStartConfirmation = false

    private var recording: (any MeetingRecording)?
    private let makeRecording: @Sendable (RecordingOptions) -> any MeetingRecording
    private var pendingMeetingId: String?
    private var info: PendingMeetingInfo?
    private var meeting: MeetingRecord?
    private var liveTasks: [Task<Void, Never>] = []
    private var monitorTask: Task<Void, Never>?
    private var pendingLiveSegments: [SegmentRecord] = []
    private var lastAudioAt: Date?
    private var finalizingSince: Date?
    private var finalizingHasGrace = false
    private var armedAt: Date?
    private var lastSnapshot: RecordingSession.Snapshot?
    private var finishing = false
    private var starting = false
    private var captureFailure: CaptureFailure?
    private var meetingLease: MeetingLease?
    private var uiState: String?
    /// ライブ字幕の言語（両トラックの認識器が見る）。録音ごとに作る。
    private var liveControl: LiveLocaleControl?
    private var liveLanguage: MeetingLanguage?
    private var livePreparation: LivePreparation?
    public private(set) var lastError: String?

    public init(store: Store, pipeline: PostProcessPipeline, configuration: SessionConfiguration, postProcessingQueue: PostProcessingQueue? = nil, makeRecording: @escaping @Sendable (RecordingOptions) -> any MeetingRecording = { RecordingSession(options: $0) }) {
        self.makeRecording = makeRecording
        self.store = store
        self.postProcessingQueue = postProcessingQueue ?? PostProcessingQueue(store: store, pipeline: pipeline)
        self.configuration = configuration
    }

    public var state: SessionState { machine.state }
    public var currentMeeting: MeetingRecord? { meeting }

    public func setHandlers(state: StateHandler?, live: LiveHandler?, event: EventHandler?) {
        stateHandler = state
        liveHandler = live
        eventHandler = event
    }

    public func setConfirmationHandler(_ handler: ConfirmationHandler?) {
        confirmationHandler = handler
    }

    /// 録音を表示している画面（"window" / "panel" など）。次の録音にも引き継ぐ（G7 の診断用）。
    public func setUIState(_ state: String?) {
        uiState = state
        recording?.setUIState(state)
    }

    /// 画面用。音量は録音側から直接読むので、監視周期（5 秒）より細かく更新できる。
    public func snapshot() -> SessionSnapshot {
        let levels = recording?.levels() ?? TrackLevels()
        // 録音の原点ではなく会議の開始から数える（armed から入ると markMeetingStarted で開始時刻が今に更新される）
        let meetingStart = machine.state == .armed ? nil : meeting?.startedAt
        return SessionSnapshot(
            state: machine.state,
            meeting: meeting,
            tappedProcessNames: recording?.tappedProcesses.compactMap(\.name) ?? [],
            elapsedSeconds: meetingStart.map { max(0, Date().timeIntervalSince($0)) } ?? 0,
            systemLevelDb: levels.systemDb,
            micLevelDb: levels.micDb,
            lastError: lastError,
            awaitingStartConfirmation: awaitingStartConfirmation,
            interruptedTracks: recording?.interruptedTracks() ?? [],
            liveLanguage: liveLanguage,
            livePreparation: livePreparation
        )
    }

    // MARK: - Commands

    /// 録音準備（カレンダー開始前 + 対象アプリ起動）。録音は始めるが、会議は system 音声の検知で開始扱いにする。
    public func arm(_ info: PendingMeetingInfo) async throws {
        guard machine.state == .idle, !starting, !finishing else { throw AudioCaptureError.invalidState("録音の開始・停止処理中です") }
        starting = true
        defer { starting = false }
        self.info = info
        do { try await beginRecording(info) }
        catch { await failRecording(error.localizedDescription); throw error }
        try apply(.armConditionMet)
        armedAt = Date()
        startMonitor()
        emit("armed: \(info.title)")
    }

    /// 手動開始（idle / armed から）。
    public func start(_ info: PendingMeetingInfo) async throws {
        guard !starting, !finishing else { throw AudioCaptureError.invalidState("録音の開始・停止処理中です") }
        starting = true
        defer { starting = false }
        switch machine.state {
        case .idle:
            self.info = info
            do { try await beginRecording(info) }
            catch { await failRecording(error.localizedDescription); throw error }
            try apply(.manualStart)
            try createMeetingRow()
            startMonitor()
        case .armed:
            self.info = info
            try apply(.manualStart)
            try createMeetingRow()
            try markMeetingStarted()
        default:
            throw AudioCaptureError.invalidState("状態 \(machine.state.rawValue) では開始できません")
        }
        emit("recording started: \(info.title)")
    }

    /// armed から、カレンダー由来のタイトル・参加者を保ったまま録音に入る（「今すぐ開始」と確認待ちの承認）。
    public func startNow() throws {
        guard machine.state == .armed, !starting, !finishing else { throw AudioCaptureError.invalidState("録音準備中ではありません") }
        awaitingStartConfirmation = false
        try apply(.manualStart)
        try markMeetingStarted()
        emit("recording started (from armed): \(info?.title ?? "")")
    }

    /// 手動停止。armed なら破棄、recording / finalizing なら即座に後処理へ。
    public func stop() async {
        switch machine.state {
        case .armed:
            await disarm()
        case .recording:
            try? apply(.manualStop)
            emit("manual stop")
            await finishAndProcess()
        case .finalizing:
            guard !finishing else { return }
            await finishAndProcess()
        default:
            break
        }
    }

    public func disarm() async {
        guard machine.state == .armed, !finishing else { return }
        finishing = true
        defer { finishing = false }
        if let error = await teardownRecording() {
            finishing = false
            await failRecording(error)
            return
        }
        do {
            if let meeting, let lease = meetingLease {
                try store.discardStoppedRecording(id: meeting.id, lease: lease)
            }
        } catch {
            emit("録音準備の削除に失敗: \(error.localizedDescription)")
            if let meeting { try? store.setMeetingStatus(id: meeting.id, status: .failed, endedAt: Date()) }
        }
        cleanupAfterMeeting()
        try? apply(.disarm)
        emit("disarmed")
    }

    /// 対象アプリ（会議アプリ）のプロセスが終了した。
    public func targetProcessExited() async {
        switch machine.state {
        case .armed: await disarm()
        case .recording: enterFinalizing(.targetProcessExited, grace: true)
        default: break
        }
    }

    public func calendarEndPassed() {
        if machine.state == .recording { enterFinalizing(.calendarEndPassed, grace: true) }
    }

    /// 録音中にライブ字幕と会議の言語を切り替える。会議のあとの文字起こし・要約もこの言語にする（自動判定はしない）。
    public func setLiveLanguage(_ language: MeetingLanguage) throws {
        guard machine.state == .armed || machine.state == .recording || machine.state == .finalizing else {
            throw AudioCaptureError.invalidState("録音中ではありません")
        }
        info?.language = language
        liveLanguage = language
        livePreparation = nil
        liveControl?.set(language.locale)
        if let current = meeting {
            try store.setMeetingLanguage(id: current.id, language: language, detected: false)
            meeting = try store.meeting(id: current.id) ?? current
            notifyState()
        }
        emit("live language: \(language.rawValue)")
    }

    /// 再試行も同じキューへ入れる。別会議の録音状態には触れない。
    public func retryPipeline(meetingId: String, reprocess: Bool = false) async throws {
        try store.requestPostProcessing(meetingId: meetingId, reprocess: reprocess)
        await postProcessingQueue.start()
    }

    // MARK: - Internals

    private var recordingDirectory: URL? {
        pendingMeetingId.map { configuration.audioRootDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    private func apply(_ event: SessionEvent) throws {
        try machine.handle(event)
        notifyState()
    }

    private func notifyState() {
        stateHandler?(machine.state, meeting)
    }

    private func emit(_ message: String) {
        Log.audio.info("session: \(message, privacy: .public)")
        eventHandler?(message)
    }

    private func beginRecording(_ info: PendingMeetingInfo) async throws {
        lastError = nil
        let id = ULID.generate()
        meetingLease = try store.acquireMeetingLease(id)
        pendingMeetingId = id
        var options = RecordingOptions(outputDirectory: configuration.audioRootDirectory.appendingPathComponent(id, isDirectory: true))
        options.targetBundleIdentifiers = info.targetBundleIdentifiers?.isEmpty == false ? info.targetBundleIdentifiers! : configuration.targetBundleIdentifiers
        options.allSystemAudio = configuration.allSystemAudio
        options.includeMic = configuration.includeMic
        options.micDeviceUID = configuration.micDeviceUID
        options.streamLiveAudio = configuration.liveTranscription
        options.title = info.title
        let session = makeRecording(options)
        session.onEvent = { [weak self] message in
            Task { await self?.emit("recording: \(message)") }
        }
        session.onFailure = { [weak self] failure in
            Task { await self?.captureDidFail(failure, generation: id) }
        }
        session.setUIState(uiState)
        recording = session
        let language = info.language ?? MeetingLanguage(code: configuration.liveLocale.identifier) ?? .ja
        liveLanguage = language
        livePreparation = nil
        liveControl = LiveLocaleControl(locale: info.language?.locale ?? configuration.liveLocale)
        // permission / capture の await より先に記録する。開始途中の異常終了も復旧対象になる。
        try createMeetingRow()
        try await session.start()
        if let captureFailure { throw captureFailure }
        lastAudioAt = Date()
        if configuration.liveTranscription { startLive(session) }
    }

    private func createMeetingRow() throws {
        guard let info, let recording, let pendingMeetingId, meeting == nil else { return }
        let origin = recording.startedAt ?? Date()
        let record = MeetingRecord(
            id: pendingMeetingId,
            title: info.title,
            startedAt: origin,
            platform: info.platform,
            calendarEventId: info.calendarEventId,
            calendarTitle: info.calendarTitle,
            attendees: info.attendees,
            privacyMode: info.privacyMode,
            status: .recording,
            audioDir: recording.options.outputDirectory.path,
            recordingStartedAt: origin,
            language: info.language
        )
        meeting = try store.createMeeting(record)
        let flushed = pendingLiveSegments.map { segment -> SegmentRecord in
            var copy = segment
            copy.meetingId = record.id
            return copy
        }
        pendingLiveSegments = []
        try store.appendSegments(flushed)
        lastAudioAt = Date()
        notifyState()
    }

    /// 会議の開始時刻を今にする。録音準備（armed）中に録った区間は mic の文字起こしから除外され、一覧の開始時刻も実際の開始になる。
    private func markMeetingStarted() throws {
        guard let current = meeting else { return }
        try store.setMeetingStarted(id: current.id, at: Date())
        meeting = try store.meeting(id: current.id) ?? current
        notifyState()
    }

    private func startLive(_ session: any MeetingRecording) {
        if let stream = session.systemChunks {
            liveTasks.append(consume(stream, track: TrackMerger.systemTrack, label: nil))
        }
        if let stream = session.micChunks {
            liveTasks.append(consume(stream, track: TrackMerger.micTrack, label: TrackMerger.micSpeakerLabel))
        }
    }

    private func consume(_ stream: AsyncStream<AudioChunk>, track: String, label: String?) -> Task<Void, Never> {
        let control = liveControl ?? LiveLocaleControl(locale: configuration.liveLocale)
        let generation = pendingMeetingId
        // モデルの用意の進み具合は相手側のトラックで代表する（両トラックが同じモデルを待つ）
        let reportsPreparation = track == TrackMerger.systemTrack
        let report: @Sendable (LivePreparation) -> Void = { [weak self] preparation in
            guard reportsPreparation else { return }
            Task { await self?.updateLivePreparation(preparation, generation: generation) }
        }
        return Task { [weak self] in
            let transcriber = SpeechAnalyzerLiveTranscriber(reportVolatile: true, onPreparation: report)
            do {
                for try await segment in transcriber.start(audio: stream, control: control) {
                    await self?.handleLive(generation: generation, track: track, label: label, segment: segment)
                }
            } catch {
                await self?.emit("live \(track) error: \(error.localizedDescription)")
            }
        }
    }

    private func updateLivePreparation(_ preparation: LivePreparation, generation: String?) {
        guard let generation, generation == pendingMeetingId else { return }
        switch preparation {
        case let .ready(locale):
            // 切り替えに失敗して元の言語で開き直したときは、失敗の知らせを残す
            if locale.identifier == liveControl?.locale.identifier { livePreparation = nil }
        case .preparing(_, nil):
            break  // モデルの確認だけ（ダウンロードしないなら一瞬で終わる）
        case .preparing, .failed:
            livePreparation = preparation
        }
    }

    private func handleLive(generation: String?, track: String, label: String?, segment: LiveSegment) {
        guard let generation, generation == pendingMeetingId else { return }
        liveHandler?(generation, track, segment)
        guard segment.isFinal else { return }
        // 録音準備中の自分の声は会議ではない。画面には流すが保存・検索対象にはしない。
        if machine.state == .armed, track == TrackMerger.micTrack { return }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let record = SegmentRecord(meetingId: meeting?.id ?? "", source: .live, tStart: segment.start, tEnd: segment.end, clusterLabel: label, text: text)
        if meeting != nil {
            // クラッシュしても live segments が失われないよう即座に保存する
            do { try store.appendSegments([record]) } catch { emit("live segment save failed: \(error.localizedDescription)") }
        } else {
            pendingLiveSegments.append(record)
        }
    }

    private func startMonitor() {
        monitorTask?.cancel()
        let interval = configuration.monitorInterval
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                await self?.monitorTick()
            }
        }
    }

    private func monitorTick() async {
        guard let recording, !finishing else { return }
        let snapshot = recording.snapshot()
        lastSnapshot = snapshot
        let threshold = configuration.silenceThresholdDb
        let systemActive = (snapshot.system?.intervalPeakRmsDb ?? -120) > threshold
        let micActive = (snapshot.mic?.intervalPeakRmsDb ?? -120) > threshold
        let now = Date()

        switch machine.state {
        case .armed:
            if systemActive {
                if configuration.confirmBeforeAutoStart {
                    // 自動開始しない設定。一度だけ確認を求め、承認（startNow）か armed のタイムアウトを待つ。
                    if !awaitingStartConfirmation {
                        awaitingStartConfirmation = true
                        emit("audio detected → awaiting confirmation")
                        confirmationHandler?(meeting)
                    }
                    return
                }
                do {
                    try apply(.audioDetected)
                    try createMeetingRow()
                    try markMeetingStarted()
                } catch { await failRecording(error.localizedDescription); return }
                emit("audio detected → recording")
            } else if let armedAt, now.timeIntervalSince(armedAt) > configuration.armedTimeout {
                emit("armed timeout")
                await disarm()
            }
        case .recording:
            if systemActive || micActive { lastAudioAt = now }
            if let lastAudioAt, now.timeIntervalSince(lastAudioAt) > configuration.silenceTimeout {
                enterFinalizing(.silenceTimeout, grace: true)
            } else if let end = info?.calendarEndDate, now > end.addingTimeInterval(configuration.afterEventEndGrace) {
                enterFinalizing(.calendarEndPassed, grace: true)
            }
        case .finalizing where finalizingHasGrace:
            if systemActive || micActive {
                finalizingHasGrace = false
                lastAudioAt = now
                try? apply(.audioResumed)
                emit("audio resumed → recording")
            } else if let since = finalizingSince, now.timeIntervalSince(since) > configuration.resumeGrace {
                await finishAndProcess()
            }
        default:
            break
        }
    }

    private func enterFinalizing(_ event: SessionEvent, grace: Bool) {
        guard machine.state == .recording else { return }
        try? apply(event)
        finalizingSince = Date()
        finalizingHasGrace = grace
        emit("finalizing (\(event)), grace \(grace ? Int(configuration.resumeGrace) : 0)s")
    }

    private func teardownRecording() async -> String? {
        monitorTask?.cancel()
        monitorTask = nil
        guard let recording else { return nil }
        var failure: String?
        do { try recording.finishRecording() } catch {
            failure = error.localizedDescription
            reportCaptureFailure(error.localizedDescription)
        }
        // ストリーム終了 → SpeechAnalyzer の finalize を待つ（最大 20 秒）
        let tasks = liveTasks
        liveTasks = []
        await TaskDrain.wait(tasks, timeout: .seconds(20))
        self.recording = nil
        return failure
    }

    private func finishAndProcess() async {
        guard !finishing else { return }
        finishing = true
        finalizingHasGrace = false
        let endedAt = Date()
        if let error = await teardownRecording() {
            finishing = false
            await failRecording(error)
            return
        }
        if let captureFailure {
            finishing = false
            await failRecording(captureFailure.localizedDescription)
            return
        }
        guard let current = meeting else {
            // 会議として成立しなかった（armed のまま停止）
            if let directory = recordingDirectory { try? FileManager.default.removeItem(at: directory) }
            cleanupAfterMeeting()
            try? apply(.reset)
            finishing = false
            return
        }
        do {
            guard let lease = meetingLease else { throw StoreError.meetingBusy(current.id) }
            try store.enqueuePostProcessing(meetingId: current.id, lease: lease, endedAt: endedAt)
        } catch {
            finishing = false
            await failRecording(error.localizedDescription)
            return
        }
        // ファイル終了と依頼の永続化が済んだら、録音の状態・所有権を解放する。
        cleanupAfterMeeting()
        finishing = false
        try? apply(.recordingFinished)
        emit("後処理を予約しました: \(current.id)")
        Task { await postProcessingQueue.start() }
    }

    private func captureDidFail(_ failure: CaptureFailure, generation: String) async {
        guard generation == pendingMeetingId else { return }
        captureFailure = failure
        if starting || finishing { return }
        await failRecording(failure.localizedDescription)
    }

    private func reportCaptureFailure(_ message: String) {
        guard machine.state != .failed else { return }
        lastError = message
        if let id = meeting?.id {
            try? store.setMeetingStatus(id: id, status: .failed, endedAt: Date())
            _ = try? store.recordRun(meetingId: id, step: "capture", status: .failed, error: message)
            meeting = try? store.meeting(id: id)
        }
        emit("録音を停止しました: \(message)。保存済み音声を保持しています")
        try? apply(.captureFailed(message))
    }

    private func failRecording(_ message: String) async {
        guard !finishing else { return }
        finishing = true
        reportCaptureFailure(message)
        _ = await teardownRecording()
        cleanupAfterMeeting()
        try? apply(.reset)
        finishing = false
    }

    private func cleanupAfterMeeting() {
        liveControl = nil
        liveLanguage = nil
        livePreparation = nil
        meetingLease = nil
        captureFailure = nil
        awaitingStartConfirmation = false
        meeting = nil
        info = nil
        pendingMeetingId = nil
        pendingLiveSegments = []
        lastAudioAt = nil
        finalizingSince = nil
        armedAt = nil
        lastSnapshot = nil
    }
}
