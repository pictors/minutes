import Foundation
import MinutesCore

/// Minutes クラウドのアカウント（SPEC §5.6）。ログインの印はアプリと同じ Keychain に置く。
///   minutes-cli account login --email <address>   メールに届いたコードを聞いてログインする
///   minutes-cli account status                    ログインしているか・プランと今月の量
///   minutes-cli account logout
/// サーバーの場所は環境変数 MINUTES_CLOUD_BASE_URL で変えられる（手元のサーバーなど）。印・コードは表示しない。
enum AccountCommand {
    static let spec = ArgumentSpec(options: ["email", "code"], flags: ["json"])

    static func run(_ arguments: [String]) async throws {
        guard let action = arguments.first else { throw ArgumentError.missingPositional("login | status | logout") }
        let parsed = try ArgumentParser.parse(Array(arguments.dropFirst()), spec: spec)
        let client = MinutesCloudClient.standard()
        switch action {
        case "login":
            guard let email = parsed.value("email") else { throw ArgumentError.missingRequired("email") }
            let code: String
            if let given = parsed.value("code") {
                code = given
            } else {
                try await client.sendSignInCode(email: email)
                Console.info("コードを送りました（5 分で切れます）。メールに届いた 6 桁を入れてください:")
                guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else { throw ArgumentError.missingRequired("code") }
                code = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let session = try await client.signIn(email: email, code: code)
            try MinutesCloudCredentials.save(session, email: email)
            Console.out("ログインしました（\(client.baseURL.host ?? client.baseURL.absoluteString)）")
        case "status":
            guard MinutesCloudCredentials.isSignedIn else {
                Console.out("ログインしていません（minutes-cli account login --email <address>）")
                return
            }
            let account = try await client.account()
            if parsed.has("json") {
                Console.out(String(decoding: try JSONCoding.encoder().encode(Status(account)), as: UTF8.self))
                return
            }
            Console.out("ログイン中: \(MinutesCloudCredentials.email() ?? "（メールアドレスは記録していません）")")
            Console.out("プラン: \(account.plan)")
            Console.out(String(format: "今月: %.0f 分（処理中 %.0f 分）/ 上限 %.0f 分", account.usage.secondsThisMonth / 60, account.usage.secondsPending / 60, account.usage.secondsLimit / 60))
        case "logout":
            try? await client.signOut()
            try MinutesCloudCredentials.clear()
            Console.out("ログアウトしました")
        default:
            throw ArgumentError.invalidValue(option: "account", value: action, expected: "login | status | logout")
        }
    }

    private struct Status: Encodable {
        var plan: String
        var secondsThisMonth: Double
        var secondsPending: Double
        var secondsLimit: Double

        init(_ account: MinutesCloudAccount) {
            plan = account.plan
            secondsThisMonth = account.usage.secondsThisMonth
            secondsPending = account.usage.secondsPending
            secondsLimit = account.usage.secondsLimit
        }
    }
}
