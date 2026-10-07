import Foundation

/// Claude Messages API による構造化要約（SPEC §8.1）。URLSession で直接呼ぶ。
/// 仕様（2026-09-17、claude-api skill / docs.claude.com で確認）:
///   POST https://api.anthropic.com/v1/messages
///   ヘッダ: x-api-key, anthropic-version: 2023-06-01, content-type: application/json
///   body: model, max_tokens, system, messages[], tools[{name, description, input_schema, strict}], tool_choice{type:"tool", name}
///   レスポンス: content[] に {type:"tool_use", name, input}、stop_reason（tool_use / end_turn / max_tokens / refusal）
///   既定モデル claude-sonnet-5（SPEC）。ヘッダ request-id をログに残す。
public struct ClaudeSummarizer: Summarizing {
    public static let defaultModel = "claude-sonnet-5"
    public static let apiKeyEnvName = "ANTHROPIC_API_KEY"
    public static let toolName = "record_minutes"
    public static let promptResourceName = "summarize_ja"
    /// これを超える会議は分割して部分要約 → 統合の 2 段にする（SPEC §8.1: 90 分）。
    public static let splitThresholdSeconds: Double = 90 * 60
    public static let partDurationSeconds: Double = 45 * 60

    public var apiKey: String
    public var model: String
    public var baseURL: URL
    public var maxTokens: Int
    public var session: URLSession
    public let prompt: SummaryPrompt

    public init(apiKey: String, model: String = ClaudeSummarizer.defaultModel, baseURL: URL = URL(string: "https://api.anthropic.com")!, maxTokens: Int = 16_000, session: URLSession = .longUpload, prompt: SummaryPrompt? = nil) throws {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.session = session
        self.prompt = try prompt ?? SummaryPrompt.loadBundled()
    }

    public var cacheIdentity: String { "\(model)/\(baseURL)/\(maxTokens)/\(prompt.fingerprint)" }

    public var modelDescription: String { "\(model) / prompt v\(prompt.version)" }

    // MARK: - Summarize

    public func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
        if input.durationSeconds > ClaudeSummarizer.splitThresholdSeconds, input.segments.count > 1 {
            return try await summarizeInParts(input)
        }
        let user = prompt.userMessage(for: input, transcript: input.transcriptText(), partLabel: nil)
        return try await callTool(system: prompt.systemMessage(for: input), user: user)
    }

    /// 長い会議: 時間で分割して部分要約し、部分要約の JSON をまとめて統合する。
    func summarizeInParts(_ input: SummaryInput) async throws -> MinutesSummary {
        var parts: [[TranscriptDocument.Segment]] = []
        var current: [TranscriptDocument.Segment] = []
        var partStart = input.segments.first?.tStart ?? 0
        for segment in input.segments {
            if segment.tStart - partStart >= ClaudeSummarizer.partDurationSeconds, !current.isEmpty {
                parts.append(current)
                current = []
                partStart = segment.tStart
            }
            current.append(segment)
        }
        if !current.isEmpty { parts.append(current) }

        var partials: [MinutesSummary] = []
        for (index, part) in parts.enumerated() {
            var partInput = input
            partInput.segments = part
            let label = "パート \(index + 1)/\(parts.count)（\(TimeFormatting.hms(part.first?.tStart ?? 0))〜\(TimeFormatting.hms(part.last?.tEnd ?? 0))）"
            let user = prompt.userMessage(for: partInput, transcript: partInput.transcriptText(), partLabel: label)
            partials.append(try await callTool(system: prompt.systemMessage(for: input), user: user))
        }
        let encoder = JSONCoding.encoder()
        let partialJSON = try partials.enumerated().map { index, partial -> String in
            "### パート \(index + 1)\n" + String(decoding: try encoder.encode(partial), as: UTF8.self)
        }.joined(separator: "\n\n")
        let mergeUser = prompt.mergeMessage(for: input, partialSummaries: partialJSON)
        return try await callTool(system: prompt.systemMessage(for: input), user: mergeUser)
    }

    // MARK: - API

    func callTool(system: String, user: String) async throws -> MinutesSummary {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "tools": [ClaudeSummarizer.recordMinutesTool],
            "tool_choice": ["type": "tool", "name": ClaudeSummarizer.toolName],
            "messages": [["role": "user", "content": user]],
        ]
        do {
            return try await send(body)
        } catch let SummarizerError.httpError(status, responseBody, _) where status == 400 && responseBody.contains("tool_choice") {
            // forced tool use を受け付けないモデルでは auto + 指示で代替する
            body["tool_choice"] = ["type": "auto"]
            body["messages"] = [["role": "user", "content": user + "\n\n必ず \(ClaudeSummarizer.toolName) ツールを 1 回だけ呼び出して結果を返してください。"]]
            return try await send(body)
        }
    }

    func send(_ body: [String: Any]) async throws -> MinutesSummary {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SummarizerError.invalidResponse("HTTP レスポンスではありません") }
        let requestID = http.value(forHTTPHeaderField: "request-id")
        guard (200..<300).contains(http.statusCode) else {
            throw SummarizerError.httpError(status: http.statusCode, body: String(decoding: data, as: UTF8.self), requestID: requestID)
        }
        Log.network.info("Claude summarize ok request-id=\(requestID ?? "-", privacy: .public)")
        return try ClaudeSummarizer.parseResponse(data)
    }

    /// Messages API のレスポンスから record_minutes の入力を取り出す。golden テスト用に public。
    public static func parseResponse(_ data: Data) throws -> MinutesSummary {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummarizerError.invalidResponse("JSON オブジェクトではありません")
        }
        let stopReason = object["stop_reason"] as? String
        if stopReason == "refusal" {
            let detail = (object["stop_details"] as? [String: Any])?["explanation"] as? String ?? "refusal"
            throw SummarizerError.refused(detail)
        }
        if stopReason == "max_tokens" { throw SummarizerError.truncated }
        guard let content = object["content"] as? [[String: Any]] else {
            throw SummarizerError.invalidResponse("content がありません")
        }
        guard let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == toolName }),
              let input = toolUse["input"] else {
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            throw SummarizerError.invalidResponse("tool_use がありません: \(Log.preview(text, limit: 200))")
        }
        let inputData = try JSONSerialization.data(withJSONObject: input)
        do {
            return try JSONCoding.decoder().decode(MinutesSummary.self, from: inputData)
        } catch {
            throw SummarizerError.invalidResponse("record_minutes の入力を decode できません: \(error)")
        }
    }

    /// record_minutes ツール定義（strict: 全オブジェクトに additionalProperties: false と required）。
    public static var recordMinutesTool: [String: Any] {
        [
            "name": toolName,
            "description": "会議の要約・決定事項・アクション・未決事項を構造化して記録する。",
            "strict": true,
            "input_schema": SummarySchema.json,
        ]
    }
}
