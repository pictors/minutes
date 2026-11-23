@preconcurrency import AVFAudio
import Foundation
import MinutesKit
import Observation

enum RecorderError: Error, LocalizedError {
    case microphoneDenied
    case simulatorMicrophone
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "マイクの使用が許可されていません。設定アプリの Minutes でマイクを許可してください"
        case .simulatorMicrophone: "シミュレータでは部屋の音を録りません（開発用の音声を MINUTES_FIXTURE_AUDIO で指定してください）"
        case .alreadyRecording: "すでに録音しています"
        }
    }
}

/// 会議の録音（iPhone と Watch で共通。製品版の P4）。
/// - 録音は走ごとに 1 つのファイル（ADTS の AAC）に書く。電話・Siri などで止まったら走を閉じ、再開の推奨を受けたら新しい走で続ける。
///   すぐの再開は失敗することがあるので（P1: ほかのアプリが音声を使っている '!pri'）、数秒おきに何度か試す。録れなかった時間は gaps に残す。
/// - 走を始めた・閉じた・録音中の 10 秒ごと・止めたときに onProgress を呼ぶ（送る側が増えた分を区切って上げる）。
@MainActor
@Observable
final class MeetingRecorder {
    enum Phase: Equatable {
        case idle
        case recording
        /// 電話・Siri などで止まっている（再開を待つ）
        case interrupted
    }

    private(set) var phase: Phase = .idle
    private(set) var clientId: String?
    private(set) var title: String?
    private(set) var meetingStartedAt: Date?
    private(set) var runStartedAt: Date?
    /// 閉じた走の合計の秒数
    private(set) var closedSeconds: Double = 0
    private(set) var gaps: [DateInterval] = []
    /// 画面に出す知らせ（中断・再開の失敗など）
    private(set) var notice: String?

    /// "iphone" | "watch"
    let source: String
    private let store: RecordingStore
    /// 書いている走の番号（記録そのものは持たず、書き換えるたびにファイルから読む: RecordingStore.update）
    private var currentRun: Int?
    private var capture: AudioCapture?
    private var fixture: FixtureCapture?
    private var observers: [NSObjectProtocol] = []
    private var resumeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// 録音が増えた・閉じた・止まった（client_id）
    var onProgress: ((String) -> Void)?

    init(source: String, store: RecordingStore = .standard) {
        self.source = source
        self.store = store
    }

    var isActive: Bool { phase != .idle }

    var level: Float { capture?.level ?? 0 }

    func elapsed(at date: Date) -> Double {
        closedSeconds + (phase == .recording ? max(0, date.timeIntervalSince(runStartedAt ?? date)) : 0)
    }

    // MARK: 始める・止める

