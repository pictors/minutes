import AVFoundation
import CoreMedia
import Foundation
import Speech
import Synchronization

// SpeechAnalyzer / SpeechTranscriber（macOS 26）のラッパ。
// API は SDK の Speech.swiftinterface で確認済み（2026-09-16）。

public enum SpeechAssets {
    public static let defaultLocale = Locale(identifier: "ja-JP")

    /// ロケールを SpeechTranscriber が受け付ける形に正規化する。
    public static func resolveLocale(_ locale: Locale) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.assetsUnavailable("SpeechTranscriber はこの環境で利用できません")
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.localeUnsupported(locale.identifier)
        }
        return supported
    }

    public static func status(for locale: Locale) async throws -> AssetInventory.Status {
        let resolved = try await resolveLocale(locale)
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        return await AssetInventory.status(forModules: [transcriber])
    }

    public static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// ライブ字幕と同じ設定のモデルを先に入れる（初回の案内で進み具合を見せる。入っていればすぐ返る）。
    public static func prepareLiveTranscription(locale: Locale, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let resolved = try await resolveLocale(locale)
        let transcriber = SpeechTranscriber(locale: resolved, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        try await ensureInstalled(for: [transcriber], locale: resolved, progress: progress)
    }

    /// モデルが未インストールならダウンロードする（SPEC §5.3: 事前ダウンロード）。
    public static func ensureInstalled(for modules: [any SpeechModule], locale: Locale? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let status = await AssetInventory.status(forModules: modules)
        switch status {
        case .installed:
            return
        case .unsupported:
            throw TranscriptionError.assetsUnavailable("このモジュール構成はサポートされていません")
        case .supported, .downloading:
            break
        @unknown default:
            break
        }
        if let locale {
            // 予約しておくと OS によるアセットの自動削除を避けられる
            _ = try? await AssetInventory.reserve(locale: locale)
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        let observer = Task {
            while !Task.isCancelled {
                progress?(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { observer.cancel() }
        try await request.downloadAndInstall()
        progress?(1.0)
    }
}

extension CMTime {
    var secondsOrZero: Double {
        let value = CMTimeGetSeconds(self)
        return value.isFinite ? value : 0
    }
}

/// SpeechTranscriber.Result → TranscriptWord（run 単位、audioTimeRange 付き）。
enum SpeechResultConverter {
    static func words(from result: SpeechTranscriber.Result) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        let text = result.text
        let fallbackStart = result.range.start.secondsOrZero
        let fallbackEnd = result.range.end.secondsOrZero
        for run in text.runs {
            let runText = String(text[run.range].characters)
            if runText.isEmpty { continue }
            let timeRange: CMTimeRange? = run.audioTimeRange
            let confidence: Double? = run.transcriptionConfidence
            let start = timeRange?.start.secondsOrZero ?? fallbackStart
            let end = timeRange?.end.secondsOrZero ?? fallbackEnd
            words.append(TranscriptWord(text: runText, start: start, end: max(end, start), confidence: confidence))
        }
        if words.isEmpty {
            let plain = String(text.characters)
            if !plain.isEmpty {
                words.append(TranscriptWord(text: plain, start: fallbackStart, end: fallbackEnd))
            }
        }
        return words
    }
}

/// 録音中にライブ字幕の言語を切り替える（2026-10-07）。`SpeechAnalyzerLiveTranscriber` は次の音声から、
/// 新しいロケールの認識器で認識し直す（それまでの音声は元のロケールで確定させる）。
public final class LiveLocaleControl: Sendable {
    private let state: Mutex<Locale>

    public init(locale: Locale) {
        state = Mutex(locale)
    }

    public var locale: Locale { state.withLock { $0 } }

    public func set(_ locale: Locale) {
        state.withLock { $0 = locale }
    }
}

/// ライブ字幕の認識器の準備（モデルのダウンロード）の進み具合。画面に出す。
public enum LivePreparation: Sendable, Equatable {
    /// モデルを確かめている・ダウンロードしている（progress は 0〜1、確認中は nil）。
    case preparing(locale: Locale, progress: Double?)
    case ready(locale: Locale)
    /// このロケールに切り替えられなかった（元のロケールで続ける）。
    case failed(locale: Locale, message: String)
}

/// ライブ字幕（SPEC §5.1 Live）。volatile と final の両方を流す。
public final class SpeechAnalyzerLiveTranscriber: LiveTranscriber {
    public let reportVolatile: Bool
    /// SpeechTranscriber.ReportingOption.fastResults（精度より速度を優先した結果報告）。
    public let fastResults: Bool
    public let onStatus: (@Sendable (String) -> Void)?
    public let onPreparation: (@Sendable (LivePreparation) -> Void)?

    public init(reportVolatile: Bool = true, fastResults: Bool = false, onStatus: (@Sendable (String) -> Void)? = nil, onPreparation: (@Sendable (LivePreparation) -> Void)? = nil) {
        self.reportVolatile = reportVolatile
        self.fastResults = fastResults
        self.onStatus = onStatus
        self.onPreparation = onPreparation
    }

    public func start(audio: AsyncStream<AudioChunk>, locale: Locale) -> AsyncThrowingStream<LiveSegment, Error> {
        start(audio: audio, control: LiveLocaleControl(locale: locale))
    }

    /// `control` のロケールが変わったら、今の認識器を閉じて新しいロケールで開き直す。
    /// 開き直す間の音声はストリームにたまり、新しい認識器に続けて渡す（時刻は録音のタイムラインのまま）。
    public func start(audio: AsyncStream<AudioChunk>, control: LiveLocaleControl) -> AsyncThrowingStream<LiveSegment, Error> {
        let options = LiveStage.Options(reportVolatile: reportVolatile, fastResults: fastResults, onStatus: onStatus, onPreparation: onPreparation)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var stage = try await LiveStage.open(locale: control.locale, options: options, continuation: continuation)
                    // 切り替えに失敗したロケール（同じロケールを繰り返し試さない。別の言語を選び直すと、また試す）
                    var failedIdentifier: String?
                    // タイムスタンプは「これまでに供給したフレーム数」から作る。
                    // 入力チャンクの startTime をそのまま使うと、変換器の遅延でバッファ長が揺れたときに
                    // 前のバッファと重なり、SpeechAnalyzer が "timestamp overlaps" で拒否する。
                    var nextStart: CMTime?
                    for await chunk in audio {
                        if Task.isCancelled { break }
                        let requested = control.locale
                        if requested.identifier != stage.requested, requested.identifier != failedIdentifier {
                            let previous = Locale(identifier: stage.requested)
                            try await stage.close()
                            do {
                                stage = try await LiveStage.open(locale: requested, options: options, continuation: continuation)
                                failedIdentifier = nil
                            } catch {
                                if error is CancellationError { throw error }
                                failedIdentifier = requested.identifier
                                options.onPreparation?(.failed(locale: requested, message: error.localizedDescription))
                                options.onStatus?("\(requested.identifier) に切り替えられませんでした: \(error.localizedDescription)")
                                stage = try await LiveStage.open(locale: previous, options: options, continuation: continuation)
                            }
                        } else if requested.identifier == stage.requested {
                            failedIdentifier = nil
                        }
                        guard let buffer = PCMChunk.monoBuffer(samples: chunk.samples, sampleRate: chunk.sampleRate) else { continue }
                        let converted = try stage.resampler.convert(buffer)
                        guard converted.frameLength > 0 else { continue }
                        let startTime = nextStart ?? CMTime(seconds: chunk.startTime, preferredTimescale: stage.timescale)
                        stage.input.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
                        nextStart = CMTimeAdd(startTime, CMTime(value: CMTimeValue(converted.frameLength), timescale: stage.timescale))
                    }
                    try await stage.close()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 1 つのロケールのライブ字幕の認識器（SpeechAnalyzer + SpeechTranscriber）。言語を切り替えるときは閉じて開き直す。
private final class LiveStage {
    struct Options: Sendable {
        var reportVolatile: Bool
        var fastResults: Bool
        var onStatus: (@Sendable (String) -> Void)?
        var onPreparation: (@Sendable (LivePreparation) -> Void)?
    }

    /// 開くときに頼んだロケールの識別子（解決後の識別子ではなく、切り替えの判定に使う）。
    let requested: String
    let analyzer: SpeechAnalyzer
    let input: AsyncStream<AnalyzerInput>.Continuation
    let results: Task<Void, any Error>
    let resampler: Resampler
    let timescale: CMTimeScale

    private init(requested: String, analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, results: Task<Void, any Error>, resampler: Resampler, timescale: CMTimeScale) {
        self.requested = requested
        self.analyzer = analyzer
        self.input = input
        self.results = results
        self.resampler = resampler
        self.timescale = timescale
    }

    static func open(locale: Locale, options: Options, continuation: AsyncThrowingStream<LiveSegment, Error>.Continuation) async throws -> LiveStage {
        let resolved = try await SpeechAssets.resolveLocale(locale)
        var reporting: Set<SpeechTranscriber.ReportingOption> = []
        if options.reportVolatile { reporting.insert(.volatileResults) }
        if options.fastResults { reporting.insert(.fastResults) }
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: reporting,
            attributeOptions: [.audioTimeRange]
        )
        options.onStatus?("モデル確認中 (\(resolved.identifier))")
        options.onPreparation?(.preparing(locale: locale, progress: nil))
        try await SpeechAssets.ensureInstalled(for: [transcriber], locale: resolved) { fraction in
            options.onStatus?(String(format: "モデルをダウンロード中 %.0f%%", fraction * 100))
            options.onPreparation?(.preparing(locale: locale, progress: fraction))
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.assetsUnavailable("互換オーディオ形式がありません")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task {
            for try await result in transcriber.results {
                continuation.yield(LiveSegment(
                    text: String(result.text.characters),
                    isFinal: result.isFinal,
                    start: result.range.start.secondsOrZero,
                    end: result.range.end.secondsOrZero,
                    receivedAt: HostClock.nowSeconds()
                ))
            }
        }
        try await analyzer.start(inputSequence: inputSequence)
        options.onStatus?("認識開始 (\(resolved.identifier), format: \(Int(analyzerFormat.sampleRate)) Hz, \(analyzerFormat.channelCount) ch)")
        options.onPreparation?(.ready(locale: locale))
        return LiveStage(requested: locale.identifier, analyzer: analyzer, input: inputBuilder, results: results,
                         resampler: Resampler(outputFormat: analyzerFormat), timescale: CMTimeScale(analyzerFormat.sampleRate))
    }

    /// 入力を閉じて、ここまでの音声を確定させる（volatile を final にしてから結果のストリームを終える）。
    func close() async throws {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results.value
    }
}

/// ファイルモードの SpeechAnalyzer（Local プロバイダの STT 部分、SPEC §5.3 Local）。
public struct SpeechAnalyzerFileTranscriber: Sendable {
    public var locale: Locale
    public var onStatus: (@Sendable (String) -> Void)?

    public init(locale: Locale = SpeechAssets.defaultLocale, onStatus: (@Sendable (String) -> Void)? = nil) {
        self.locale = locale
        self.onStatus = onStatus
    }

    public struct Output: Sendable {
        public var words: [TranscriptWord]
        /// 認識結果 1 件 = 1 セグメント（話者なし）。
        public var segments: [TranscriptSegment]
        public var resolvedLocale: Locale
    }

    public func transcribe(fileURL: URL) async throws -> Output {
        let resolved = try await SpeechAssets.resolveLocale(locale)
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        try await SpeechAssets.ensureInstalled(for: [transcriber], locale: resolved) { [onStatus] fraction in
            onStatus?(String(format: "モデルをダウンロード中 %.0f%%", fraction * 100))
        }
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionError.unsupportedAudio("\(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () -> ([TranscriptWord], [TranscriptSegment]) in
            var words: [TranscriptWord] = []
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                let resultWords = SpeechResultConverter.words(from: result)
                words.append(contentsOf: resultWords)
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let confidences = resultWords.compactMap(\.confidence)
                    segments.append(TranscriptSegment(
                        start: result.range.start.secondsOrZero,
                        end: result.range.end.secondsOrZero,
                        text: text,
                        speakerLabel: nil,
                        confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                    ))
                }
            }
            return (words, segments)
        }

        onStatus?("SpeechAnalyzer 解析中 (\(resolved.identifier))")
        if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let (words, segments) = try await collector.value
        return Output(words: words.sorted { $0.start < $1.start }, segments: segments.sorted { $0.start < $1.start }, resolvedLocale: resolved)
    }
}
