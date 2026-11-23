import CryptoKit
import Foundation

/// Minutes（キーなし）: Pictors のサーバーで文字起こしする（製品版の有料の手段、SPEC §5.6）。
/// トラックの音声を AAC にして送り、文字起こしだけ（要約しない）を頼む。結果は ElevenLabs の応答の形で受け、
/// 直接 ElevenLabs に送ったときと同じ読み方（ElevenLabsScribe）で読む。
/// - 同じトラックは同じ client_id で送る（後処理のやり直し・スリープのあとに、上げ直したり二重に数えたりしない）。前の失敗は消して作り直す。
/// - 同じ会議の 2 本は組（TranscriptionRequest.groupKey）にする（サーバーは組の長いほうだけを使える量に数える）。組は結果の providerMeta に残し、要約が使う。
/// - サーバーの誤りは TranscriptionError.httpError にする（408・429・5xx は待ってやり直し、ほかはこの Mac の中の文字起こしに切り替える。SPEC §8.2）。
public struct MinutesCloudTranscriber: BatchTranscriber {
    public static let providerID = "minutes.cloud"
    /// providerMeta に残す組の名前の鍵
    public static let groupMetaKey = "minutes_cloud_group"
    /// サーバーの keyterms は 1 語 50 文字まで・1000 語まで
    static let maxKeyterms = 1000
    static let maxKeytermLength = 50

    public let id = MinutesCloudTranscriber.providerID
    public let runsLocally = false
    public var client: MinutesCloudClient
    public var foldingOptions: SegmentFoldingOptions
    /// 状態を見に行く間隔
    public var pollInterval: Duration
    /// 待つ上限（60 分の会議でも数分で終わる）
    public var timeout: Duration
    /// "mac" | "import"
    public var source: String

    public init(client: MinutesCloudClient, foldingOptions: SegmentFoldingOptions = SegmentFoldingOptions(), pollInterval: Duration = .seconds(3),
                timeout: Duration = .seconds(3600), source: String = "mac") {
        self.client = client
        self.foldingOptions = foldingOptions
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.source = source
    }

    public var cacheIdentity: String {
        "\(id)/\(client.baseURL)/\(foldingOptions.maxPause)/\(foldingOptions.maxDuration)/\(foldingOptions.sentenceSplitMinDuration)/\(foldingOptions.sentenceEnders.sorted().map(String.init).joined())"
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        do {
            return try await run(request)
        } catch let error as MinutesCloudError {
            throw Self.transcriptionError(error, provider: id)
        }
    }

    static func transcriptionError(_ error: MinutesCloudError, provider: String) -> TranscriptionError {
        switch error {
        case let .http(status, _, requestID):
            return .httpError(provider: provider, status: status, body: error.localizedDescription, requestID: requestID)
        case .notSignedIn:
            return .httpError(provider: provider, status: 401, body: error.localizedDescription, requestID: nil)
        case .invalidResponse, .timedOut, .failed:
            return .invalidResponse(provider: provider, detail: error.localizedDescription)
        }
    }

    /// 同じトラック（組・音声・話者を分けるか・言語）なら同じ ID。
    static func clientID(for request: TranscriptionRequest) throws -> String {
        let parts = [
            "minutes-cloud-track/v1",
            request.groupKey ?? "",
            request.diarize ? "diarize" : "single",
            request.language,
            try PipelineFingerprint.file(request.audioURL),
        ]
        return "mac-" + SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    static func keyterms(_ terms: [String]) -> [String]? {
        let kept = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.unicodeScalars.count <= maxKeytermLength }
        return kept.isEmpty ? nil : Array(kept.prefix(maxKeyterms))
    }

    private func run(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard client.token() != nil else { throw MinutesCloudError.notSignedIn }
        let started = Date()
        let options = MinutesCloudRecordingRequest(
            clientId: try Self.clientID(for: request),
            source: source,
            language: ["ja", "en"].contains(request.language) ? request.language : nil,
            contentType: "audio/mp4",
            summarize: false,
            diarize: request.diarize,
            keyterms: Self.keyterms(request.keyterms),
            group: request.groupKey
        )
        // 文字起こしそのものが消えていたら（30 日を過ぎた）、1 回だけ作り直す
        for attempt in 0..<2 {
            var recording = try await client.createRecording(options)
            if recording.status == "failed" {
                // 前の失敗は消して作り直す（同じ client_id で作れるように。組の 2 本にも数えない）
                try await client.deleteRecording(id: recording.id)
                recording = try await client.createRecording(options)
            }
            do {
                return try await finish(recording, request: request, started: started)
            } catch let error as MinutesCloudError where error.status == 404 && attempt == 0 && recording.status == "done" {
                try await client.deleteRecording(id: recording.id)
            }
        }
        throw MinutesCloudError.failed("文字起こしを読めない")
    }

    private func finish(_ created: MinutesCloudRecording, request: TranscriptionRequest, started: Date) async throws -> TranscriptionResult {
        var recording = created
        var meta: [String: String] = ["provider": id, "server_recording_id": recording.id]
        if let group = request.groupKey { meta[Self.groupMetaKey] = group }
        if recording.status == "uploading" {
            let aac = try AudioFileTools.aacCopy(of: request.audioURL)
            defer { try? FileManager.default.removeItem(at: aac.deletingLastPathComponent()) }
            let bytes = try AudioFileTools.fileSize(aac)
            let duration = try? AudioFileTools.duration(of: request.audioURL)
            let uploadStarted = Date()
            try Task.checkCancellation()
            try await client.uploadAudio(recordingID: recording.id, fileURL: aac, contentType: "audio/mp4")
            meta["upload_seconds"] = String(format: "%.1f", Date().timeIntervalSince(uploadStarted))
            meta["upload_bytes"] = String(bytes)
            meta["upload_format"] = "m4a"
            recording = try await client.complete(recordingID: recording.id, durationSeconds: duration)
        }
        let serverStarted = Date()
        let deadline = ContinuousClock.now + timeout
        while !recording.isFinished {
            guard ContinuousClock.now < deadline else { throw MinutesCloudError.timedOut("文字起こし（\(recording.status)）") }
            try await Task.sleep(for: pollInterval)
            recording = try await client.recording(id: recording.id)
        }
        if recording.status == "failed" { throw MinutesCloudError.failed(recording.error ?? "理由は分からない") }
        meta["server_seconds"] = String(format: "%.1f", Date().timeIntervalSince(serverStarted))
        let response = try ElevenLabsScribe.parseResponse(try await client.transcription(recordingID: recording.id))
        meta["elapsed_seconds"] = String(format: "%.1f", Date().timeIntervalSince(started))
        meta["language_code"] = response.languageCode ?? ""
        if let probability = response.languageProbability { meta["language_probability"] = String(format: "%.3f", probability) }
        if let transcriptionID = response.transcriptionId { meta["transcription_id"] = transcriptionID }
        if let duration = response.audioDurationSecs { meta["audio_duration_secs"] = String(format: "%.1f", duration) }
        return ElevenLabsScribe.makeResult(from: response, foldingOptions: foldingOptions, meta: meta)
    }
}
