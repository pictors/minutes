import Foundation

// SPEC §5.2 のプロトコルと型。提供元（ElevenLabs / OpenAI / Local）を差し替え可能にする。

/// 参照音声付きの既知話者（OpenAI の known_speaker_* に対応）。
public struct KnownSpeaker: Sendable, Equatable {
    public var name: String
    /// 2〜10 秒の参照音声（wav / m4a）。
    public var referenceAudioURL: URL

    public init(name: String, referenceAudioURL: URL) {
        self.name = name
        self.referenceAudioURL = referenceAudioURL
    }
}

public struct TranscriptionRequest: Sendable {
    /// 16 kHz mono の音声ファイル。
    public var audioURL: URL
    /// ISO 639-1（"ja"）。
    public var language: String
    public var diarize: Bool
    /// 参加者名・業界用語。
    public var keyterms: [String]
    public var knownSpeakers: [KnownSpeaker]

    public init(audioURL: URL, language: String = "ja", diarize: Bool = true, keyterms: [String] = [], knownSpeakers: [KnownSpeaker] = []) {
        self.audioURL = audioURL
        self.language = language
        self.diarize = diarize
        self.keyterms = keyterms
        self.knownSpeakers = knownSpeakers
    }
}

/// 話者ラベル付きのセグメント。時刻は音声ファイル先頭からの秒。
public struct TranscriptSegment: Sendable, Codable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    /// プロバイダの話者ラベルを正規化したもの（"spk_0" 等）。mic トラックは "me"。未分離なら nil。
    public var speakerLabel: String?
    public var confidence: Double?

    public init(start: Double, end: Double, text: String, speakerLabel: String? = nil, confidence: Double? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speakerLabel = speakerLabel
        self.confidence = confidence
    }

    public var duration: Double { max(0, end - start) }
}

public struct TranscriptWord: Sendable, Codable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var speakerLabel: String?
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, speakerLabel: String? = nil, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speakerLabel = speakerLabel
        self.confidence = confidence
    }
}

public struct TranscriptionResult: Sendable, Codable, Equatable {
    public var segments: [TranscriptSegment]
    public var words: [TranscriptWord]?
    /// モデル名、リクエスト id など（ログ・比較表用）。
    public var providerMeta: [String: String]

    public init(segments: [TranscriptSegment], words: [TranscriptWord]? = nil, providerMeta: [String: String] = [:]) {
        self.segments = segments
        self.words = words
        self.providerMeta = providerMeta
    }

    /// 出現順に話者ラベルを列挙する。
    public var speakerLabels: [String] {
        var seen: [String] = []
        for segment in segments {
            if let label = segment.speakerLabel, !seen.contains(label) { seen.append(label) }
        }
        return seen
    }

    /// 切り出した音声の結果を、元の録音タイムラインに戻す（時刻を `offset` 秒ずらす）。
    public func shifted(by offset: Double) -> TranscriptionResult {
        guard offset != 0 else { return self }
        var copy = self
        copy.segments = segments.map { segment in
            var moved = segment
            moved.start += offset
            moved.end += offset
            return moved
        }
        copy.words = words?.map { word in
            var moved = word
            moved.start += offset
            moved.end += offset
            return moved
        }
        return copy
    }
}

public protocol BatchTranscriber: Sendable {
    /// "elevenlabs.scribe_v2" / "openai.gpt-4o-transcribe-diarize" / "local.speechanalyzer+fluidaudio"
    var id: String { get }
    var runsLocally: Bool { get }
    var cacheIdentity: String { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

public extension BatchTranscriber {
    var cacheIdentity: String { id }
}

/// 16 kHz mono Float32 の音声チャンク（STT 用の内部形式、SPEC §4.3）。
public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    /// 録音タイムライン上の開始時刻（秒）。
    public var startTime: Double

    public init(samples: [Float], sampleRate: Double, startTime: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
    }

    public var duration: Double { Double(samples.count) / sampleRate }
}

/// ライブ字幕の 1 結果。volatile（途中）と final（確定）の両方が流れる。
public struct LiveSegment: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    /// 音声タイムライン上の範囲（秒）。
    public var start: Double
    public var end: Double
    /// 結果を受信したホスト時刻（秒）。遅延計測用。
    public var receivedAt: Double

    public init(text: String, isFinal: Bool, start: Double, end: Double, receivedAt: Double) {
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
        self.receivedAt = receivedAt
    }
}

public protocol LiveTranscriber: Sendable {
    func start(audio: AsyncStream<AudioChunk>, locale: Locale) -> AsyncThrowingStream<LiveSegment, Error>
}

public enum TranscriptionError: Error, LocalizedError, Equatable {
    case missingAPIKey(provider: String, envName: String)
    case httpError(provider: String, status: Int, body: String, requestID: String?)
    case invalidResponse(provider: String, detail: String)
    case audioTooLarge(bytes: Int, limit: Int)
    case unsupportedAudio(String)
    case localeUnsupported(String)
    case assetsUnavailable(String)
    case diarizationFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .missingAPIKey(provider, envName):
            return "\(provider) の API キーがありません。環境変数または .env に \(envName) を設定してください。"
        case let .httpError(provider, status, body, requestID):
            let id = requestID.map { " request-id=\($0)" } ?? ""
            return "\(provider) が HTTP \(status) を返しました\(id): \(Log.preview(body, limit: 300))"
        case let .invalidResponse(provider, detail):
            return "\(provider) のレスポンスを解釈できません: \(detail)"
        case let .audioTooLarge(bytes, limit):
            return "音声ファイルが大きすぎます (\(bytes) bytes > \(limit) bytes)"
        case let .unsupportedAudio(detail):
            return "音声を読めません: \(detail)"
        case let .localeUnsupported(locale):
            return "SpeechTranscriber がロケール \(locale) をサポートしていません"
        case let .assetsUnavailable(detail):
            return "音声認識モデルが利用できません: \(detail)"
        case let .diarizationFailed(detail):
            return "話者分離に失敗しました: \(detail)"
        case .cancelled:
            return "キャンセルされました"
        }
    }
}
