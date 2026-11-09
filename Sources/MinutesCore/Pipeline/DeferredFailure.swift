import Foundation

/// 後処理を失敗にせず、条件がそろってからやり直す理由（SPEC §8）。
public enum DeferReason: String, Sendable, Equatable {
    /// 処理中に Mac がスリープした（蓋を閉じたなど）。
    case sleep
    /// 回線が切れた・つながらない。
    case network
    /// 文字起こしの事業者が混んでいる・一時的な障害（HTTP 408・429・5xx）。
    case server

    /// 待っているあいだ画面に出す短い説明（後処理の依頼の error に入れる）。
    public var waitingMessage: String {
        switch self {
        case .sleep: "スリープで中断しました。まもなく再開します"
        case .network: "回線を待っています"
        case .server: "文字起こしの混雑がおさまるのを待っています"
        }
    }
}

/// 一時的な理由で止めた後処理。キューは依頼を失敗にせず、条件がそろったら続きから再開する（会議は処理中のまま）。
public struct DeferredFailure: Error, LocalizedError, Sendable {
    public var reason: DeferReason
    public var step: PipelineStep
    /// 元のエラーの説明（pipeline_runs に残す）。
    public var underlying: String

    public init(reason: DeferReason, step: PipelineStep, underlying: String) {
        self.reason = reason
        self.step = step
        self.underlying = underlying
    }

    public var errorDescription: String? {
        "\(reason.waitingMessage)（\(step.title): \(Log.preview(underlying, limit: 160))）"
    }
}

/// 一時的な失敗の扱い（SPEC §8.2）。
public struct RetryPolicy: Sendable, Equatable {
    /// 手順の途中で Mac がスリープしたら、失敗にせず待ってやり直す。任意の手順（要約・書き出し）もスリープのときだけ待つ。
    public var deferOnSleep: Bool
    /// クラウドの文字起こしが回線・混雑で失敗したら、ローカルに切り替えずに待ってクラウドでやり直す。
    public var deferTransientCloudFailures: Bool

    public init(deferOnSleep: Bool, deferTransientCloudFailures: Bool) {
        self.deferOnSleep = deferOnSleep
        self.deferTransientCloudFailures = deferTransientCloudFailures
    }

    /// CLI と直接の呼び出し: 待たずに、これまでどおりその場でローカルに切り替える。
    public static let immediate = RetryPolicy(deferOnSleep: false, deferTransientCloudFailures: false)
    /// アプリの後処理キュー: 待ってやり直す。
    public static let deferred = RetryPolicy(deferOnSleep: true, deferTransientCloudFailures: true)
}

/// 送信中にスリープを挟んだため、送信を止めた（接続はスリープで切れている）。
struct SleepInterruption: Error, LocalizedError {
    var errorDescription: String? { "送信中に Mac がスリープしました" }
}

enum TransientFailure {
    /// 回線が切れた・つながらないときの URLError。
    static let networkCodes: Set<URLError.Code> = [
        .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed,
    ]

    /// クラウドの文字起こしの失敗のうち、待ってやり直せば通りそうなものの理由。キーの誤りや音声の形式などは nil（ローカルに切り替える）。
    static func reason(for error: Error) -> DeferReason? {
        if error is SleepInterruption { return .sleep }
        if let error = error as? URLError { return networkCodes.contains(error.code) ? .network : nil }
        if case let .httpError(_, status, _, _)? = error as? TranscriptionError {
            return status == 408 || status == 429 || (500...599).contains(status) ? .server : nil
        }
        let error = error as NSError
        if error.domain == NSURLErrorDomain { return networkCodes.contains(URLError.Code(rawValue: error.code)) ? .network : nil }
        return nil
    }
}
