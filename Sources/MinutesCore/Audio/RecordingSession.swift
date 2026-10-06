import AVFoundation
import CoreAudio
import Foundation

/// 録音 1 回分の設定。
public struct RecordingOptions: Sendable {
    public var targetBundleIdentifiers: [String] = []
    public var outputDirectory: URL
    public var includeSystem = true
    public var includeMic = true
    /// true なら対象アプリを限定せず全システム音声を録る（会議専用ブラウザ運用の代替）。
    public var allSystemAudio = false
    public var tapAutoStart = false
    public var clockDeviceUID: String?
    /// マイク入力デバイスの UID。nil ならシステムの既定入力。見つからなければ既定入力で続ける。
    public var micDeviceUID: String?
    public var aacBitrate = 64_000
    /// false なら音声ファイルを書かず、16 kHz ストリームと統計だけを出す（live 用）。
    public var writeAudioFiles = true
    /// ライブ字幕を使わない場合はストリームを生成・蓄積しない。
    public var streamLiveAudio = true
    /// 録音開始後に現れた対象プロセスを tap に追加する。
    public var followNewProcesses = true
    public var title: String?

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }
}

public struct ResourceUsageSummary: Sendable, Codable, Equatable {
    public var cpuPercentAvg: Double
    public var cpuPercentMax: Double
    public var rssMaxBytes: UInt64
    public var sampleCount: Int
}

/// 録音フォルダに書く `recording.json`。transcribe が読む。
public struct RecordingManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let fileName = "recording.json"

    public var schemaVersion: Int
    public var id: String
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Double?
    public var targetBundleIdentifiers: [String]
    public var allSystemAudio: Bool
    public var tappedProcesses: [AudioProcessInfo]
    public var clockDevice: String?
    public var micDevice: String?
    public var tapStream: String?
    /// 役割 → ファイル名（"system_archive": "system.m4a" など）。
    public var files: [String: String]
    public var tracks: [String: TrackStatsSnapshot]
    public var resourceUsage: ResourceUsageSummary?
    public var events: [String]

    public func write(to directory: URL) throws {
        let data = try JSONCoding.encoder().encode(self)
        try data.write(to: directory.appendingPathComponent(RecordingManifest.fileName), options: .atomic)
    }

    public static func read(from directory: URL) throws -> RecordingManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent(fileName))
        return try JSONCoding.decoder().decode(RecordingManifest.self, from: data)
    }
}

/// 2 トラック録音のオーケストレーション（SPEC §4）。Phase 1 の Session 状態機械はこの上に載せる。
@available(macOS 15.0, *)
public final class RecordingSession: @unchecked Sendable {
    public static let systemArchiveName = "system.m4a"
    public static let systemSTTName = "system_16k.wav"
    public static let micArchiveName = "mic.m4a"
    public static let micSTTName = "mic_16k.wav"

    public struct Snapshot: Sendable, Codable {
        public var elapsedSeconds: Double
        public var system: TrackStatsSnapshot?
        public var mic: TrackStatsSnapshot?
        public var cpuPercent: Double
        public var residentBytes: UInt64
        public var tappedProcessCount: Int
        /// 録音を表示していた画面（"window" / "panel" / "panel+window" / "none"）。G7 の CPU を画面の有無で分けて見るための診断用。
        public var ui: String? = nil
        /// スレッド名ごとの CPU（1 コア基準の %、多い順に 6 件）。G7 の内訳の診断用。
        public var threads: [String: Double]? = nil

        /// 人間向けの 1 行。
        public func formatted() -> String {
            var parts: [String] = ["[stats] \(TimeFormatting.hms(elapsedSeconds))"]
            for track in [system, mic] {
                guard let track else { continue }
                let drift = track.driftSeconds.map { String(format: "%+.1fms", $0 * 1000) } ?? "n/a"
                parts.append(String(
                    format: "%@ %dHz: rms=%.1fdB peak=%.1fdB active=%.0fs gaps=%d(%.3fs) drift=%@",
                    track.name, Int(track.sourceSampleRate), track.lastRmsDb, track.intervalPeakRmsDb,
                    track.activeSeconds, track.gapCount, track.gapSeconds, drift
                ))
            }
            parts.append(String(format: "cpu=%.1f%% rss=%dMB", cpuPercent, Int(residentBytes / 1_048_576)))
            return parts.joined(separator: " | ")
        }

