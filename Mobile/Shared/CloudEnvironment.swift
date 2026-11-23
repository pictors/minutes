import Foundation
import MinutesKit

/// サーバーの場所と、録音を送ってよいか（製品版の P4）。
/// - 既定は本番（api.minutes.tools）。開発のビルド（DEBUG）だけ、環境変数 MINUTES_CLOUD_BASE_URL で手元のサーバーに向けられる
///   （シミュレータでは `SIMCTL_CHILD_MINUTES_CLOUD_BASE_URL` で渡す）。
/// - シミュレータのマイクは Mac のマイク（部屋の本当の音）なので、シミュレータからは本番に録音を送らない。手元のサーバーに向けたときだけ送る。
enum CloudEnvironment {
    static let baseURLEnvName = "MINUTES_CLOUD_BASE_URL"

    static var baseURL: URL {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment[baseURLEnvName], let url = URL(string: value) { return url }
        #endif
        return MinutesCloudClient.productionBaseURL
    }

    static var isProduction: Bool { baseURL.host == MinutesCloudClient.productionBaseURL.host }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// 録音をサーバーへ送ってよいか。
    static var uploadsAllowed: Bool { !(isSimulator && isProduction) }

    static func client(token: @escaping @Sendable () -> String? = { TokenStore.shared.token() }) -> MinutesCloudClient {
        MinutesCloudClient(baseURL: baseURL, token: token)
    }
}
