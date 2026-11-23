@preconcurrency import AVFAudio
import Foundation
import MinutesKit
import Observation

/// Watch のアプリの状態（録音・この Watch の録音の一覧・送信・ログイン）。
@MainActor
@Observable
final class WatchModel {
    private(set) var recordings: [MinutesCloudUpload] = []
    private(set) var isSignedIn: Bool

    let recorder: MeetingRecorder
    let uploads: UploadEngine
    let store: RecordingStore

    private static let noticeAcceptedKey = "recordingNoticeAccepted"

    init(store: RecordingStore = .standard) {
        self.store = store
        recorder = MeetingRecorder(source: "watch", store: store)
        uploads = UploadEngine(store: store) { CloudEnvironment.client() }
        isSignedIn = TokenStore.shared.isSignedIn
        recorder.onProgress = { [weak self] clientId in
            self?.uploads.kick(clientId)
            self?.reload()
        }
        uploads.onChange = { [weak self] _ in self?.reload() }
        LoginRelay.shared.onChange = { [weak self] in self?.loginChanged() }
    }

    /// 録音の告知と送り先の説明に同意したか（最初の録音の前に一度だけ）。
    var noticeAccepted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.noticeAcceptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.noticeAcceptedKey) }
    }

    func onLaunch() {
        recoverUnfinished()
        reload()
        uploads.restore()
        LoginRelay.shared.activate()
        #if DEBUG
        autoRecordIfRequested()
        #endif
    }

    #if DEBUG
    /// 開発用: Watch のシミュレータは外から画面を押せないので、環境変数 MINUTES_AUTORECORD_SECONDS があれば、起動してすぐ録音を始めて
    /// その秒数で止める（シミュレータでは MINUTES_FIXTURE_AUDIO の架空の会議を書く。マイクは使わない）。
    private func autoRecordIfRequested() {
        guard let value = ProcessInfo.processInfo.environment["MINUTES_AUTORECORD_SECONDS"], let seconds = Double(value), seconds > 0 else { return }
        Task {
            do {
                try await recorder.start(title: nil)
            } catch {
                Log.audio.error("autorecord_failed \(error.localizedDescription, privacy: .public)")
                return
            }
            try? await Task.sleep(for: .seconds(seconds))
            recorder.stop()
        }
    }
    #endif

    func becameActive() {
        reload()
        uploads.kickAll()
    }

    private func loginChanged() {
        isSignedIn = TokenStore.shared.isSignedIn
        if isSignedIn { uploads.kickAll() }
        reload()
    }

    /// 録音の途中でアプリが終わった録音は、録れたところまでで止めて送る。
    private func recoverUnfinished() {
        for upload in store.all() where !upload.stopped && upload.clientId != recorder.clientId {
            try? store.update(clientId: upload.clientId) { $0.stop() }
        }
    }

    func reload() {
        recordings = store.all()
        isSignedIn = TokenStore.shared.isSignedIn
    }

    func recording(_ clientId: String) -> MinutesCloudUpload? {
        recordings.first { $0.clientId == clientId }
    }

    /// この Watch とサーバーから消す。
    func delete(_ upload: MinutesCloudUpload) async {
        uploads.cancel(upload.clientId)
        if let serverId = upload.serverId { try? await CloudEnvironment.client().deleteRecording(id: serverId) }
        try? store.delete(clientId: upload.clientId)
        reload()
    }

    func retry(_ upload: MinutesCloudUpload) {
        uploads.retry(upload.clientId)
    }

    func runURLs(_ upload: MinutesCloudUpload) -> [URL] {
        upload.runs.sorted { $0.index < $1.index }.map { store.runURL(upload, $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 一覧と詳細に出す状態。
    func status(_ upload: MinutesCloudUpload) -> String {
        if upload.clientId == recorder.clientId { return "録音中" }
        if upload.completed { return upload.lastError ?? "送りました。議事録は iPhone で見られます" }
        if !CloudEnvironment.uploadsAllowed { return "この Watch に保存（シミュレータからは本番に送りません）" }
        if !isSignedIn { return "iPhone の Minutes でログインすると送ります" }
        if let error = upload.lastError { return "送れていません: \(error)" }
        return upload.stopped ? "送っています" : "録音中"
    }
}

/// この Watch の録音の再生（走ごとのファイルを順に）。
@MainActor
@Observable
final class RunPlayback {
    private(set) var isPlaying = false
    private var queue: [URL] = []
    private var player: AVAudioPlayer?
    private let finish = FinishDelegate()

    init() {
        finish.onFinish = { [weak self] in self?.next() }
    }

    func play(_ urls: [URL]) {
        queue = urls
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        next()
    }

    func stop() {
        queue = []
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func next() {
        guard !queue.isEmpty else {
            isPlaying = false
            return
        }
        let url = queue.removeFirst()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = finish
        if player?.play() == true {
            isPlaying = true
        } else {
            next()
        }
    }

    private final class FinishDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        @MainActor var onFinish: (() -> Void)?

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor in self.onFinish?() }
        }
    }
}
