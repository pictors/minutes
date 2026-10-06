import Foundation
import Synchronization
import Testing
@testable import MinutesCore

private final class MockCodexTransport: CodexTransport, @unchecked Sendable {
    let messages: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    let mode: String
    let calls = Mutex<[Data]>([])
    let isClosed = Mutex(false)

    var failure: [String: Any]? {
        let detail = "secret transcript / Bearer secret-token"
        switch mode {
        case "modelUnavailable", "rpcModelUnavailable":
            return ["message": "The 'gpt-6-sol' model is not supported when using Codex with a ChatGPT account.", "codexErrorInfo": "badRequest", "additionalDetails": detail]
        case "upgradeRequired": return ["message": "This model requires a newer version of Codex", "additionalDetails": detail]
        case "usageLimit", "notificationOnly", "notificationAfterAck", "retryThenFailed":
            return ["message": detail, "codexErrorInfo": "usageLimitExceeded"]
        case "rateLimit": return ["message": detail, "codexErrorInfo": "rateLimitExceeded"]
        case "contextLimit": return ["message": detail, "codexErrorInfo": "contextWindowExceeded"]
        case "unauthorized": return ["message": detail, "codexErrorInfo": "unauthorized"]
        case "httpUnauthorized": return ["message": detail, "codexErrorInfo": ["httpConnectionFailed": ["httpStatusCode": 401]]]
        case "connectionFailed", "retryThenSuccess":
            return ["message": detail, "codexErrorInfo": ["responseStreamDisconnected": ["httpStatusCode": NSNull()]]]
        case "serviceUnavailable": return ["message": detail, "codexErrorInfo": "serverOverloaded"]
        case "unknownFailure": return ["message": detail, "codexErrorInfo": "other", "additionalDetails": detail]
        default: return nil
        }
    }

    init(mode: String = "ok") {
        self.mode = mode
        (messages, continuation) = AsyncThrowingStream.makeStream()
    }

    func emit(_ object: [String: Any]) throws {
        continuation.yield(try JSONSerialization.data(withJSONObject: object))
    }

