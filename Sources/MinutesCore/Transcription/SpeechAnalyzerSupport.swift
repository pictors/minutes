import AVFoundation
import CoreMedia
import Foundation
import Speech

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

/// ライブ字幕（SPEC §5.1 Live）。volatile と final の両方を流す。
public final class SpeechAnalyzerLiveTranscriber: LiveTranscriber {
    public let reportVolatile: Bool
    /// SpeechTranscriber.ReportingOption.fastResults（精度より速度を優先した結果報告）。
    public let fastResults: Bool
    public let onStatus: (@Sendable (String) -> Void)?

    public init(reportVolatile: Bool = true, fastResults: Bool = false, onStatus: (@Sendable (String) -> Void)? = nil) {
        self.reportVolatile = reportVolatile
        self.fastResults = fastResults
        self.onStatus = onStatus
    }

    public func start(audio: AsyncStream<AudioChunk>, locale: Locale) -> AsyncThrowingStream<LiveSegment, Error> {
        let reportVolatile = self.reportVolatile
        let fastResults = self.fastResults
        let onStatus = self.onStatus
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let resolved = try await SpeechAssets.resolveLocale(locale)
                    var reporting: Set<SpeechTranscriber.ReportingOption> = []
                    if reportVolatile { reporting.insert(.volatileResults) }
                    if fastResults { reporting.insert(.fastResults) }
                    let transcriber = SpeechTranscriber(
                        locale: resolved,
                        transcriptionOptions: [],
                        reportingOptions: reporting,
                        attributeOptions: [.audioTimeRange]
                    )
                    onStatus?("モデル確認中 (\(resolved.identifier))")
                    try await SpeechAssets.ensureInstalled(for: [transcriber], locale: resolved) { fraction in
                        onStatus?(String(format: "モデルをダウンロード中 %.0f%%", fraction * 100))
                    }
                    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                        throw TranscriptionError.assetsUnavailable("互換オーディオ形式がありません")
                    }
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

                    let resultsTask = Task {
                        for try await result in transcriber.results {
                            let segment = LiveSegment(
                                text: String(result.text.characters),
                                isFinal: result.isFinal,
                                start: result.range.start.secondsOrZero,
                                end: result.range.end.secondsOrZero,
                                receivedAt: HostClock.nowSeconds()
                            )
                            continuation.yield(segment)
                        }
                    }

                    try await analyzer.start(inputSequence: inputSequence)
                    onStatus?("認識開始 (format: \(Int(analyzerFormat.sampleRate)) Hz, \(analyzerFormat.channelCount) ch)")

                    // タイムスタンプは「これまでに供給したフレーム数」から作る。
                    // 入力チャンクの startTime をそのまま使うと、変換器の遅延でバッファ長が揺れたときに
                    // 前のバッファと重なり、SpeechAnalyzer が "timestamp overlaps" で拒否する。
                    let resampler = Resampler(outputFormat: analyzerFormat)
                    let timescale = CMTimeScale(analyzerFormat.sampleRate)
                    var fedFrames: Int64 = 0
                    var timelineOffset: CMTime?
                    for await chunk in audio {
                        if Task.isCancelled { break }
                        guard let buffer = PCMChunk.monoBuffer(samples: chunk.samples, sampleRate: chunk.sampleRate) else { continue }
                        let converted = try resampler.convert(buffer)
                        guard converted.frameLength > 0 else { continue }
                        if timelineOffset == nil {
                            timelineOffset = CMTime(seconds: chunk.startTime, preferredTimescale: timescale)
                        }
                        let startTime = CMTimeAdd(timelineOffset ?? .zero, CMTime(value: fedFrames, timescale: timescale))
                        inputBuilder.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
                        fedFrames += Int64(converted.frameLength)
                    }
                    inputBuilder.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    try await resultsTask.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
