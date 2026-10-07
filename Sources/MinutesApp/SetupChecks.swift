import AppKit
import MinutesCore

/// 会議アプリの音の録音（システムオーディオ録音）の許可を確かめる。事前に調べる API がないので、Minutes 自身がテスト音を鳴らし、
/// それを Process Tap で録れるかを見る。初めてのときは OS が許可を尋ねるので、その間も音を鳴らし続けて待つ。
@MainActor
enum SystemAudioCheck {
    enum Result: Equatable {
        case granted
        /// tap は作れたが音が届かない（許可されていない、または許可を待っている間に時間切れ）
        case silent
        case failed(String)
    }

    static func run(timeout: Duration = .seconds(20)) async -> Result {
        guard let bundleID = Bundle.main.bundleIdentifier else { return .failed("アプリの識別子がありません") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = RecordingOptions(outputDirectory: directory)
        options.targetBundleIdentifiers = [bundleID]
        options.includeMic = false
        options.writeAudioFiles = false
        options.streamLiveAudio = false
        let chime = NSSound(named: "Glass")
        // 先に音を出して、Minutes 自身に音の出口（Core Audio のプロセス）を作ってから tap を作る
        chime?.play()
        try? await Task.sleep(for: .milliseconds(300))
        let session = RecordingSession(options: options)
        do {
            try await session.start()
        } catch {
            chime?.stop()
            return .failed(SetupMessages.describe(error))
        }
        defer { _ = try? session.stop() }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if chime?.isPlaying == false { chime?.play() }
            try? await Task.sleep(for: .milliseconds(100))
            if session.levels().systemDb > -60 {
                chime?.stop()
                return .granted
            }
        }
        chime?.stop()
        return .silent
    }
}

/// 試しの録音（20 秒）。保存はせず、会議アプリの音・自分の声・ライブ字幕が届くかを確かめる（2026-10-05 決定）。
@MainActor
@Observable
final class TestRecording {
    enum Phase: Equatable {
        case idle, starting, running, finished
        case failed(String)
    }

    struct Caption: Identifiable, Equatable {
        let id = UUID()
        let track: String
        var text: String
    }

    static let duration = 20

    private(set) var phase: Phase = .idle
    private(set) var remaining = TestRecording.duration
    private(set) var captions: [Caption] = []
    private(set) var systemPeak: Float = -120
    private(set) var micPeak: Float = -120
    /// メーター（音量は SwiftUI の状態を通さずに渡す。G7）
    let systemLevel = LevelFeed()
    let micLevel = LevelFeed()
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// トラックごとの、途中経過を書き換えている行
    @ObservationIgnored private var volatile: [String: UUID] = [:]
    @ObservationIgnored private var directory: URL?

    /// 会議アプリの音・自分の声とみなす大きさ（無音の部屋は -60 dB 前後）
    static let heardThreshold: Float = -50
    var heardSystem: Bool { systemPeak > Self.heardThreshold }
    var heardMic: Bool { micPeak > Self.heardThreshold }
    var sawCaptions: Bool { captions.contains { !$0.text.isEmpty } }

    func start(settings: AppSettings) async {
        cancel()
        phase = .starting
        remaining = Self.duration
        captions = []
        systemPeak = -120
        micPeak = -120
        volatile = [:]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-test-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        var options = RecordingOptions(outputDirectory: directory)
        options.targetBundleIdentifiers = settings.targetBundleIdentifiers
        options.includeMic = settings.includeMic
        options.micDeviceUID = settings.micDevice
        options.writeAudioFiles = false
        options.streamLiveAudio = true
        let session = RecordingSession(options: options)
        do {
            try await session.start()
        } catch {
            phase = .failed(SetupMessages.describe(error, targets: settings.targetBundleIdentifiers))
            cleanUp()
            return
        }
        self.session = session
        phase = .running
        let locale = settings.meetingLanguage.liveLanguage.locale
        for (track, stream) in [(TrackMerger.systemTrack, session.systemChunks), (TrackMerger.micTrack, session.micChunks)] {
            guard let stream else { continue }
            tasks.append(Task { [weak self] in
                let transcriber = SpeechAnalyzerLiveTranscriber(reportVolatile: true)
                do {
                    for try await segment in transcriber.start(audio: stream, locale: locale) {
                        self?.receive(track: track, segment: segment)
                    }
                } catch {}
            })
        }
        tasks.append(Task { [weak self] in
            let end = ContinuousClock.now + .seconds(Self.duration)
            while !Task.isCancelled, ContinuousClock.now < end {
                self?.sample(session.levels(), remaining: end - ContinuousClock.now)
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled else { return }
            self?.finish()
        })
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks = []
        _ = try? session?.stop()
        session = nil
        cleanUp()
        if phase == .running || phase == .starting { phase = .idle }
    }

    private func sample(_ levels: TrackLevels, remaining: Duration) {
        systemLevel.send(levels.systemDb)
        micLevel.send(levels.micDb)
        systemPeak = max(systemPeak, levels.systemDb)
        micPeak = max(micPeak, levels.micDb)
        let seconds = Int((Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18).rounded(.up))
        if seconds != self.remaining { self.remaining = max(0, seconds) }
    }

    /// 途中経過は同じ行を書き換え、確定したら次の行へ。直近の 4 行だけ残す。
    private func receive(track: String, segment: LiveSegment) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = volatile[track], let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index].text = text
        } else if !text.isEmpty {
            let caption = Caption(track: track, text: text)
            captions.append(caption)
            volatile[track] = caption.id
        }
        if segment.isFinal { volatile[track] = nil }
        if captions.count > 4 { captions.removeFirst(captions.count - 4) }
    }

    private func finish() {
        _ = try? session?.stop()
        session = nil
        // 録音を止めると字幕の流れも終わる。残りの確定を受け取るまで少し待ってから閉じる
        let pending = tasks
        tasks = []
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            pending.forEach { $0.cancel() }
        }
        cleanUp()
        phase = .finished
    }

    private func cleanUp() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

/// 録音を始められなかった理由を、初めての人に分かる言葉にする（CLI の案内や内部の名前を出さない）。
enum SetupMessages {
    static func describe(_ error: any Error, targets: [String] = []) -> String {
        switch error as? AudioCaptureError {
        case .noMatchingProcess?:
            // 起動していても、まだ音を出していないアプリは録音の対象に見えない
            let names = targets.compactMap(AppNames.name(for:))
            let apps = names.isEmpty ? "会議アプリ" : names.joined(separator: "・")
            return "\(apps)から出る音が見つかりません。会議アプリを開き、音が出ている状態でもう一度始めてください。"
        case .tapCreationFailed?:
            return "会議アプリの音を録音する許可がありません。システム設定の「画面収録とシステムオーディオ録音」で Minutes を許可してください。"
        case .permissionDenied?:
            return "マイクの許可がありません。システム設定の「マイク」で Minutes を許可してください。"
        case .noInputDevice?:
            return "マイクが見つかりません。マイクをつないでから、もう一度試してください。"
        default:
            return error.localizedDescription
        }
    }
}

/// bundle ID からアプリの表示名とアイコンを引く（入っていなければ nil）。
enum AppNames {
    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String? {
        guard let url = url(for: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(for bundleID: String) -> NSImage? {
        url(for: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
