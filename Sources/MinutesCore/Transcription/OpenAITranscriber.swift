import Foundation

/// OpenAI gpt-4o-transcribe-diarize（SPEC §5.3）。
/// 公式仕様（2026-09-16 確認、developers.openai.com/api/reference/.../transcriptions/methods/create）:
///   POST /v1/audio/transcriptions（multipart）、`Authorization: Bearer`
///   file（拡張子付き filename と Content-Type 必須）, model, response_format=diarized_json,
///   chunking_strategy=auto（30 秒超は必須）, language,
///   known_speaker_names[] / known_speaker_references[]（data URL、各 2〜10 秒、最大 4 人）
///   prompt / timestamp_granularities[] / include[] はこのモデルでは非対応。
///   レスポンス: task, duration, text, segments[]{id,type,start,end,text,speaker}
///   話者ラベル: 既知話者はその名前、未知は "A","B",… 。上限 25 MB → AAC 32 kbps に再エンコードして送る。
public struct OpenAITranscriber: BatchTranscriber {
    public static let defaultModel = "gpt-4o-transcribe-diarize"
    public static let apiKeyEnvName = "OPENAI_API_KEY"
    public static let maxUploadBytes = 25 * 1024 * 1024
    public static let maxKnownSpeakers = 4
    public static let knownSpeakerMaxSeconds = 10.0
    public static let knownSpeakerMinSeconds = 2.0
    /// 送信用 AAC のビットレート（約 14 MB/時）。
    public static let uploadBitrate = 32_000

    public let id: String
    public let runsLocally = false
    public var apiKey: String
    public var model: String
    public var baseURL: URL
    public var temperature: Double?
    public var session: URLSession
    /// 再エンコード後も 25 MB を超える場合の分割長（秒）。無音位置で前後にずらす。
    public var chunkTargetSeconds: Double = 50 * 60

    public init(
        apiKey: String,
        model: String = OpenAITranscriber.defaultModel,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        temperature: Double? = nil,
        session: URLSession = .longUpload
    ) {
        self.id = "openai.\(model)"
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.temperature = temperature
        self.session = session
    }

    public var cacheIdentity: String { "\(model)/\(baseURL)/\(String(describing: temperature))/\(chunkTargetSeconds)" }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let prepared = try OpenAITranscriber.prepareUpload(audioURL: request.audioURL, chunkTargetSeconds: chunkTargetSeconds)
        defer { prepared.cleanup() }

        let knownSpeakers = try request.knownSpeakers.prefix(OpenAITranscriber.maxKnownSpeakers).map { speaker in
            (name: speaker.name, dataURL: try OpenAITranscriber.referenceDataURL(for: speaker.referenceAudioURL))
        }

        var allSegments: [TranscriptSegment] = []
        var meta: [String: String] = ["provider": id, "model": model, "chunks": String(prepared.chunks.count)]
        if prepared.transcoded { meta["upload_format"] = "aac \(OpenAITranscriber.uploadBitrate / 1000) kbps mono" }
        let started = Date()
        var totalDuration = 0.0

