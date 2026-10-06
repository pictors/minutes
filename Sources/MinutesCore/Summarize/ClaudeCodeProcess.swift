import Darwin
import Foundation

/// `claude` を 1 回だけ実行する。入力は stdin に書いて閉じ、stdout を EOF まで読む。
/// stderr はプロンプトや認証情報を含む可能性があるため記録せず、起動エラーの判定に先頭だけを使う。
final class ClaudeCodeProcess: @unchecked Sendable {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    static let maxOutputBytes = 16 * 1_024 * 1_024
    static let maxErrorBytes = 8 * 1_024

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    /// stdout の EOF・stderr の EOF・プロセスの終了がそろったら結果を返す。
    private var pending = 3
    private var continuation: CheckedContinuation<Output, Error>?
    private var done = false

    /// タイムアウト・キャンセル・異常な出力量では子プロセスを終了させる。
    static func run(executable: URL, arguments: [String], directory: URL, environment: [String: String], input: Data, timeoutSeconds: Double) async throws -> Output {
        let child = ClaudeCodeProcess(executable: executable, arguments: arguments, directory: directory, environment: environment)
        defer { child.close() }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Output.self) { group in
                group.addTask { try await child.start(input: input) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw ClaudeCodeError.timeout
                }
                defer {
                    group.cancelAll()
                    child.close()
                }
                guard let result = try await group.next() else { throw ClaudeCodeError.invalidResponse }
                return result
            }
        } onCancel: {
            child.close()
        }
    }

    private init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data, fromErrors: false)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data, fromErrors: true)
        }
        process.terminationHandler = { [weak self] _ in self?.arrive() }
    }

    private func start(input data: Data) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            // close() と競合しても、閉じたあとに起動したプロセスを残さないよう起動までをロックの中で行う。
            let launched: Result<Void, Error> = lock.withLock {
                guard !done else { return .failure(CancellationError()) }
                self.continuation = continuation
                do {
                    try process.run()
                    return .success(())
                } catch {
                    return .failure(ClaudeCodeError.launchFailed)
                }
            }
            if case let .failure(error) = launched {
                if error is CancellationError { continuation.resume(throwing: error) } else { finish(.failure(error)) }
                return
            }
            // 親の余分な端を閉じ、子の終了を EOF として検出できるようにする。
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            let writer = input.fileHandleForWriting
            // 子が stdin を読まずに終了しても SIGPIPE でアプリを落とさない。
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            // pipe の容量（64 KB）を超える入力でも、子が読むのを待つ間に呼び出し元を止めない。
            DispatchQueue.global().async {
                try? writer.write(contentsOf: data)
                try? writer.close()
            }
        }
    }

    private func receive(_ data: Data, fromErrors: Bool) {
        if data.isEmpty {
            (fromErrors ? errors : output).fileHandleForReading.readabilityHandler = nil
            arrive()
            return
        }
        let overflow = lock.withLock { () -> Bool in
            if fromErrors {
                stderr.append(data.prefix(max(0, Self.maxErrorBytes - stderr.count)))
                return false
            }
            stdout.append(data)
            return stdout.count > Self.maxOutputBytes
        }
        if overflow {
            finish(.failure(ClaudeCodeError.invalidResponse))
            close()
        }
    }

    private func arrive() {
        let result = lock.withLock { () -> Output? in
            pending -= 1
            guard pending == 0 else { return nil }
            return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        }
        if let result { finish(.success(result)) }
    }

    private func finish(_ result: Result<Output, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Output, Error>? in
            done = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func close() {
        finish(.failure(CancellationError()))
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        lock.withLock {
            guard process.isRunning else { return }
            process.terminate()
            // SIGTERM を無視した場合も自分で起動したプロセスだけを終了する。
            let process = self.process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
