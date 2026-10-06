import Foundation

/// ElevenLabs Scribe v2（SPEC §5.3）。
/// 公式仕様（2026-09-16 確認、https://api.elevenlabs.io/openapi.json）:
///   POST /v1/speech-to-text（multipart）、ヘッダ `xi-api-key`
///   フィールド: model_id, file, language_code, diarize, num_speakers, timestamps_granularity(word),
///             keyterms（同名パートを語ごとに繰り返す、最大 1000）, tag_audio_events
///   レスポンス: language_code, language_probability, text, words[]{text,type,logprob,start,end,speaker_id}, transcription_id
///   ログ用ヘッダ: request-id, x-trace-id
public struct ElevenLabsTranscriber: BatchTranscriber {
    public static let defaultModelID = "scribe_v2"
    public static let apiKeyEnvName = "ELEVENLABS_API_KEY"
    public static let maxKeyterms = 1000

    public let id: String
    public let runsLocally = false
    public var apiKey: String
    public var modelID: String
    public var baseURL: URL
    /// 話者数が分かっている場合に指定（1〜32）。
    public var numSpeakers: Int?
    /// 笑い声などのイベントタグ。文字起こしの CER 評価では邪魔なので既定 false。
    public var tagAudioEvents: Bool
    public var foldingOptions: SegmentFoldingOptions
    public var session: URLSession

    public init(
        apiKey: String,
        modelID: String = ElevenLabsTranscriber.defaultModelID,
        baseURL: URL = URL(string: "https://api.elevenlabs.io")!,
        numSpeakers: Int? = nil,
        tagAudioEvents: Bool = false,
        foldingOptions: SegmentFoldingOptions = SegmentFoldingOptions(),
        session: URLSession = .longUpload
    ) {
        self.id = "elevenlabs.\(modelID)"
        self.apiKey = apiKey
        self.modelID = modelID
        self.baseURL = baseURL
        self.numSpeakers = numSpeakers
        self.tagAudioEvents = tagAudioEvents
        self.foldingOptions = foldingOptions
        self.session = session
    }

    public var cacheIdentity: String { "\(modelID)/\(baseURL)/\(String(describing: numSpeakers))/\(tagAudioEvents)/\(foldingOptions.maxPause)/\(foldingOptions.maxDuration)/\(foldingOptions.sentenceSplitMinDuration)/\(foldingOptions.sentenceEnders.sorted().map(String.init).joined())" }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        // WAV は送る前に FLAC（可逆）へ写す。送信量が 4 割前後になり、認識結果は変わらない（G3）。変換できなければ WAV のまま送る。
        var flacDirectory: URL?
        defer { if let flacDirectory { try? FileManager.default.removeItem(at: flacDirectory) } }
        var audioURL = request.audioURL
        if audioURL.pathExtension.lowercased() == "wav" {
            do {
                audioURL = try AudioFileTools.flacCopy(of: request.audioURL)
                flacDirectory = audioURL.deletingLastPathComponent()
            } catch {
                Log.network.error("FLAC conversion failed; sending WAV: \(error.localizedDescription, privacy: .public)")
            }
        }
        let fileSize = try AudioFileTools.fileSize(audioURL)
        let ext = audioURL.pathExtension

        var form = MultipartFormData()
        form.addField(name: "model_id", value: modelID)
        form.addField(name: "language_code", value: request.language)
        form.addField(name: "diarize", value: request.diarize ? "true" : "false")
        form.addField(name: "timestamps_granularity", value: "word")
        form.addField(name: "tag_audio_events", value: tagAudioEvents ? "true" : "false")
        if request.diarize, let numSpeakers {
            form.addField(name: "num_speakers", value: String(numSpeakers))
        }
        for term in request.keyterms.prefix(ElevenLabsTranscriber.maxKeyterms) {
            form.addField(name: "keyterms", value: term)
        }
        form.addFile(
            name: "file",
            filename: audioURL.lastPathComponent,
            contentType: MultipartFormData.mimeType(forExtension: ext),
            url: audioURL
        )

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/speech-to-text"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        Log.network.info("ElevenLabs upload: \(fileSize, privacy: .public) bytes (\(ext, privacy: .public)), diarize=\(request.diarize, privacy: .public)")
        let started = Date()
        // body は一時ファイルから流す（音声をメモリに 2 重に持たない）
        let bodyURL = try form.writeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let timing = UploadTimingDelegate()
        let (data, response) = try await session.upload(for: urlRequest, fromFile: bodyURL, delegate: timing)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse(provider: id, detail: "HTTP レスポンスではありません")
        }
        let requestID = http.value(forHTTPHeaderField: "request-id") ?? http.value(forHTTPHeaderField: "x-trace-id")
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.httpError(provider: id, status: http.statusCode, body: String(decoding: data, as: UTF8.self), requestID: requestID)
        }

        let decoded = try ElevenLabsTranscriber.parseResponse(data)
        var meta: [String: String] = [
            "provider": id,
            "model_id": modelID,
            "elapsed_seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
            "language_code": decoded.languageCode ?? "",
        ]
        if let probability = decoded.languageProbability { meta["language_probability"] = String(format: "%.3f", probability) }
        if let requestID { meta["request_id"] = requestID }
        if let transcriptionID = decoded.transcriptionId { meta["transcription_id"] = transcriptionID }
        if let duration = decoded.audioDurationSecs { meta["audio_duration_secs"] = String(format: "%.1f", duration) }
        meta["upload_format"] = ext
        meta["upload_bytes"] = String(fileSize)
        if let measured = timing.timing {
            meta.merge(measured.metadata) { _, new in new }
            Log.network.info("ElevenLabs timing: \(measured.summary, privacy: .public)")
        }
        return ElevenLabsTranscriber.makeResult(from: decoded, foldingOptions: foldingOptions, meta: meta)
    }

    // MARK: - Response

    public struct Response: Decodable, Sendable {
        public struct Word: Decodable, Sendable {
            public var text: String
            /// "word" | "spacing" | "audio_event"
            public var type: String
            public var logprob: Double?
            public var start: Double?
            public var end: Double?
            public var speakerId: String?
        }

        public var languageCode: String?
        public var languageProbability: Double?
        public var text: String
        public var words: [Word]
        public var transcriptionId: String?
        public var audioDurationSecs: Double?
    }

    public static func parseResponse(_ data: Data) throws -> Response {
        do {
            return try JSONCoding.decoder().decode(Response.self, from: data)
        } catch {
            throw TranscriptionError.invalidResponse(provider: "elevenlabs", detail: "\(error)")
        }
    }

    /// words[] を TranscriptWord / TranscriptSegment に畳む。audio_event は除外する。
    public static func makeResult(from response: Response, foldingOptions: SegmentFoldingOptions = SegmentFoldingOptions(), meta: [String: String] = [:]) -> TranscriptionResult {
        var words: [TranscriptWord] = []
        words.reserveCapacity(response.words.count)
        var lastEnd = 0.0
        for word in response.words where word.type != "audio_event" {
            let start = word.start ?? lastEnd
            let end = word.end ?? start
            lastEnd = max(lastEnd, end)
            let confidence = word.logprob.map { exp($0) }
            words.append(TranscriptWord(text: word.text, start: start, end: end, speakerLabel: word.speakerId, confidence: confidence))
        }
        let segments = SegmentFolder.fold(words: words, options: foldingOptions)
        return TranscriptionResult(segments: segments, words: words, providerMeta: meta)
    }
}

public extension URLSession {
    /// 長時間アップロード用（60 分の音声を送る）。
    static let longUpload: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()
}