        for (index, chunk) in prepared.chunks.enumerated() {
            let (decoded, requestID) = try await upload(fileURL: chunk.url, request: request, knownSpeakers: knownSpeakers)
            if let requestID { meta["request_id_\(index)"] = requestID }
            totalDuration += decoded.duration ?? 0
            // 複数チャンクかつ既知話者なしの場合、チャンク間で話者 id は揃わない（SPEC §5.3 の注記）。
            // ラベルにチャンク番号を付けて区別し、手動割当で統合する。
            let prefix = (prepared.chunks.count > 1 && knownSpeakers.isEmpty) ? "c\(index)_" : ""
            let knownNames = Set(knownSpeakers.map(\.name))
            for segment in decoded.segments {
                let label: String? = segment.speaker.map { knownNames.contains($0) ? $0 : prefix + $0 }
                allSegments.append(TranscriptSegment(
                    start: segment.start + chunk.offset,
                    end: segment.end + chunk.offset,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    speakerLabel: label,
                    confidence: nil
                ))
            }
        }
        meta["elapsed_seconds"] = String(format: "%.1f", Date().timeIntervalSince(started))
        meta["audio_duration_secs"] = String(format: "%.1f", totalDuration)
        return TranscriptionResult(segments: allSegments.filter { !$0.text.isEmpty }, words: nil, providerMeta: meta)
    }

    private func upload(fileURL: URL, request: TranscriptionRequest, knownSpeakers: [(name: String, dataURL: String)]) async throws -> (DiarizedResponse, String?) {
        let fileSize = try AudioFileTools.fileSize(fileURL)
        guard fileSize <= OpenAITranscriber.maxUploadBytes else {
            throw TranscriptionError.audioTooLarge(bytes: fileSize, limit: OpenAITranscriber.maxUploadBytes)
        }
        var form = MultipartFormData()
        form.addField(name: "model", value: model)
        form.addField(name: "response_format", value: "diarized_json")
        form.addField(name: "chunking_strategy", value: "auto")
        form.addField(name: "language", value: request.language)
        if let temperature { form.addField(name: "temperature", value: String(temperature)) }
        for speaker in knownSpeakers {
            form.addField(name: "known_speaker_names[]", value: speaker.name)
            form.addField(name: "known_speaker_references[]", value: speaker.dataURL)
        }
        form.addFile(
            name: "file",
            filename: fileURL.lastPathComponent,
            contentType: MultipartFormData.mimeType(forExtension: fileURL.pathExtension),
            url: fileURL
        )

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        Log.network.info("OpenAI upload: \(fileSize, privacy: .public) bytes")
        let bodyURL = try form.writeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let (data, response) = try await session.upload(for: urlRequest, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse(provider: id, detail: "HTTP レスポンスではありません")
        }
        let requestID = http.value(forHTTPHeaderField: "x-request-id")
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.httpError(provider: id, status: http.statusCode, body: String(decoding: data, as: UTF8.self), requestID: requestID)
        }
        return (try OpenAITranscriber.parseResponse(data), requestID)
    }

    // MARK: - Response

    public struct DiarizedResponse: Decodable, Sendable {
        public struct Segment: Decodable, Sendable {
            public var id: String?
            public var type: String?
            public var start: Double
            public var end: Double
            public var text: String
            public var speaker: String?
        }

        public var task: String?
        public var duration: Double?
        public var text: String?
        public var segments: [Segment]
    }

    public static func parseResponse(_ data: Data) throws -> DiarizedResponse {
        do {
            return try JSONCoding.decoder().decode(DiarizedResponse.self, from: data)
        } catch {
            throw TranscriptionError.invalidResponse(provider: "openai", detail: "\(error)")
        }
    }

    /// diarized_json → TranscriptionResult（単一チャンク、オフセットなし）。golden テスト用。
    public static func makeResult(from response: DiarizedResponse, meta: [String: String] = [:]) -> TranscriptionResult {
        let segments = response.segments.map {
            TranscriptSegment(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), speakerLabel: $0.speaker)
        }.filter { !$0.text.isEmpty }
        return TranscriptionResult(segments: segments, providerMeta: meta)
    }

    // MARK: - Upload preparation

    public struct PreparedUpload: Sendable {
        public struct Chunk: Sendable {
            public var url: URL
            /// 元音声内での開始秒。
            public var offset: Double
        }
        public var chunks: [Chunk]
        public var transcoded: Bool
        public var temporaryDirectory: URL?

        public func cleanup() {
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }
    }

    /// 25 MB 以下ならそのまま、超えるなら AAC 32 kbps mono に再エンコード、それでも超えるなら無音位置で分割する。
    public static func prepareUpload(audioURL: URL, chunkTargetSeconds: Double) throws -> PreparedUpload {
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let acceptedExtensions: Set<String> = ["flac", "mp3", "mp4", "mpeg", "mpga", "m4a", "ogg", "wav", "webm"]
        if size <= maxUploadBytes, acceptedExtensions.contains(audioURL.pathExtension.lowercased()) {
            return PreparedUpload(chunks: [.init(url: audioURL, offset: 0)], transcoded: false, temporaryDirectory: nil)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-openai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let whole = tempDir.appendingPathComponent("upload.m4a")
        try AudioFileTools.transcodeToAAC(input: audioURL, output: whole, bitrate: uploadBitrate)
        let wholeSize = try AudioFileTools.fileSize(whole)
        if wholeSize <= maxUploadBytes {
            return PreparedUpload(chunks: [.init(url: whole, offset: 0)], transcoded: true, temporaryDirectory: tempDir)
        }

        // 分割: 無音位置を探して切る
        let samples = try AudioFileTools.loadMono16k(audioURL)
        let sampleRate = 16_000.0
        let duration = Double(samples.count) / sampleRate
        let ratio = Double(wholeSize) / Double(maxUploadBytes)
        let target = min(chunkTargetSeconds, duration / ceil(ratio) * 0.95)
        let splitPoints = AudioFileTools.quietSplitPoints(samples: samples, sampleRate: sampleRate, targetChunkSeconds: target)
        var chunks: [PreparedUpload.Chunk] = []
        var boundaries = [0.0] + splitPoints + [duration]
        boundaries = Array(Set(boundaries)).sorted()
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard end - start > 0.5 else { continue }
            let range = Int(start * sampleRate)..<min(samples.count, Int(end * sampleRate))
            let chunkURL = tempDir.appendingPathComponent(String(format: "chunk_%02d.m4a", index))
            try AudioFileTools.writeAAC(samples: Array(samples[range]), sampleRate: sampleRate, to: chunkURL, bitrate: uploadBitrate)
            chunks.append(.init(url: chunkURL, offset: start))
        }
        try? FileManager.default.removeItem(at: whole)
        return PreparedUpload(chunks: chunks, transcoded: true, temporaryDirectory: tempDir)
    }

    /// 参照音声を 16 kHz mono WAV（最大 10 秒）に変換して data URL にする。
    public static func referenceDataURL(for url: URL) throws -> String {
        var samples = try AudioFileTools.loadMono16k(url)
        let sampleRate = 16_000.0
        let duration = Double(samples.count) / sampleRate
        guard duration >= knownSpeakerMinSeconds else {
            throw TranscriptionError.unsupportedAudio("参照音声 \(url.lastPathComponent) が短すぎます（\(String(format: "%.1f", duration)) 秒 < \(knownSpeakerMinSeconds) 秒）")
        }
        if duration > knownSpeakerMaxSeconds {
            samples = Array(samples[0..<Int(knownSpeakerMaxSeconds * sampleRate)])
        }
        let wav = AudioFileTools.wavData(samples: samples, sampleRate: sampleRate)
        return "data:audio/wav;base64," + wav.base64EncodedString()
    }
}