        public func jsonLine() -> String {
            guard let data = try? JSONCoding.encoder(pretty: false).encode(self) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    public let options: RecordingOptions
    public let id: String
    public private(set) var startedAt: Date?
    public private(set) var timelineStartHostTime: UInt64 = 0
    public private(set) var tappedProcesses: [AudioProcessInfo] = []
    public private(set) var clockDeviceName: String?
    public private(set) var tapStreamDescription: String?
    /// 人間向けイベント（マイク再起動、プロセス追加など）。
    public var onEvent: (@Sendable (String) -> Void)?

    public var onFailure: (@Sendable (CaptureFailure) -> Void)?
    private var captureFailure: CaptureFailure?

    private func reportFailure(_ failure: CaptureFailure) {
        let first = lock.withLock {
            guard captureFailure == nil else { return false }
            captureFailure = failure
            return true
        }
        if first {
            record(event: "capture failed: \(failure.localizedDescription)")
            onFailure?(failure)
        }
    }

    private var uiState: String?

    /// 録音を表示している画面を capture_stats.jsonl に残す（G7 の診断用。画面を出しているときの CPU を分けて見る）。
    public func setUIState(_ state: String?) {
        lock.withLock { uiState = state }
    }

    /// 音声が 5 秒以上届いていないトラック（"system" / "mic"）。片方が途切れても録音は続ける（SPEC §4.3）。
    public func interruptedTracks() -> [String] {
        lock.withLock { watchdog }?.interruptedTracks ?? []
    }

    private func record(_ interruption: CaptureWatchdog.Interruption) {
        switch interruption {
        case let .interrupted(track, since):
            record(event: "\(track) interrupted: no audio since \(TimeFormatting.hms(since)); recording continues")
        case let .recovered(track, seconds):
            record(event: String(format: "%@ recovered after about %.0f s", track, seconds))
        }
    }

    /// 直近チャンクの音量だけを読む（統計のリセットや診断ログの書き込みはしない）。
    public func levels() -> TrackLevels {
        TrackLevels(
            systemDb: systemPipeline?.snapshot(resetIntervalPeak: false).lastRmsDb ?? -120,
            micDb: micPipeline?.snapshot(resetIntervalPeak: false).lastRmsDb ?? -120
        )
    }

    private let lock = NSLock()
    private let controlQueue = DispatchQueue(label: "jp.pictors.minutes.session.control")
    private var tap: SystemAudioCapture?
    private var mic: MicCapture?
    private var systemPipeline: TrackPipeline?
    private var micPipeline: TrackPipeline?
    private var listener: ProcessListListener?
    private var events: [String] = []
    private var usageSampler = ProcessResourceUsage.Sampler()
    private var threadSampler = ThreadCPUSampler()
    private var cpuSamples: [Double] = []
    private var rssMax: UInt64 = 0
    private var stopped = false
    private var diagnosticLog: FileHandle?
    private var watchdog: CaptureWatchdog?

    public init(options: RecordingOptions) {
        self.options = options
        self.id = UUID().uuidString.lowercased()
    }

    public var systemChunks: AsyncStream<AudioChunk>? { options.streamLiveAudio ? systemPipeline?.chunks : nil }
    public var micChunks: AsyncStream<AudioChunk>? { options.streamLiveAudio ? micPipeline?.chunks : nil }

    // MARK: - Lifecycle

    public func start() async throws {
        guard startedAt == nil else { throw AudioCaptureError.invalidState("既に開始しています") }
        if options.includeMic {
            guard await MicCapture.requestPermission() else {
                throw AudioCaptureError.permissionDenied("マイクへのアクセスが許可されていません（システム設定 > プライバシーとセキュリティ > マイク）")
            }
        }
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

        var tapConfiguration: ProcessTap.Configuration?
        if options.includeSystem {
            var configuration = ProcessTap.Configuration()
            configuration.tapAutoStart = options.tapAutoStart
            configuration.clockDeviceUID = options.clockDeviceUID
            if options.allSystemAudio {
                configuration.excludeListedProcesses = true
            } else {
                let processes = try AudioProcessList.resolve(targets: options.targetBundleIdentifiers)
                guard !processes.isEmpty else {
                    throw AudioCaptureError.noMatchingProcess(targets: options.targetBundleIdentifiers)
                }
                tappedProcesses = processes
                configuration.processObjectIDs = processes.map(\.objectID)
                var bundleIDs = options.targetBundleIdentifiers
                for process in processes {
                    if let bundleID = process.bundleID, !bundleIDs.contains(bundleID) { bundleIDs.append(bundleID) }
                }
                configuration.bundleIDs = bundleIDs
            }
            tapConfiguration = configuration
        }

        if options.writeAudioFiles {
            let expected = [options.includeSystem ? "system" : nil, options.includeMic ? "mic" : nil].compactMap { $0 }
            try JSONCoding.encoder().encode(expected).write(to: options.outputDirectory.appendingPathComponent("expected-tracks.json"), options: .atomic)
        }
        let write = options.writeAudioFiles
        let directory = options.outputDirectory
        let t0 = HostClock.now()
        timelineStartHostTime = t0
        startedAt = Date()
        var startupComplete = false
        defer {
            if !startupComplete {
                self.tap?.invalidate()
                self.mic?.stop()
                _ = systemPipeline?.finish()
                _ = micPipeline?.finish()
                try? diagnosticLog?.close()
                diagnosticLog = nil
            }
        }
        if write {
            let logURL = directory.appendingPathComponent("capture_stats.jsonl")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            diagnosticLog = try FileHandle(forWritingTo: logURL)
        }

        if options.includeMic {
            let pipeline = TrackPipeline(
                name: "mic",
                timelineStartHostTime: t0,
                archiveURL: write ? directory.appendingPathComponent(RecordingSession.micArchiveName) : nil,
                sttURL: write ? directory.appendingPathComponent(RecordingSession.micSTTName) : nil,
                aacBitrate: options.aacBitrate,
                streamLiveAudio: options.streamLiveAudio,
                onLiveFailure: { [weak self] message in self?.record(event: message) },
                onFailure: { [weak self] failure in self?.reportFailure(failure) }
            )
            micPipeline = pipeline
            let mic = MicCapture(deviceUID: options.micDeviceUID)
            mic.onConfigurationChange = { [weak self] format in
                if let format {
                    self?.record(event: "mic restarted after device change: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, device=\(mic.activeDeviceName ?? "default")")
                    let capture = self?.lock.withLock { self?.tap }
                    capture?.requestRestart(reason: "microphone configuration")
                } else {
                    // 録音全体は止めない（SPEC §4.3）。MicCapture が停止まで再試行し、途切れは watchdog が知らせる。
                    self?.record(event: "mic restart failed; retrying until an input device is available")
                }
            }
            do {
                try mic.start { chunk in pipeline.enqueue(chunk) }
            } catch {
                self.tap?.invalidate()
                throw error
            }
            self.mic = mic
            if let requested = options.micDeviceUID, mic.activeDeviceUID == nil {
                record(event: "mic device \(requested) not available; using default input (\(mic.activeDeviceName ?? "?"))")
            } else if let name = mic.activeDeviceName {
                record(event: "mic device: \(name)")
            }
        }

        // AirPods の入力を先に起動し、通話モードの交渉後に aggregate を作る。
        // 以後のデバイス変更は SystemAudioCapture が tap / aggregate の再作成まで行う。
        if let configuration = tapConfiguration {
            let tap = SystemAudioCapture(configuration: configuration)
            lock.withLock { self.tap = tap }
            tap.onLayoutObserved = { [weak self] message in self?.record(event: "tap layout: \(message)") }
            tap.onEvent = { [weak self] message in self?.record(event: message) }
            let pipeline = TrackPipeline(
                name: "system",
                timelineStartHostTime: t0,
                archiveURL: write ? directory.appendingPathComponent(RecordingSession.systemArchiveName) : nil,
                sttURL: write ? directory.appendingPathComponent(RecordingSession.systemSTTName) : nil,
                aacBitrate: options.aacBitrate,
                streamLiveAudio: options.streamLiveAudio,
                onLiveFailure: { [weak self] message in self?.record(event: message) },
                onFailure: { [weak self] failure in self?.reportFailure(failure) }
            )
            systemPipeline = pipeline
            do {
                try tap.start { chunk in pipeline.enqueue(chunk) }
            } catch {
                tap.invalidate()
                throw error
            }
            clockDeviceName = tap.clockDeviceName
            tapStreamDescription = tap.streamInfo?.description
        }
        startupComplete = true
        let pipelines = [systemPipeline, micPipeline].compactMap { $0 }
        let watchdog = CaptureWatchdog(startTime: HostClock.seconds(fromHostTime: t0), tapAutoStart: options.tapAutoStart,
                                       snapshots: { pipelines.map { $0.snapshot() } },
                                       onInterruption: { [weak self] interruption in self?.record(interruption) },
                                       onFailure: { [weak self] failure in self?.reportFailure(failure) })
        lock.withLock { self.watchdog = watchdog }

        if options.followNewProcesses, !options.allSystemAudio, tap != nil {
            installProcessListener()
        }
        record(event: "recording started (id \(id))")
    }

    public func snapshot() -> Snapshot {
        let (usage, threads) = lock.withLock { () -> (ProcessResourceUsage, [String: Double]) in
            let sample = usageSampler.sample()
            cpuSamples.append(sample.cpuPercent)
            rssMax = max(rssMax, sample.residentBytes)
            return (sample, threadSampler.sample())
        }
        let elapsed = timelineStartHostTime == 0 ? 0 : HostClock.nowSeconds() - HostClock.seconds(fromHostTime: timelineStartHostTime)
        let snapshot = Snapshot(
            elapsedSeconds: elapsed,
            system: systemPipeline?.snapshot(resetIntervalPeak: true),
            mic: micPipeline?.snapshot(resetIntervalPeak: true),
            cpuPercent: usage.cpuPercent,
            residentBytes: usage.residentBytes,
            tappedProcessCount: tappedProcesses.count,
            ui: lock.withLock { uiState },
            threads: threads.isEmpty ? nil : threads
        )
        lock.withLock {
            if let data = (snapshot.jsonLine() + "\n").data(using: .utf8) { try? diagnosticLog?.write(contentsOf: data) }
        }
        return snapshot
    }

    /// 停止してファイルを閉じ、recording.json を書く。
    @discardableResult
    public func stop() throws -> RecordingManifest {
        guard let startedAt else { throw AudioCaptureError.invalidState("開始していません") }
        let alreadyStopped = lock.withLock { () -> Bool in
            let value = stopped
            stopped = true
            return value
        }
        guard !alreadyStopped else { throw AudioCaptureError.invalidState("既に停止しています") }
        lock.withLock { () -> CaptureWatchdog? in
            defer { watchdog = nil }
            return watchdog
        }?.stop()

        defer {
            lock.withLock {
                try? diagnosticLog?.close()
                diagnosticLog = nil
            }
        }
        removeProcessListener()
        // 再起動後の機器名・形式を停止前に取得する。
        clockDeviceName = tap?.clockDeviceName ?? clockDeviceName
        tapStreamDescription = tap?.streamInfo?.description ?? tapStreamDescription
        tap?.stop()
        let micDeviceName = mic?.activeDeviceName
        mic?.stop()
        let endedAt = Date()
        let duration = HostClock.nowSeconds() - HostClock.seconds(fromHostTime: timelineStartHostTime)
        // 途切れたまま終わったトラックは末尾を無音で埋め、両トラックの長さを録音の終了にそろえる（SPEC §4.3）。
        let padTo = options.writeAudioFiles && lock.withLock({ captureFailure == nil }) ? duration : nil
        let systemStats = systemPipeline?.finish(padTo: padTo)
        let micStats = micPipeline?.finish(padTo: padTo)
        tap?.invalidate()
        lock.withLock { tap = nil }
        mic = nil

        var tracks: [String: TrackStatsSnapshot] = [:]
        if let systemStats { tracks["system"] = systemStats }
        if let micStats { tracks["mic"] = micStats }
        if let failure = lock.withLock({ captureFailure }) { tracks[failure.track]?.failure = failure }
        var files: [String: String] = [:]
        if options.writeAudioFiles {
            if systemStats != nil {
                files["system_archive"] = RecordingSession.systemArchiveName
                files["system_stt"] = RecordingSession.systemSTTName
            }
            if micStats != nil {
                files["mic_archive"] = RecordingSession.micArchiveName
                files["mic_stt"] = RecordingSession.micSTTName
            }
        }
        let usage: ResourceUsageSummary? = lock.withLock {
            guard !cpuSamples.isEmpty else { return nil }
            return ResourceUsageSummary(
                cpuPercentAvg: cpuSamples.reduce(0, +) / Double(cpuSamples.count),
                cpuPercentMax: cpuSamples.max() ?? 0,
                rssMaxBytes: rssMax,
                sampleCount: cpuSamples.count
            )
        }
        record(event: "recording stopped")
        let manifest = RecordingManifest(
            schemaVersion: RecordingManifest.currentSchemaVersion,
            id: id,
            title: options.title,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            targetBundleIdentifiers: options.targetBundleIdentifiers,
            allSystemAudio: options.allSystemAudio,
            tappedProcesses: tappedProcesses,
            clockDevice: clockDeviceName,
            micDevice: options.includeMic ? (micDeviceName ?? MicCapture.defaultInputDeviceName()) : nil,
            tapStream: tapStreamDescription,
            files: files,
            tracks: tracks,
            resourceUsage: usage,
            events: lock.withLock { events }
        )
        try manifest.write(to: options.outputDirectory)
        if let failure = lock.withLock({ captureFailure }) { throw failure }
        for stats in tracks.values {
            try RecordingAudioValidation.validate(stats: stats, recordingDuration: manifest.durationSeconds)
        }
        if options.writeAudioFiles {
            for (role, name) in files {
                let url = options.outputDirectory.appendingPathComponent(name)
                guard let duration = try? AudioFileTools.duration(of: url), duration > 0 else {
                    throw CaptureFailure(track: name, operation: "録音検証", message: "有効な音声が保存されていません")
                }
                if let stats = tracks[role.hasPrefix("system") ? "system" : "mic"] {
                    try RecordingAudioValidation.validate(stats: stats, fileDuration: duration)
                }
            }
        }
        return manifest
    }

    // MARK: - Process following

    private func installProcessListener() {
        let listener = ProcessListListener { [weak self] in self?.refreshTappedProcesses() }
        let system = AudioHardwareSystem.shared
        do {
            system.delegates.append(listener)
            try system.addListener(forProperties: [PropertyAddress(kAudioHardwarePropertyProcessObjectList)], dispatchQueue: controlQueue)
            self.listener = listener
        } catch {
            record(event: "process list listener unavailable: \(error)")
        }
    }

    private func removeProcessListener() {
        guard let listener else { return }
        let system = AudioHardwareSystem.shared
        try? system.removeListener(forProperties: [PropertyAddress(kAudioHardwarePropertyProcessObjectList)], dispatchQueue: controlQueue)
        system.delegates.removeAll { ($0 as? ProcessListListener) === listener }
        self.listener = nil
    }

    private func refreshTappedProcesses() {
        guard let tap = lock.withLock({ stopped ? nil : self.tap }) else { return }
        guard let matches = try? AudioProcessList.resolve(targets: options.targetBundleIdentifiers) else { return }
        let current = Set(tap.currentProcesses)
        let added = matches.filter { !current.contains($0.objectID) }
        guard !added.isEmpty else { return }
        do {
            try tap.setProcesses(Array(current) + added.map(\.objectID))
            lock.withLock {
                for info in added where !tappedProcesses.contains(where: { $0.objectID == info.objectID }) {
                    tappedProcesses.append(info)
                }
            }
            let names = added.map { "\($0.name ?? "?") (pid \($0.pid), \($0.bundleID ?? "-"))" }
            record(event: "tap now includes: \(names.joined(separator: ", "))")
        } catch {
            record(event: "failed to add processes to tap: \(error)")
        }
    }

    private func record(event: String) {
        let line = "\(JSONCoding.iso8601Local(Date())) \(event)"
        lock.withLock { events.append(line) }
        Log.audio.info("\(event, privacy: .public)")
        onEvent?(event)
    }
}

@available(macOS 15.0, *)
final class ProcessListListener: PropertyListenerDelegate, @unchecked Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func propertiesChanged(properties: [AudioObjectPropertyAddress]) {
        onChange()
    }
}
