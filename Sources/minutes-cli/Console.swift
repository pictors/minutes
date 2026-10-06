import Darwin
import Foundation
import MinutesCore

/// stdout（データ）と stderr（進捗・ログ）を分ける。
enum Console {
    static func out(_ text: String) {
        print(text)
        fflush(stdout)
    }

    static func info(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data(("error: " + text + "\n").utf8))
    }

    static let isTTY: Bool = isatty(STDOUT_FILENO) != 0

    /// 同じ行を上書きする（ライブ字幕の途中結果用）。TTY でなければ何もしない。
    static func overwriteLine(_ text: String) {
        guard isTTY else { return }
        let width = terminalWidth()
        var line = text.replacingOccurrences(of: "\n", with: " ")
        if line.count > width - 1 { line = String(line.suffix(width - 2)) }
        FileHandle.standardOutput.write(Data(("\r\u{1B}[K" + line).utf8))
    }

    static func clearLine() {
        guard isTTY else { return }
        FileHandle.standardOutput.write(Data("\r\u{1B}[K".utf8))
    }

    static func terminalWidth() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 20 { return Int(size.ws_col) }
        return 100
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes > 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes > 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
}

/// 1 回の録音にだけシグナルとタイマーを登録し、終了時に解除する。
final class RecordingSignals {
    private var sources: [DispatchSourceSignal] = []
    /// 元の処理。既定（SIG_DFL）は nil なので Optional で持つ。
    private var previousHandlers: [(Int32, sig_t?)] = []
    private var timer: DispatchSourceTimer?
    private let request: RecordingStopRequest

    init(request: RecordingStopRequest) {
        self.request = request
        for sig in [SIGINT, SIGTERM] {
            previousHandlers.append((sig, signal(sig, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { request.request(.signal) }
            source.resume()
            sources.append(source)
        }
    }

    func startTimeout(_ seconds: Double?) {
        guard let seconds, seconds.isFinite, seconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [request] in request.request(.timeout) }
        timer.resume()
        self.timer = timer
    }

    func close() {
        timer?.cancel()
        timer = nil
        for source in sources { source.cancel() }
        sources = []
        for (sig, handler) in previousHandlers { signal(sig, handler) }
        previousHandlers = []
    }

    deinit { close() }
}

/// JSONL の追記書き込み。
final class JSONLinesWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ line: String) {
        lock.withLock {
            guard !closed else { return }
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    func append<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value) {
            append(String(decoding: data, as: UTF8.self))
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? handle.close()
        }
    }
}

enum Statistics {
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[rank]
    }
}
