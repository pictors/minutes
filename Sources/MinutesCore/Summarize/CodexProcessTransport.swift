import Darwin
import Foundation

/// app-server の JSONL transport。stdout の行境界と UTF-8 の分割は Data のまま処理する。
/// stderr はプロンプトや認証情報を含む可能性があるため保存せず、詰まらないよう排出する。
protocol CodexTransport: Sendable {
    var messages: AsyncThrowingStream<Data, Error> { get }
    func send(_ data: Data) throws
    func close()
}

final class CodexProcessTransport: CodexTransport, @unchecked Sendable {
    let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false

    init(executable: URL, directory: URL, arguments: [String] = CodexAppServerClient.arguments) throws {
        (messages, continuation) = AsyncThrowingStream.makeStream()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        do {
            try process.run()
        } catch {
            close()
            throw CodexError.launchFailed
        }
        // 親の余分な write end を閉じ、子の終了を EOF として検出できるようにする。
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }

    func send(_ data: Data) throws {
        try lock.withLock {
            guard !closed, process.isRunning else { throw CodexError.disconnected }
        }
        // pipe が詰まっても close() がロック待ちにならないようにする。
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
    }

    private func receive(_ data: Data) {
        lock.withLock {
            guard !closed else { return }
            if data.isEmpty {
                output.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: CodexError.disconnected)
                return
            }
            buffer.append(data)
            // 不正なサーバーによる無制限のメモリ消費を防ぐ。
            guard buffer.count <= 16 * 1_024 * 1_024 else {
                continuation.finish(throwing: CodexError.invalidResponse)
                return
            }
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                if !line.isEmpty { continuation.yield(line) }
            }
        }
    }

    func close() {
        let shouldClose = lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        continuation.finish()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // SIGTERM を無視した場合も自分で起動したプロセスだけを終了する。
            let process = self.process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    deinit { close() }
}

public enum CodexError: Error, LocalizedError, Equatable {
    case executableNotFound
    case launchFailed
    case loginRequired
    case disconnected
    case timeout
    case invalidResponse
    case requestFailed(method: String, code: Int)
    case turnFailed(String)
    case unexpectedRequest
    case unsupportedConfiguration
    case upgradeRequired
    case modelUnavailable
    case usageLimitExceeded
    case rateLimitExceeded
    case contextWindowExceeded
    case connectionFailed
    case serviceUnavailable

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: return "Codex CLI が見つかりません。インストールするか、設定で codex の実行ファイルを指定してください。"
        case .launchFailed: return "Codex app server を起動できません。実行ファイルと Codex の設定を確認してください。"
        case .loginRequired: return "Codex にログインしていません。ターミナルで codex login を実行し、接続を確認してください。"
        case .disconnected: return "Codex app server との接続が終了しました。Codex CLI の更新とログイン状態を確認してください。"
        case .timeout: return "Codex の要約がタイムアウトしました。後処理を再実行できます。"
        case .invalidResponse: return "Codex から有効な構造化要約を受け取れませんでした。"
        case let .requestFailed(method, code): return "Codex の \(method) が失敗しました（code: \(code)）。Codex のログイン・設定・バージョンを確認してください。"
        case let .turnFailed(status): return "Codex の要約が完了しませんでした（\(status)）。接続を確認して再実行してください。"
        case .unexpectedRequest: return "Codex が要約に不要な操作を要求したため処理を中止しました。"
        case .unsupportedConfiguration: return "Codex の MCP サーバー名にドットが含まれるため、要約用の設定を作れません。MCP サーバー名のドットをハイフンに変更してください。"
        case .upgradeRequired: return "このモデルには新しい Codex が必要です。Codex CLI またはデスクトップアプリを更新し、設定の実行ファイルを確認してください。"
        case .modelUnavailable: return "選択したモデルは、この Codex ログインでは利用できません。Codex を更新し、設定の実行ファイルと要約モデルを確認してください。"
        case .usageLimitExceeded: return "Codex の利用上限に達しました。Codex の残り利用量とリセット時刻を確認してください。"
        case .rateLimitExceeded: return "Codex のリクエストが一時的なレート制限に達しました。少し待って再実行してください。"
        case .contextWindowExceeded: return "会議の入力が Codex のコンテキスト上限を超えました。"
        case .connectionFailed: return "Codex の推論サーバーとの通信に失敗しました。接続状態を確認して再実行してください。"
        case .serviceUnavailable: return "Codex の推論サーバーでエラーが発生しました。少し待って再実行してください。"
        }
    }
}
