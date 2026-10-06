import Foundation

/// 1 回の送信にかかった時間の内訳（G3: 会議の終了から議事録まで 5 分以内）。
/// URLSessionTaskMetrics の最後のトランザクションから、送信（本文を送り終えるまで）と、
/// 待ち（送り終えてから応答の先頭が届くまで = サーバーの処理）を分ける。
public struct UploadTiming: Sendable, Equatable {
    public var uploadSeconds: Double
    public var serverSeconds: Double
    public var bytesSent: Int64

    public init(uploadSeconds: Double, serverSeconds: Double, bytesSent: Int64) {
        self.uploadSeconds = uploadSeconds
        self.serverSeconds = serverSeconds
        self.bytesSent = bytesSent
    }

    init?(_ metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last,
              let requestStart = transaction.requestStartDate,
              let requestEnd = transaction.requestEndDate,
              let responseStart = transaction.responseStartDate else { return nil }
        self.init(uploadSeconds: max(0, requestEnd.timeIntervalSince(requestStart)),
                  serverSeconds: max(0, responseStart.timeIntervalSince(requestEnd)),
                  bytesSent: transaction.countOfRequestBodyBytesSent)
    }

    /// 実効の送信速度（Mbps）。0.5 秒未満で送り終えたときは誤差が大きいので出さない。
    public var megabitsPerSecond: Double? {
        uploadSeconds >= 0.5 ? Double(bytesSent) * 8 / uploadSeconds / 1_000_000 : nil
    }

    /// `TranscriptionResult.providerMeta` に入れる値。
    public var metadata: [String: String] {
        var meta = [
            "upload_seconds": String(format: "%.1f", uploadSeconds),
            "server_seconds": String(format: "%.1f", serverSeconds),
        ]
        if let mbps = megabitsPerSecond { meta["upload_mbps"] = String(format: "%.1f", mbps) }
        return meta
    }

    var summary: String {
        String(format: "upload %.1f s (%@), server %.1f s", uploadSeconds,
               megabitsPerSecond.map { String(format: "%.1f Mbps", $0) } ?? "?", serverSeconds)
    }

    /// pipeline_runs の記録に添える短い説明（「送信 45 s・処理 30 s」）。providerMeta に値がなければ nil。
    public static func note(from meta: [String: String]) -> String? {
        guard let upload = meta["upload_seconds"], let server = meta["server_seconds"] else { return nil }
        return "送信 \(upload) s・処理 \(server) s"
    }
}

/// タスク単位の delegate で計測値を受け取る。
final class UploadTimingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: UploadTiming?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let timing = UploadTiming(metrics)
        lock.withLock { collected = timing }
    }

    var timing: UploadTiming? { lock.withLock { collected } }
}
