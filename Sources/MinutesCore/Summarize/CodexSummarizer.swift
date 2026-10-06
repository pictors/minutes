import Foundation
import Synchronization

/// Codex の既存ログインを使用する。Minutes は認証トークンを読み出し・保存しない。
public final class CodexSummarizer: Summarizing {
    private let client: CodexAppServerClient
    private let model: String?
    private let prompt: SummaryPrompt
    private let resolvedModel: Mutex<String>

    /// model: model/list の id。nil または空なら Codex の既定モデル（config.toml / Codex の既定）を使う。
    public convenience init(model: String? = nil, executablePath: String? = nil, timeoutSeconds: Double = 240, prompt: SummaryPrompt? = nil) throws {
        try self.init(client: CodexAppServerClient(executablePath: executablePath, timeoutSeconds: timeoutSeconds), model: model, prompt: prompt)
    }

    init(client: CodexAppServerClient, model: String? = nil, prompt: SummaryPrompt? = nil) throws {
        let requested = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.client = client
        self.model = requested.isEmpty ? nil : requested
        self.prompt = try prompt ?? SummaryPrompt.loadBundled()
        self.resolvedModel = Mutex(requested.isEmpty ? "default" : requested)
    }

    public var cacheIdentity: String { "codex/\(model ?? "default")/\(prompt.fingerprint)" }

    public var modelDescription: String {
        "codex/\(resolvedModel.withLock { $0 }) / prompt v\(prompt.version)"
    }

    /// ログインと選択できるモデルを確認する。会議データを送らず、推論も実行しない。
    public func checkConnection() async throws -> CodexConnection {
        try await client.checkConnection()
    }

    public func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
        try await StructuredSummary.summarize(input, prompt: prompt, generate: generate)
    }

    private func generate(_ user: String, validIds: Set<Int>) async throws -> MinutesSummary {
        let completion = try await client.complete(system: prompt.system, user: user, model: model)
        let summary: MinutesSummary
        do {
            summary = try JSONCoding.decoder().decode(MinutesSummary.self, from: Data(completion.text.utf8))
        } catch { throw CodexError.invalidResponse }
        try Self.validate(summary, validIds: validIds)
        resolvedModel.withLock { $0 = completion.model }
        return summary
    }

    static func validate(_ summary: MinutesSummary, validIds: Set<Int>) throws {
        guard StructuredSummary.isValid(summary, validIds: validIds) else { throw CodexError.invalidResponse }
    }
}

public enum SummaryProvider: String, Codable, Sendable, CaseIterable {
    case codex
    case claudeCode = "claude-code"
    case anthropic
    /// 要約しない（文字起こしまでの議事録を作る）。Codex にも Claude Code にもログインしておらず、キーもない人向け（2026-10-05 決定）
    case none
}

public enum SummaryProviders {
    /// 選ばれた要約の手段。「要約しない」なら nil。
    public static func make(settings: AppSettings) throws -> (any Summarizing)? {
        switch settings.resolvedSummaryProvider {
        case .codex:
            return try CodexSummarizer(model: settings.codexModel, executablePath: settings.codexExecutablePath)
        case .claudeCode:
            return try ClaudeCodeSummarizer(model: settings.claudeCodeModel, executablePath: settings.claudeCodeExecutablePath)
        case .anthropic:
            guard let key = APIKeys.resolve(APIKeys.anthropic) else { throw SummarizerError.missingAPIKey }
            return try ClaudeSummarizer(apiKey: key, model: settings.summaryModel)
        case .none:
            return nil
        }
    }
}
