@preconcurrency import AVFAudio
import Foundation
import MinutesKit

/// 録音の形。サーバーが受け取る形と同じ AAC 16 kHz mono 32 kbps で、拡張子 .aac に書くと ADTS になる
/// （書いている途中も前から足していくだけなので、増えた分を区切りにして送れる。2026-11-22 の確認と MinutesCloudUploadTests）。
enum RecordingFormat {
    static var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    static func makeFile(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}

enum CaptureError: Error, LocalizedError {
    case noInput
    case converter
    case fixtureMissing(String)

    var errorDescription: String? {
        switch self {
        case .noInput: "マイクが使えません"
        case .converter: "録音の形を変換できません"
        case let .fixtureMissing(path): "開発用の音声が見つかりません: \(path)"
        }
    }
}

/// 1 つの走（中断までのひと続き）の音声を、ファイルに書き足していく入力。
protocol AudioCapture: AnyObject, Sendable {
    /// 書き込みを始める（ADTS の .aac）
    func start(writingTo url: URL) throws
    /// 止めてファイルを閉じる。録れた秒数を返す
    func stop() -> Double
    /// 今の音量（0〜1、表示用）
    var level: Float { get }
    /// 録音が途中で止まった（音声の経路の変化・書き込みの失敗）。録音する側は走を閉じて、新しい走で続ける
    var onStopped: (@Sendable () -> Void)? { get set }
}

/// 入力の音声を録音の形に変換してファイルに書く（マイクと開発用の音声で共通）。
private final class EncodingWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private(set) var frames: AVAudioFramePosition = 0
    private(set) var level: Float = 0
    private(set) var failure: Error?
    /// 初めて失敗したときに一度だけ呼ぶ
    var onFailure: (@Sendable () -> Void)?

    init(url: URL, inputFormat: AVAudioFormat) throws {
        file = try RecordingFormat.makeFile(at: url)
        guard let converter = AVAudioConverter(from: inputFormat, to: file.processingFormat) else { throw CaptureError.converter }
        self.converter = converter
    }

    var seconds: Double { Double(frames) / file.processingFormat.sampleRate }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard failure == nil, buffer.frameLength > 0 else { return }
        let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
        let supplied = SuppliedFlag()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied.value {
                status.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            fail(error)
            return
        }
        guard output.frameLength > 0 else { return }
        do {
            try file.write(from: output)
            frames += AVAudioFramePosition(output.frameLength)
            level = Self.level(output)
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        Log.audio.error("recording_write_failed \(String(describing: type(of: error)), privacy: .public)")
        onFailure?()
    }

    func close() {
        file.close()
    }

    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // -50 dB〜0 dB を 0〜1 に
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 50))
    }

    private final class SuppliedFlag: @unchecked Sendable {
        var value = false
    }
}

/// マイク（AVAudioEngine の入力）。シミュレータでは使わない（Mac のマイクになるので、CloudEnvironment と MeetingRecorder が止める）。
final class MicrophoneCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var writer: EncodingWriter?
    private var configurationObserver: NSObjectProtocol?
    var onStopped: (@Sendable () -> Void)?

    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        let writer = try EncodingWriter(url: url, inputFormat: format)
        writer.onFailure = { [weak self] in self?.onStopped?() }
        lock.withLock { self.writer = writer }
        // 音声の経路が変わる（AirPods をつないだなど）と、エンジンは止まる。走を閉じて新しい形で録り直してもらう
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Log.audio.notice("recording_engine_configuration_change")
            self?.onStopped?()
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.withLock { self.writer?.write(buffer) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock {
                self.writer?.close()
                self.writer = nil
            }
            throw error
        }
    }

    func stop() -> Double {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock {
            let seconds = writer?.seconds ?? 0
            writer?.close()
            writer = nil
            return seconds
        }
    }

    var level: Float { lock.withLock { writer?.level ?? 0 } }
}

/// 開発用: 架空の会議の音声ファイルを、録音の代わりに時間どおり（speed 倍）書き足す（シミュレータで部屋の音を録らないため）。
/// 走が分かれても、音声の続きから書く。DEBUG のビルドで、環境変数 MINUTES_FIXTURE_AUDIO を指定したときだけ使う。
final class FixtureCapture: AudioCapture, @unchecked Sendable {
    static let sourceEnvName = "MINUTES_FIXTURE_AUDIO"
    static let speedEnvName = "MINUTES_FIXTURE_SPEED"

    private let source: AVAudioFile
    private let speed: Double
    private let queue = DispatchQueue(label: "jp.pictors.minutes.fixture")
    private let lock = NSLock()
    private var writer: EncodingWriter?
    private var timer: DispatchSourceTimer?
    var onStopped: (@Sendable () -> Void)?

    init(sourceURL: URL, speed: Double) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw CaptureError.fixtureMissing(sourceURL.path) }
        source = try AVAudioFile(forReading: sourceURL)
        self.speed = max(0.1, speed)
    }

    /// 環境変数から作る（DEBUG のビルドだけ。指定がなければ nil）。
    static func fromEnvironment() throws -> FixtureCapture? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[sourceEnvName], !path.isEmpty else { return nil }
        return try FixtureCapture(sourceURL: URL(fileURLWithPath: path), speed: environment[speedEnvName].flatMap(Double.init) ?? 1)
        #else
        return nil
        #endif
    }

    func start(writingTo url: URL) throws {
        let writer = try EncodingWriter(url: url, inputFormat: source.processingFormat)
        lock.withLock { self.writer = writer }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 0.25
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.pump(seconds: interval) }
        self.timer = timer
        timer.resume()
    }

    private func pump(seconds: Double) {
        let count = AVAudioFrameCount(source.processingFormat.sampleRate * seconds * speed)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count) else { return }
        lock.withLock {
            guard let writer, source.framePosition < source.length else { return }
            do {
                try source.read(into: buffer, frameCount: count)
                writer.write(buffer)
            } catch {
                return
            }
        }
    }

    func stop() -> Double {
        timer?.cancel()
        timer = nil
        return queue.sync {
            lock.withLock {
                let seconds = writer?.seconds ?? 0
                writer?.close()
                writer = nil
                return seconds
            }
        }
    }

    var level: Float { lock.withLock { writer?.level ?? 0 } }
}
