import CryptoKit
import Foundation

/// Minutes（キーなし）: Pictors のサーバーで要約する（製品版の有料の手段、SPEC §5.6）。
/// 話者の名前などを解いたあとの SummaryInput をそのまま送る（サーバーは Mac と同じ指示文と出力の形で要約する）。
/// キーなしで文字起こしした会議（同じ組。SummaryContext.cloudGroup）だけで使える。同じ入力の要約は同じ依頼（client_id）にする。
public struct MinutesCloudSummarizer: Summarizing {
    public var client: MinutesCloudClient
    public var pollInterval: Duration
    public var timeout: Duration

    public init(client: MinutesCloudClient, pollInterval: Duration = .seconds(3), timeout: Duration = .seconds(1800)) {
        self.client = client
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    public var modelDescription: String { "minutes.cloud" }
    public var cacheIdentity: String { "minutes.cloud/\(client.baseURL)" }

    /// 会議が分からない（組がない）ときは頼めない。誤りは MinutesCloudError のまま投げる（要約の失敗は会議を失敗にせず警告になる）
    public func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
        throw MinutesCloudError.http(status: 403, code: "no_transcription", requestID: nil)
    }

    public func summarize(_ input: SummaryInput, context: SummaryContext) async throws -> MinutesSummary {
        guard let group = context.cloudGroup else { return try await summarize(input) }
        let clientID = "mac-summary-" + SHA256.hash(data: try JSONCoding.encoder(pretty: false).encode(input) + Data(group.utf8))
            .prefix(20).map { String(format: "%02x", $0) }.joined()
        var job = try await client.createSummary(clientID: clientID, group: group, input: input)
        let deadline = ContinuousClock.now + timeout
        while !job.isFinished {
            guard ContinuousClock.now < deadline else { throw MinutesCloudError.timedOut("要約（\(job.status)）") }
            try await Task.sleep(for: pollInterval)
            job = try await client.summary(id: job.id)
        }
        guard job.status == "done", let summary = job.result else { throw MinutesCloudError.failed(job.error ?? "理由は分からない") }
        return summary
    }
}
