import Darwin
import Foundation
import Testing
@testable import MinutesCore

/// 実際の `claude` の代わりに、決まった出力を返すシェルスクリプト。受け取った引数・stdin・PID をファイルに残す。
/// モデル一覧の読み取り（--input-format stream-json）は別のファイル（*.models）に残し、models を指定すればその出力を返す。
private struct FakeClaude {
    let directory: URL
    var path: String { directory.appendingPathComponent("claude").path }

    /// hangModels: モデル一覧の読み取りだけを止める（ログインの確認は答える）。
    init(stdout: String, stderr: String = "", status: Int32 = 0, models: String? = nil, hang: Bool = false, hangModels: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-fake-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try stdout.write(to: directory.appendingPathComponent("stdout"), atomically: true, encoding: .utf8)
        try stderr.write(to: directory.appendingPathComponent("stderr"), atomically: true, encoding: .utf8)
        try models?.write(to: directory.appendingPathComponent("stdout.models"), atomically: true, encoding: .utf8)
        let dir = directory.path
        let script = """
        #!/bin/sh
        suffix=''
        for a in "$@"; do [ "$a" = '--input-format' ] && suffix='.models'; done
        echo $$ > '\(dir)/pid'"$suffix"
        for a in "$@"; do printf '%s\\0' "$a"; done > '\(dir)/args'"$suffix"
        cat > '\(dir)/stdin'"$suffix"
        [ -f '\(dir)/hang' ] && exec sleep 30
        [ -n "$suffix" ] && [ -f '\(dir)/hang.models' ] && exec sleep 30
        if [ -f '\(dir)/stdout'"$suffix" ]; then cat '\(dir)/stdout'"$suffix"; else cat '\(dir)/stdout'; fi
        cat '\(dir)/stderr' >&2
        exit \(status)
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        if hang || hangModels {
            // 新しい実行ファイルの初回起動はシステムの検査で遅れる（並列のテストでは数秒）。タイムアウトを測る前に一度起動しておく。
            let warmup = Process()
            warmup.executableURL = URL(fileURLWithPath: path)
            warmup.standardInput = FileHandle.nullDevice
            warmup.standardOutput = FileHandle.nullDevice
            try warmup.run()
            warmup.waitUntilExit()
            try FileManager.default.removeItem(at: directory.appendingPathComponent("pid"))
            FileManager.default.createFile(atPath: directory.appendingPathComponent(hang ? "hang" : "hang.models").path, contents: nil)
        }
    }

    var arguments: [String] {
        get throws { try arguments(in: "args") }
    }

    /// モデル一覧の読み取りで受け取った引数。
    var modelArguments: [String] {
        get throws { try arguments(in: "args.models") }
    }

    var stdin: String {
        get throws { try String(contentsOf: directory.appendingPathComponent("stdin"), encoding: .utf8) }
    }

    var modelStdin: String {
        get throws { try String(contentsOf: directory.appendingPathComponent("stdin.models"), encoding: .utf8) }
    }

    /// モデル一覧を読みに起動したか。
    var listedModels: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("args.models").path) }

    private func arguments(in file: String) throws -> [String] {
        let data = try Data(contentsOf: directory.appendingPathComponent(file))
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    /// スクリプトが起動していれば、その PID（file: "pid.models" ならモデル一覧の読み取り）。
    func pid(_ file: String = "pid", waitingUpTo seconds: Double = 3) async throws -> pid_t? {
        let url = directory.appendingPathComponent(file)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    static func result(_ fields: [String: Any]) throws -> String {
        var object: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "result": "", "session_id": "test"]
        object.merge(fields) { $1 }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func summary(evidence: [Int] = [17]) -> [String: Any] {
        ["summary_md": "発売を決めた。", "decisions": [["text": "発売を決定", "evidence": evidence]], "action_items": [], "open_questions": [], "keyterms_learned": []]
    }

    static let loggedIn = #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "someone@example.com", "subscriptionType": "max"}"#

    /// claude 2.1.272 の initialize が返した models と同じ形。
    static var modelList: [[String: Any]] {
        [
            ["value": "default", "resolvedModel": "claude-opus-5[1m]", "displayName": "Default (recommended)", "description": "Opus 5 with 1M context · Best for everyday, complex tasks", "supportsEffort": true],
            ["value": "opus[1m]", "resolvedModel": "claude-opus-5[1m]", "displayName": "Opus (1M context)", "description": "Opus 5 with 1M context · Best for everyday, complex tasks", "supportsEffort": true],
            ["value": "claude-fable-5-1[1m]", "resolvedModel": "claude-fable-5-1", "displayName": "Fable", "description": "Fable 5.1 · Most capable for your hardest and longest-running tasks"],
            ["value": "sonnet", "resolvedModel": "claude-sonnet-5", "displayName": "Sonnet", "description": "Sonnet 5 · Efficient for routine tasks"],
            ["value": "haiku", "resolvedModel": "claude-haiku-4-5-20251001", "displayName": "Haiku", "description": "Haiku 4.5 · Fastest for quick answers"],
        ]
    }

    /// initialize と get_context_usage の制御応答（1 行 1 件）。
    static func controlResponses(models: [[String: Any]] = modelList, current: String?) throws -> String {
        var lines: [[String: Any]] = [
            ["type": "control_response", "response": ["subtype": "success", "request_id": "models",
                                                        "response": ["models": models, "account": ["email": "someone@example.com"]]]],
        ]
        if let current {
            lines.append(["type": "control_response", "response": ["subtype": "success", "request_id": "current-model",
                                                                     "response": ["model": current, "totalTokens": 0]]])
        }
        return try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }
}

/// プロセスが終了するまで待つ（SIGTERM を無視されても 2 秒後に SIGKILL される）。
private func exited(_ pid: pid_t, within seconds: Double = 4) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if kill(pid, 0) != 0 { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return false
}

@Suite("Claude Code headless")
struct ClaudeCodeSummarizerTests {
    func input() -> SummaryInput {
        SummaryInput(meetingTitle: "テスト会議", startedAt: nil, attendees: [], segments: [
            .init(id: 17, track: "mic", tStart: 0, tEnd: 2, speaker: "me", text: "発売を決定します。"),
        ])
    }

    @Test("ツール・個人設定・セッション保存なしで起動し、stdin の本文から構造化要約と実モデルを得る")
    func protocolFlow() async throws {
        let fake = try FakeClaude(stdout: FakeClaude.result([
            "structured_output": FakeClaude.summary(),
            "modelUsage": ["claude-haiku-4-5": ["outputTokens": 3], "claude-sonnet-5": ["outputTokens": 180]],
        ]))
        defer { fake.remove() }
        let summarizer = try ClaudeCodeSummarizer(executablePath: fake.path)
        #expect(summarizer.cacheIdentity.hasPrefix("claude-code/default/"))
        let summary = try await summarizer.summarize(input())
        #expect(summary.decisions.first?.evidence == [17])
        #expect(summarizer.modelDescription.hasPrefix("claude-code/claude-sonnet-5 / prompt v"))

        let args = try fake.arguments
        #expect(args.first == "-p")
        #expect(args.contains("--safe-mode"))
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--no-session-persistence"))
        #expect(!args.contains("--bare"))
        #expect(!args.contains("--model"))
        func value(after flag: String) throws -> String {
            let index = try #require(args.firstIndex(of: flag))
            return args[index + 1]
        }
        #expect(try value(after: "--tools") == "")
        #expect(try value(after: "--output-format") == "json")
        let schema = try JSONSerialization.jsonObject(with: Data(try value(after: "--json-schema").utf8)) as? [String: Any]
        #expect(schema?["additionalProperties"] as? Bool == false)
        #expect(try value(after: "--system-prompt").hasSuffix(ClaudeCodeClient.instructions))
        // 本文は引数ではなく stdin で渡す
        #expect(try fake.stdin.contains("[seg 17]"))
        #expect(!args.contains { $0.contains("[seg 17]") })
    }

    @Test("選んだモデルを --model とキャッシュの同一性に使い、空欄は Claude Code の既定にする")
    func modelSelection() async throws {
        let output = try FakeClaude.result(["structured_output": FakeClaude.summary()])
        let selected = try FakeClaude(stdout: output)
        defer { selected.remove() }
        let summarizer = try ClaudeCodeSummarizer(model: " opus ", executablePath: selected.path)
        _ = try await summarizer.summarize(input())
        let args = try selected.arguments
        #expect(args.firstIndex(of: "--model").map { args[$0 + 1] } == "opus")
        #expect(summarizer.cacheIdentity.hasPrefix("claude-code/opus/"))
        // modelUsage がなければ指定したモデル名のまま記録する
        #expect(summarizer.modelDescription.hasPrefix("claude-code/opus / prompt v"))

        let automatic = try FakeClaude(stdout: output)
        defer { automatic.remove() }
        let fallback = try ClaudeCodeSummarizer(model: "  ", executablePath: automatic.path)
        _ = try await fallback.summarize(input())
        #expect(try !automatic.arguments.contains("--model"))
        #expect(fallback.cacheIdentity.hasPrefix("claude-code/default/"))
    }

    @Test("pipe の容量を超える本文も欠けずに渡す")
    func largeInput() async throws {
        let fake = try FakeClaude(stdout: FakeClaude.result(["structured_output": FakeClaude.summary()]))
        defer { fake.remove() }
        var value = input()
        let long = String(repeating: "あ", count: 40_000)
        value.segments[0].text = long
        _ = try await ClaudeCodeSummarizer(executablePath: fake.path).summarize(value)
        #expect(try fake.stdin.contains(long))
    }

    @Test("未ログイン・再試行切れ・API エラー・出力なし・無効な根拠・壊れた出力・異常終了・古い CLI を成功扱いにしない",
          arguments: ["loggedOut", "retries", "apiError", "missingOutput", "badEvidence", "malformed", "crash", "oldCLI"])
    func failures(mode: String) async throws {
        let expected: ClaudeCodeError
        let fake: FakeClaude
        switch mode {
        case "loggedOut":
            fake = try FakeClaude(stdout: FakeClaude.result(["is_error": true, "result": "Not logged in · Please run /login"]), status: 1)
            expected = .loginRequired
        case "retries":
            fake = try FakeClaude(stdout: FakeClaude.result(["subtype": "error_max_structured_output_retries", "is_error": true]), status: 1)
            expected = .invalidResponse
        case "apiError":
            fake = try FakeClaude(stdout: FakeClaude.result(["is_error": true, "result": "API Error: 529 overloaded"]), status: 1)
            expected = .failed("API Error: 529 overloaded")
        case "missingOutput":
            fake = try FakeClaude(stdout: FakeClaude.result(["result": "要約です"]))
            expected = .invalidResponse
        case "badEvidence":
            fake = try FakeClaude(stdout: FakeClaude.result(["structured_output": FakeClaude.summary(evidence: [99])]))
            expected = .invalidResponse
        case "malformed":
            fake = try FakeClaude(stdout: "not json")
            expected = .invalidResponse
        case "crash":
            fake = try FakeClaude(stdout: "", status: 2)
            expected = .processFailed(2)
        default:
            fake = try FakeClaude(stdout: "", stderr: "error: unknown option '--safe-mode'", status: 1)
            expected = .upgradeRequired
        }
        defer { fake.remove() }
        let summarizer = try ClaudeCodeSummarizer(executablePath: fake.path)
        await #expect(throws: expected) { _ = try await summarizer.summarize(input()) }
    }

    @Test("実行ファイルが見つからない・相対パスは起動しない")
    func executableNotFound() async throws {
        for path in ["/nonexistent/claude", "claude"] {
            let summarizer = try ClaudeCodeSummarizer(executablePath: path)
            await #expect(throws: ClaudeCodeError.executableNotFound) { _ = try await summarizer.summarize(input()) }
        }
    }

    @Test("タイムアウトとキャンセルは子プロセスを終了させる")
    func timeoutAndCancellation() async throws {
        let hung = try FakeClaude(stdout: "", hang: true)
        defer { hung.remove() }
        let summarizer = try ClaudeCodeSummarizer(executablePath: hung.path, timeoutSeconds: 1)
        await #expect(throws: ClaudeCodeError.timeout) { _ = try await summarizer.summarize(input()) }
        let pid = try #require(try await hung.pid())
        #expect(try await exited(pid))

        let cancelled = try FakeClaude(stdout: "", hang: true)
        defer { cancelled.remove() }
        let second = try ClaudeCodeSummarizer(executablePath: cancelled.path)
        let task = Task { try await second.summarize(input()) }
        let running = try #require(try await cancelled.pid())
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(try await exited(running))
    }

    @Test("接続確認は auth status とモデル一覧だけを読み、推論を始めない")
    func connection() async throws {
        let fake = try FakeClaude(stdout: FakeClaude.loggedIn, models: try FakeClaude.controlResponses(current: "claude-opus-5[1m]"))
        defer { fake.remove() }
        let connection = try await ClaudeCodeSummarizer(executablePath: fake.path).checkConnection()
        #expect(connection.authMethod == "claude.ai")
        #expect(connection.label == "claude.ai / max")
        #expect(try fake.arguments == ["auth", "status", "--json"])
        // "default" の行は「Claude Code の既定」（--model なし）と同じなので選択肢に入れない
        #expect(connection.models.map(\.id) == ["opus[1m]", "claude-fable-5-1[1m]", "sonnet", "haiku"])
        #expect(connection.models.first?.description == "Opus 5 with 1M context · Best for everyday, complex tasks")
        #expect(connection.currentModel == "claude-opus-5[1m]")
        // 既定のモデルは、そのモデルを指す一覧の行の名前で示す
        #expect(connection.defaultModel?.id == "opus[1m]")
        #expect(connection.defaultModel?.displayName == "Opus (1M context)")

        // 要約と同じ条件で起動し、制御要求だけを書いて閉じる（利用者のメッセージを送らないので推論しない）
        let args = try fake.modelArguments
        #expect(args.first == "-p")
        func value(after flag: String) throws -> String {
            let index = try #require(args.firstIndex(of: flag))
            return args[index + 1]
        }
        #expect(try value(after: "--input-format") == "stream-json")
        #expect(try value(after: "--output-format") == "stream-json")
        #expect(try value(after: "--tools") == "")
        for flag in ["--verbose", "--safe-mode", "--strict-mcp-config", "--no-session-persistence"] {
            #expect(args.contains(flag))
        }
        for flag in ["--model", "--system-prompt", "--json-schema", "--bare"] {
            #expect(!args.contains(flag))
        }
        let requests = try fake.modelStdin.split(separator: "\n").map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(requests.map { $0["type"] as? String } == ["control_request", "control_request"])
        #expect(requests.map { ($0["request"] as? [String: Any])?["subtype"] as? String } == ["initialize", "get_context_usage"])

        // 一覧にないモデル（settings.json のモデル名など）が既定なら、その名前で示す
        let custom = ClaudeCodeConnection(authMethod: "claude.ai", currentModel: "claude-opus-4-1", models: connection.models)
        #expect(custom.defaultModel == ClaudeCodeModel(id: "claude-opus-4-1", displayName: "claude-opus-4-1"))

        let loggedOut = try FakeClaude(stdout: #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#, status: 1)
        defer { loggedOut.remove() }
        await #expect(throws: ClaudeCodeError.loginRequired) { _ = try await ClaudeCodeSummarizer(executablePath: loggedOut.path).checkConnection() }
        #expect(!loggedOut.listedModels)
    }

    @Test("モデル一覧を読めなくても接続確認は成功する", arguments: ["error", "malformed", "missing"])
    func connectionWithoutModels(mode: String) async throws {
        let models: String? = switch mode {
        case "error": #"{"type":"control_response","response":{"subtype":"error","request_id":"models","error":"unsupported"}}"#
        case "malformed": "not json"
        default: nil
        }
        // missing: ログインの確認と同じ出力（制御応答なし）を返す
        let fake = try FakeClaude(stdout: FakeClaude.loggedIn, models: models)
        defer { fake.remove() }
        let connection = try await ClaudeCodeSummarizer(executablePath: fake.path).checkConnection()
        #expect(connection == ClaudeCodeConnection(authMethod: "claude.ai", subscription: "max"))
        #expect(connection.defaultModel == nil)
        #expect(fake.listedModels)
    }

    @Test("制御応答の失敗・壊れた行・重複・value のない行を選択肢にしない")
    func modelParsing() {
        let lines = [
            "not json",
            #"{"type":"control_response","response":{"subtype":"error","request_id":"current-model","error":"unsupported"}}"#,
            #"{"type":"control_response","response":{"subtype":"success","request_id":"models","response":{"models":[{"value":"sonnet","displayName":"Sonnet","description":"d"},{"value":"sonnet","displayName":"Sonnet (dup)"},{"displayName":"no value"},{"value":"","displayName":"empty"},{"value":"claude-x","displayName":""}]}}}"#,
        ]
        let parsed = ClaudeCodeClient.parseModels(ClaudeCodeProcess.Output(status: 0, stdout: Data(lines.joined(separator: "\n").utf8), stderr: Data()))
        #expect(parsed.models == [ClaudeCodeModel(id: "sonnet", displayName: "Sonnet", description: "d"), ClaudeCodeModel(id: "claude-x", displayName: "claude-x")])
        #expect(parsed.current == nil)
    }

    @Test("モデル一覧の読み取りがタイムアウトしても接続確認は成功し、キャンセルは伝える")
    func connectionModelsTimeout() async throws {
        let slow = try FakeClaude(stdout: FakeClaude.loggedIn, hangModels: true)
        defer { slow.remove() }
        let connection = try await ClaudeCodeSummarizer(executablePath: slow.path, timeoutSeconds: 1).checkConnection()
        #expect(connection.models.isEmpty)
        #expect(connection.currentModel == nil)
        let pid = try #require(try await slow.pid("pid.models"))
        #expect(try await exited(pid))

        let cancelled = try FakeClaude(stdout: FakeClaude.loggedIn, hangModels: true)
        defer { cancelled.remove() }
        let summarizer = try ClaudeCodeSummarizer(executablePath: cancelled.path)
        let task = Task { try await summarizer.checkConnection() }
        let running = try #require(try await cancelled.pid("pid.models"))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(try await exited(running))
    }

    @Test("起動環境の ANTHROPIC_API_KEY を渡さず、ログインを使わせる")
    func environment() {
        let environment = ClaudeCodeClient.environment(["ANTHROPIC_API_KEY": "sk-test", "HOME": "/Users/test", "CLAUDE_CODE_USE_BEDROCK": "1"])
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["CLAUDE_CODE_USE_BEDROCK"] == "1")
    }

    @Test("Claude Code の設定を保存し、未知のプロバイダでもほかの設定を失わない")
    func settings() throws {
        var settings = AppSettings()
        settings.summaryProvider = .claudeCode
        settings.claudeCodeModel = "opus"
        settings.claudeCodeExecutablePath = "~/.local/bin/claude"
        let decoded = try JSONCoding.decoder().decode(AppSettings.self, from: JSONCoding.encoder().encode(settings))
        #expect(decoded.resolvedSummaryProvider == .claudeCode)
        #expect(decoded.claudeCodeModel == "opus")
        #expect(decoded.claudeCodeExecutablePath == "~/.local/bin/claude")
        #expect(try SummaryProviders.make(settings: decoded) is ClaudeCodeSummarizer)

        let future = Data(#"{"summary_provider": "future-provider", "default_privacy_mode": "local_only", "codex_model": "fast-model"}"#.utf8)
        let tolerant = try JSONCoding.decoder().decode(AppSettings.self, from: future)
        #expect(tolerant.resolvedSummaryProvider == .codex)
        #expect(tolerant.defaultPrivacyMode == .localOnly)
        #expect(tolerant.codexModel == "fast-model")
    }

    @Test("Claude Code 実接続でモデル一覧と既定のモデルを読む（推論・送信なし）", .enabled(if: ProcessInfo.processInfo.environment["MINUTES_CLAUDE_CODE_LIVE"] == "1"))
    func liveModels() async throws {
        let connection = try await ClaudeCodeSummarizer(timeoutSeconds: 60).checkConnection()
        #expect(!connection.models.isEmpty)
        #expect(!connection.models.contains { $0.id == "default" })
        #expect(connection.currentModel != nil)
        #expect(connection.defaultModel != nil)
    }

    @Test("Claude Code 実接続で架空の会議を要約", .enabled(if: ProcessInfo.processInfo.environment["MINUTES_CLAUDE_CODE_LIVE"] == "1"))
    func liveSmoke() async throws {
        // MINUTES_CLAUDE_CODE_MODEL にエイリアスかモデル名を指定すると、そのモデルで要約する（未指定は Claude Code の既定）。
        let model = ProcessInfo.processInfo.environment["MINUTES_CLAUDE_CODE_MODEL"]
        let summarizer = try ClaudeCodeSummarizer(model: model, timeoutSeconds: 120)
        _ = try await summarizer.checkConnection()
        let summary = try await summarizer.summarize(input())
        #expect(!summary.summaryMd.isEmpty)
        #expect(summary.decisions.contains { $0.evidence.contains(17) })
        #expect(!summarizer.modelDescription.contains("/default"))
    }
}