    func start(title: String?) async throws {
        guard phase == .idle else { throw RecorderError.alreadyRecording }
        let usesFixture = try prepareFixture()
        if !usesFixture {
            if CloudEnvironment.isSimulator { throw RecorderError.simulatorMicrophone }
            guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.microphoneDenied }
            try configureSession()
        }
        let now = Date()
        let upload = MinutesCloudUpload(clientId: MinutesCloudUpload.newClientID(source: source, date: now), source: source,
                                        title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, startedAt: now)
        try store.create(upload)
        clientId = upload.clientId
        self.title = upload.title
        meetingStartedAt = now
        closedSeconds = 0
        gaps = []
        notice = nil
        do {
            try startRun()
        } catch {
            try? store.update(clientId: upload.clientId) { $0.stop() }
            reset()
            throw error
        }
        if !usesFixture { observeSession() }
        startTicking()
    }

    func stop() {
        guard phase != .idle, let id = clientId else { return }
        resumeTask?.cancel()
        finishRun()
        try? store.update(clientId: id) { $0.stop() }
        if fixture == nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        reset()
        onProgress?(id)
    }

    /// 中断のあと、利用者のボタンで再開する。
    func resume() {
        guard phase == .interrupted else { return }
        scheduleResume(attempts: 3, firstDelay: .zero)
    }

    private func reset() {
        tickTask?.cancel()
        tickTask = nil
        resumeTask = nil
        removeObservers()
        phase = .idle
        currentRun = nil
        capture = nil
        fixture = nil
        clientId = nil
        title = nil
        meetingStartedAt = nil
        runStartedAt = nil
        notice = nil
    }

    // MARK: 走

    private func startRun() throws {
        guard let clientId else { return }
        let (upload, run) = try store.update(clientId: clientId) { (upload: inout MinutesCloudUpload) -> (MinutesCloudUpload, MinutesCloudUpload.Run) in
            let run = upload.startRun(at: Date())
            return (upload, run)
        }
        let capture: AudioCapture = fixture ?? MicrophoneCapture()
        // 前の走の入力から遅れて届いた知らせで、いまの走を閉じない
        capture.onStopped = { [weak self, weak capture] in
            Task { @MainActor in
                guard let self, let capture, let current = self.capture, current === capture else { return }
                self.captureStopped()
            }
        }
        do {
            if fixture == nil { try AVAudioSession.sharedInstance().setActive(true) }
            try capture.start(writingTo: store.runURL(upload, run))
        } catch {
            try? store.update(clientId: clientId) { $0.finishRun(run.index, durationSeconds: 0) }
            throw error
        }
        self.capture = capture
        currentRun = run.index
        runStartedAt = run.startedAt
        phase = .recording
        gaps = upload.gaps
        onProgress?(clientId)
    }

    private func finishRun() {
        guard let clientId, let capture, let index = currentRun else { return }
        let seconds = capture.stop()
        let upload = try? store.update(clientId: clientId) { (upload: inout MinutesCloudUpload) -> MinutesCloudUpload in
            upload.finishRun(index, durationSeconds: seconds)
            return upload
        }
        self.capture = nil
        currentRun = nil
        closedSeconds += seconds
        runStartedAt = nil
        if let upload { gaps = upload.gaps }
        onProgress?(clientId)
    }

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let id = self.clientId, self.phase == .recording else { continue }
                self.onProgress?(id)
            }
        }
    }

    // MARK: 開発用の音声

    private func prepareFixture() throws -> Bool {
        guard let fixture = try FixtureCapture.fromEnvironment() else { return false }
        self.fixture = fixture
        return true
    }

    // MARK: 中断

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // iOS・watchOS 26 まで（27 では旧式。27 でも届く: P1）
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            MainActor.assumeIsolated {
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self?.interrupted()
                } else if type == AVAudioSession.InterruptionType.ended.rawValue, options & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0 {
                    self?.resumeRecommended()
                }
            }
        })
        // iOS・watchOS 27 から: 止めたのが OS か（source 2）、再開してよいか（recommendation 1）
        if #available(iOS 27.0, watchOS 27.0, *) {
            observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                let bySystem = context.map { $0.source.rawValue == 2 } ?? true
                MainActor.assumeIsolated {
                    if bySystem { self?.interrupted() }
                }
            })
            observers.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: .main) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                let shouldResume = context.map { $0.recommendation.rawValue == 1 } ?? false
                MainActor.assumeIsolated {
                    if shouldResume { self?.resumeRecommended() }
                }
            })
        }
        // 音声の仕組みが作り直されたときは、新しい走で続ける
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                self.interrupted()
                self.scheduleResume(attempts: 5, firstDelay: .seconds(1))
            }
        })
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// 入力が途中で止まった（経路の変化・書き込みの失敗）: 走を閉じ、新しい走で録り直す。録れなかった時間は gaps に残る。
    private func captureStopped() {
        guard phase == .recording else { return }
        finishRun()
        phase = .interrupted
        notice = "録音が途切れました。続きを録ります"
        scheduleResume(attempts: 5, firstDelay: .milliseconds(500))
    }

    private func interrupted() {
        guard phase == .recording else { return }
        finishRun()
        phase = .interrupted
        notice = "録音が止まりました（電話・Siri など）。終わったら自動で続きを録ります"
    }

    private func resumeRecommended() {
        guard phase == .interrupted else { return }
        scheduleResume(attempts: 15, firstDelay: .seconds(1))
    }

    /// すぐの再開は断られることがあるので、2 秒おきに試す（P1）。
    private func scheduleResume(attempts: Int, firstDelay: Duration) {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: firstDelay)
            for attempt in 0..<attempts {
                guard let self, !Task.isCancelled, self.phase == .interrupted else { return }
                do {
                    try self.startRun()
                    self.notice = nil
                    return
                } catch {
                    self.notice = "録音を再開できません（\(attempt + 1) 回目）。ほかのアプリが音声を使っているかもしれません"
                }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.notice = "録音を再開できませんでした。「再開」を押してください"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