    func send(_ data: Data) throws {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        calls.withLock { $0.append(data) }
        guard let method = object["method"] as? String, let id = object["id"] as? Int else { return }
        if mode == "hang" { return }
        if mode == "disconnect" { continuation.finish(); return }
        if mode == "malformed" { continuation.yield(Data("not json".utf8)); return }
        func respond(_ result: [String: Any]) throws { try emit(["id": id, "result": result]) }
        switch method {
        case "initialize": try respond(["userAgent": "fake"])
        case "account/read":
            try respond(["requiresOpenaiAuth": true, "account": mode == "loggedOut" ? NSNull() : ["type": "chatgpt"]])
        case "model/list":
            if mode == "noModelList" {
                try emit(["id": id, "error": ["code": -32601, "message": "Method not found"]])
                return
            }
            // 2 ページに分け、非表示モデルを混ぜる。
            if (object["params"] as? [String: Any])?["cursor"] as? String == "page2" {
                try respond(["data": [["id": "fast-model", "model": "fast-model", "displayName": "Fast", "description": "Quick", "hidden": false, "isDefault": false]], "nextCursor": NSNull()])
            } else {
                try respond(["data": [
                    ["id": "test-model", "model": "test-model", "displayName": "Test Model", "description": "Capable", "hidden": false, "isDefault": true],
                    ["id": "internal-model", "model": "internal-model", "displayName": "Internal", "description": "", "hidden": true, "isDefault": false],
                ], "nextCursor": "page2"])
            }
        case "config/read":
            var config: [String: Any] = ["mcp_servers": ["private-server": ["enabled": true]]]
            if mode != "unconfiguredModel" { config["model"] = "fast-model" }
            try respond(["config": config])
        case "thread/start": try respond(["thread": ["id": "thread"], "model": "test-model"])
        case "turn/start":
            if mode == "rpcModelUnavailable" {
                var error = failure!
                error["code"] = -32000
                try emit(["id": id, "error": error])
                return
            }
            if mode == "rpcError" {
                try emit(["id": id, "error": ["code": -32000, "message": "secret transcript"]])
                return
            }
            if mode == "serverRequest" {
                try emit(["id": 99, "method": "item/commandExecution/requestApproval", "params": [:]])
                return
            }
            // 通知は request の応答前に届くこともある。無関係な thread は無視する。
            try emit(["method": "turn/completed", "params": ["threadId": "other", "turn": ["id": "other", "status": "failed"]]])
            if mode == "notificationAfterAck" {
                try respond(["turn": ["id": "turn", "status": "inProgress", "items": []]])
            }
            if ["notificationOnly", "notificationAfterAck", "retryThenSuccess", "retryThenFailed"].contains(mode), let failure {
                try emit(["method": "error", "params": ["threadId": "thread", "turnId": "turn", "willRetry": mode.hasPrefix("retry"), "error": failure]])
            }
            if mode == "wrongTurnError" {
                let error: [String: Any] = ["message": "secret transcript", "codexErrorInfo": "usageLimitExceeded"]
                try emit(["method": "error", "params": ["threadId": "other", "turnId": "turn", "willRetry": false, "error": error]])
                try emit(["method": "error", "params": ["threadId": "thread", "turnId": "other", "willRetry": false, "error": error]])
            }
            try emit(["method": "item/completed", "params": ["threadId": "thread", "turnId": "turn", "item": ["type": "agentMessage", "phase": "commentary", "text": "途中経過"]]])
            let summary = MinutesSummary(summaryMd: "確認済みの要約", decisions: [.init(text: "発売を決定", evidence: mode == "badEvidence" ? [999] : [17])], actionItems: [], openQuestions: [], keytermsLearned: [])
            let json = String(decoding: try JSONCoding.encoder().encode(summary), as: UTF8.self)
            try emit(["method": "item/completed", "params": ["threadId": "thread", "turnId": "turn", "item": ["id": "item", "type": "agentMessage", "phase": "final_answer", "text": json]]])
            let failed = mode == "turnFailed" || mode == "wrongTurnError" || (failure != nil && mode != "retryThenSuccess")
            var turn: [String: Any] = ["id": "turn", "status": failed ? "failed" : "completed", "items": []]
            if let failure, !["notificationOnly", "notificationAfterAck", "retryThenFailed", "retryThenSuccess"].contains(mode) { turn["error"] = failure }
            try emit(["method": "turn/completed", "params": ["threadId": "thread", "turn": turn]])
            if mode != "notificationAfterAck" { try respond(["turn": ["id": "turn", "status": "inProgress", "items": []]]) }
        default: Issue.record("Unexpected method: \(method)")
        }
    }

    func close() {
        isClosed.withLock { $0 = true }
        continuation.finish()
    }
}

@Suite("Codex app server")
struct CodexSummarizerTests {
    func input() -> SummaryInput {
        SummaryInput(meetingTitle: "テスト会議", startedAt: nil, attendees: [], segments: [
            .init(id: 17, track: "mic", tStart: 0, tEnd: 2, speaker: "me", text: "発売を決定します。"),
        ])
    }

