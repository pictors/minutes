import Foundation

/// Local プロバイダ: SpeechAnalyzer（ファイルモード）+ FluidAudio 話者分離（SPEC §5.3 Local）。
/// privacy_mode = local_only の会議、およびクラウド失敗時のフォールバック。音声は端末外に出ない。
public struct LocalTranscriber: BatchTranscriber {
    public let id = "local.speechanalyzer+fluidaudio"
    public let runsLocally = true
    public var locale: Locale
    public var numSpeakers: Int?
    /// FluidAudio のクラスタリング閾値（nil = 既定 0.6）。
    public var clusteringThreshold: Double?
    public var foldingOptions: SegmentFoldingOptions
    public var onStatus: (@Sendable (String) -> Void)?

    public init(locale: Locale = SpeechAssets.defaultLocale, numSpeakers: Int? = nil, clusteringThreshold: Double? = nil, foldingOptions: SegmentFoldingOptions = SegmentFoldingOptions(), onStatus: (@Sendable (String) -> Void)? = nil) {
        self.locale = locale
        self.numSpeakers = numSpeakers
        self.clusteringThreshold = clusteringThreshold
        self.foldingOptions = foldingOptions
        self.onStatus = onStatus
    }

    public var cacheIdentity: String {
        "\(id)/\(locale.identifier)/\(String(describing: numSpeakers))/\(String(describing: clusteringThreshold))/\(foldingOptions.maxPause)/\(foldingOptions.maxDuration)/\(foldingOptions.sentenceSplitMinDuration)/\(foldingOptions.sentenceEnders.sorted().map(String.init).joined())"
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let started = Date()
        // 会議の言語（日本語・英語）に合わせる。CLI で別の言語のロケールを指定したときはそれを使う
        var locale = self.locale
        if let language = MeetingLanguage(code: request.language), MeetingLanguage(code: locale.identifier) != language {
            locale = language.locale
        }
        let stt = SpeechAnalyzerFileTranscriber(locale: locale, onStatus: onStatus)
        let output = try await stt.transcribe(fileURL: request.audioURL)
        var meta: [String: String] = [
            "provider": id,
            "stt": "apple.speechanalyzer",
            "locale": output.resolvedLocale.identifier,
            "word_count": String(output.words.count),
        ]
        let sttElapsed = Date().timeIntervalSince(started)
        meta["stt_elapsed_seconds"] = String(format: "%.1f", sttElapsed)

        var words = output.words
        var segments: [TranscriptSegment]
        if request.diarize {
            onStatus?("FluidAudio 話者分離中")
            let diarizeStarted = Date()
            let samples = try AudioFileTools.loadMono16k(request.audioURL)
            let turns = try await FluidAudioDiarizer.diarize(samples: samples, numSpeakers: numSpeakers, clusteringThreshold: clusteringThreshold) { [onStatus] done, total in
                onStatus?("話者分離 \(done)/\(total)")
            }
            meta["diarizer"] = FluidAudioDiarizer.identifier
            if let numSpeakers { meta["num_speakers"] = String(numSpeakers) }
            if let clusteringThreshold { meta["cluster_threshold"] = String(clusteringThreshold) }
            meta["diarize_elapsed_seconds"] = String(format: "%.1f", Date().timeIntervalSince(diarizeStarted))
            meta["diarization_turns"] = String(turns.count)
            words = SpeakerOverlap.assign(words: words, turns: turns)
            segments = SegmentFolder.fold(words: words, options: foldingOptions)
        } else {
            segments = output.segments
        }
        meta["elapsed_seconds"] = String(format: "%.1f", Date().timeIntervalSince(started))
        return TranscriptionResult(segments: segments, words: words, providerMeta: meta)
    }
}