    @Test("ChatGPT / Codex の同梱 CLI は新形式を優先し、旧形式にも対応する", arguments: ["ChatGPT.app", "Codex.app"])
    func bundledExecutableSelection(application: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent(application)
        let legacy = bundle.appendingPathComponent("Contents/Resources/codex")
        let packaged = bundle.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let launcher = bundle.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        for url in [legacy, packaged, launcher] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        #expect(try CodexAppServerClient.executable(configuredPath: nil, applicationRoots: [root]) == launcher)
        try FileManager.default.removeItem(at: launcher)
        #expect(try CodexAppServerClient.executable(configuredPath: nil, applicationRoots: [root]) == packaged)
        try FileManager.default.removeItem(at: packaged)
        #expect(try CodexAppServerClient.executable(configuredPath: nil, applicationRoots: [root]) == legacy)
        // 明示指定は自動検出より優先し、指定先が消えても別の CLI に戻らない。
        #expect(try CodexAppServerClient.executable(configuredPath: legacy.path, applicationRoots: [root]) == legacy)
        #expect(throws: CodexError.executableNotFound) {
            try CodexAppServerClient.executable(configuredPath: launcher.path, applicationRoots: [root])
        }
    }

    @Test("別のアプリの新形式も、旧形式の同梱 CLI より優先する")
    func newLayoutAcrossApplications() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("ChatGPT.app/Contents/Resources/codex")
        let current = root.appendingPathComponent("Codex.app/Contents/Resources/codex-cli/bin/codex")
        for url in [legacy, current] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        #expect(try CodexAppServerClient.executable(configuredPath: nil, applicationRoots: [root]) == current)
        #expect(try CodexAppServerClient.executable(configuredPath: legacy.path, applicationRoots: [root]) == legacy)
    }

    @Test("失敗理由を区別し、本文や認証情報をエラー表示に含めない", arguments: [
        "modelUnavailable", "rpcModelUnavailable", "upgradeRequired", "usageLimit", "rateLimit", "contextLimit",
        "unauthorized", "httpUnauthorized", "connectionFailed", "serviceUnavailable", "unknownFailure",
        "notificationOnly", "notificationAfterAck", "wrongTurnError", "retryThenFailed",
    ])
    func failureReasons(mode: String) async throws {
        let expected: CodexError
        switch mode {
        case "modelUnavailable", "rpcModelUnavailable": expected = .modelUnavailable
        case "upgradeRequired": expected = .upgradeRequired
        case "usageLimit", "notificationOnly", "notificationAfterAck": expected = .usageLimitExceeded
        case "rateLimit": expected = .rateLimitExceeded
        case "contextLimit": expected = .contextWindowExceeded
        case "unauthorized", "httpUnauthorized": expected = .loginRequired
        case "connectionFailed": expected = .connectionFailed
        case "serviceUnavailable": expected = .serviceUnavailable
        default: expected = .turnFailed("failed")
        }
        let transport = MockCodexTransport(mode: mode)
        let summarizer = try CodexSummarizer(client: .init(timeoutSeconds: 1, transportFactory: { _ in transport }))
        do {
            _ = try await summarizer.summarize(input())
            Issue.record("失敗した turn が成功扱いになった")
        } catch let error as CodexError {
            #expect(error == expected)
            let description = error.localizedDescription
            #expect(!description.contains("secret"))
            #expect(!description.contains("Bearer"))
            if expected != .usageLimitExceeded { #expect(!description.contains("利用上限")) }
        }
        #expect(transport.isClosed.withLock { $0 })
    }

    @Test("再試行中の error 通知だけでは要約を失敗にしない")
    func retryThenSuccess() async throws {
        let transport = MockCodexTransport(mode: "retryThenSuccess")
        let summarizer = try CodexSummarizer(client: .init(timeoutSeconds: 1, transportFactory: { _ in transport }))
        let summary = try await summarizer.summarize(input())
        #expect(summary.decisions.first?.evidence == [17])
        #expect(transport.isClosed.withLock { $0 })
    }

    @Test("初期化・ログイン・一時 thread・構造化出力・完了待ち・実モデルの記録")
    func protocolFlow() async throws {
        let transport = MockCodexTransport()
        let client = CodexAppServerClient(transportFactory: { _ in transport })
        let summarizer = try CodexSummarizer(client: client)
        let summary = try await summarizer.summarize(input())
        #expect(summary.decisions.first?.evidence == [17])
        #expect(summarizer.modelDescription.contains("codex/test-model"))
        #expect(transport.isClosed.withLock { $0 })
        let calls = try transport.calls.withLock { $0 }.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        #expect(calls.compactMap { $0["method"] as? String } == ["initialize", "initialized", "account/read", "config/read", "thread/start", "turn/start"])
        let thread = try #require(calls.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        #expect(thread["ephemeral"] as? Bool == true)
        #expect(thread["sandbox"] as? String == "read-only")
        #expect(thread["approvalPolicy"] as? String == "never")
        #expect((thread["config"] as? [String: Any])?["mcp_servers.private-server.enabled"] as? Bool == false)
        let turn = try #require(calls.last?["params"] as? [String: Any])
        #expect((turn["outputSchema"] as? [String: Any])?["additionalProperties"] as? Bool == false)
    }

    @Test("ログイン未完了・失敗・切断・無効な出力を成功扱いにしない", arguments: ["loggedOut", "rpcError", "turnFailed", "serverRequest", "badEvidence", "disconnect", "malformed"])
    func failures(mode: String) async throws {
        let transport = MockCodexTransport(mode: mode)
        let summarizer = try CodexSummarizer(client: .init(timeoutSeconds: 1, transportFactory: { _ in transport }))
        await #expect(throws: (any Error).self) { _ = try await summarizer.summarize(input()) }
        #expect(transport.isClosed.withLock { $0 })
    }

    @Test("タイムアウトとキャンセルはプロセスを閉じる")
    func timeoutAndCancellation() async throws {
        let hung = MockCodexTransport(mode: "hang")
        let summarizer = try CodexSummarizer(client: .init(timeoutSeconds: 0.05, transportFactory: { _ in hung }))
        await #expect(throws: CodexError.timeout) { _ = try await summarizer.summarize(input()) }
        #expect(hung.isClosed.withLock { $0 })
        let cancelled = MockCodexTransport(mode: "hang")
        let second = try CodexSummarizer(client: .init(transportFactory: { _ in cancelled }))
        let task = Task { try await second.summarize(input()) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(cancelled.isClosed.withLock { $0 })
    }

    @Test("接続確認は推論を始めず、ログイン・設定・モデル一覧（全ページ・非表示を除く）だけを読む")
    func connection() async throws {
        let transport = MockCodexTransport()
        let client = CodexAppServerClient(transportFactory: { _ in transport })
        let connection = try await client.checkConnection()
        #expect(connection.account == "chatgpt")
        #expect(connection.models.map(\.id) == ["test-model", "fast-model"])
        // config.toml の model が一覧の既定より優先される
        #expect(connection.defaultModel?.displayName == "Fast")
        let calls = try transport.calls.withLock { $0 }.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        #expect(calls.compactMap { $0["method"] as? String } == ["initialize", "initialized", "account/read", "config/read", "model/list", "model/list"])
        #expect(transport.isClosed.withLock { $0 })

        let unconfigured = MockCodexTransport(mode: "unconfiguredModel")
        let fallback = try await CodexAppServerClient(transportFactory: { _ in unconfigured }).checkConnection()
        #expect(fallback.configuredModel == nil)
        #expect(fallback.defaultModel?.displayName == "Test Model")
    }

    @Test("モデル一覧を取得できなくても接続確認は成功する")
    func connectionWithoutModelList() async throws {
        let transport = MockCodexTransport(mode: "noModelList")
        let connection = try await CodexAppServerClient(transportFactory: { _ in transport }).checkConnection()
        #expect(connection.account == "chatgpt")
        #expect(connection.models.isEmpty)
        #expect(connection.defaultModel?.id == "fast-model")
    }

    @Test("選んだモデルを thread/start とキャッシュの同一性に使い、空欄は Codex の既定にする")
    func modelSelection() async throws {
        func threadParams(_ transport: MockCodexTransport) throws -> [String: Any] {
            let calls = try transport.calls.withLock { $0 }.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
            return try #require(calls.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        }
        let selected = MockCodexTransport()
        let summarizer = try CodexSummarizer(client: .init(transportFactory: { _ in selected }), model: " fast-model ")
        _ = try await summarizer.summarize(input())
        #expect(try threadParams(selected)["model"] as? String == "fast-model")
        #expect(summarizer.cacheIdentity.hasPrefix("codex/fast-model/"))

        let automatic = MockCodexTransport()
        let fallback = try CodexSummarizer(client: .init(transportFactory: { _ in automatic }), model: "  ")
        _ = try await fallback.summarize(input())
        #expect(try threadParams(automatic)["model"] == nil)
        #expect(fallback.cacheIdentity.hasPrefix("codex/default/"))
    }

    @Test("旧設定を保持し、要約だけ Codex を既定にする")
    func migration() throws {
        var old = AppSettings()
        old.defaultPrivacyMode = .localOnly
        old.summaryModel = "custom-claude"
        old.syncDirectory = "/example/sync"
        let decoded = try JSONCoding.decoder().decode(AppSettings.self, from: JSONCoding.encoder().encode(old))
        #expect(decoded.resolvedSummaryProvider == .codex)
        #expect(decoded.summaryModel == "custom-claude")
        #expect(decoded.defaultPrivacyMode == .localOnly)
        #expect(decoded.syncDirectory == "/example/sync")
    }

    @Test("空の根拠・存在しない根拠を保存しない")
    func evidence() throws {
        let summary = MinutesSummary(summaryMd: "要約", decisions: [.init(text: "決定", evidence: [])], actionItems: [], openQuestions: [], keytermsLearned: [])
        #expect(throws: CodexError.invalidResponse) { try CodexSummarizer.validate(summary, validIds: [17]) }
    }

    @Test("長時間または長文の会議を分割する")
    func chunking() {
        var value = input()
        value.segments.append(.init(id: 18, track: "mic", tStart: 3_000, tEnd: 6_000, speaker: "me", text: "次の議題"))
        #expect(StructuredSummary.parts(value).count == 2)
        value.segments[1].tStart = 2
        value.segments[1].tEnd = 3
        value.segments[1].text = String(repeating: "あ", count: 50_000)
        #expect(StructuredSummary.parts(value).count == 2)
    }

    @Test("実 transport は分割された JSONL と stderr を処理する")
    func processTransport() async throws {
        let script = "import sys,time; sys.stdin.readline(); sys.stderr.write('x'*100000); sys.stderr.flush(); b='{\"text\":\"日本語\"}\\n'.encode(); sys.stdout.buffer.write(b[:12]); sys.stdout.flush(); time.sleep(.03); sys.stdout.buffer.write(b[12:]); sys.stdout.flush(); time.sleep(.1)"
        let transport = try CodexProcessTransport(executable: URL(fileURLWithPath: "/usr/bin/python3"), directory: FileManager.default.temporaryDirectory, arguments: ["-u", "-c", script])
        defer { transport.close() }
        try transport.send(Data("{}".utf8))
        var iterator = transport.messages.makeAsyncIterator()
        let line = try #require(try await iterator.next())
        #expect(String(decoding: line, as: UTF8.self) == #"{"text":"日本語"}"#)
    }

    @Test("Codex 実接続で架空の会議を要約", .enabled(if: ProcessInfo.processInfo.environment["MINUTES_CODEX_LIVE"] == "1"))
    func liveSmoke() async throws {
        // MINUTES_CODEX_MODEL に model/list の id を指定すると、そのモデルで要約する（未指定は Codex の既定）。
        let model = ProcessInfo.processInfo.environment["MINUTES_CODEX_MODEL"]
        let summarizer = try CodexSummarizer(model: model, timeoutSeconds: 90)
        let connection = try await summarizer.checkConnection()
        #expect(!connection.models.isEmpty)
        if let model { #expect(connection.models.contains { $0.id == model }) }
        let summary = try await summarizer.summarize(input())
        #expect(!summary.summaryMd.isEmpty)
        #expect(summary.decisions.contains { $0.evidence.contains(17) })
        #expect(!summarizer.modelDescription.contains("/default"))
        if let model { #expect(summarizer.modelDescription.hasPrefix("codex/\(model) ")) }
    }
}
