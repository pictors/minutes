import AppKit
import AuthenticationServices
import MinutesCore

// Sign in with Apple のウェブの流れ（SPEC §5.6）。Developer ID で配る Mac のアプリはネイティブの Sign in with Apple（entitlement）を
// 使えないので、ASWebAuthenticationSession でブラウザを開き、サーバー経由で Apple のページを通す（約束は MinutesKit の MinutesCloudAppleWeb）。
// AuthenticationServices（macOS 26 の SDK の swiftinterface で確認）:
//   ASWebAuthenticationSession(url:callback:completionHandler:) と Callback.customScheme(_:)（macOS 14.4 以降）、
//   presentationContextProvider、prefersEphemeralWebBrowserSession、start()。断ったときは ASWebAuthenticationSessionError.canceledLogin。
// 既定のブラウザが対応していればそこで、なければ Safari で開く。ブラウザの Apple のログインを使えるよう、ephemeral にはしない。

/// ブラウザで Apple のページを通し、戻りの URL を受け取る。
@MainActor
final class AppleWebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: LocalizedError {
        /// 利用者が閉じた・Apple のページで断った（画面には何も出さない）
        case cancelled
        case failed
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .cancelled: nil
            case .failed: "Apple でサインインできませんでした。もう一度試してください。"
            case .couldNotStart: "ブラウザを開けませんでした。"
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    /// ブラウザを開き、戻ってきた一度だけのコードを返す。
    func authorize(_ attempt: MinutesCloudAppleWeb, baseURL: URL) async throws -> String {
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            // 戻りの呼び出しはメインスレッドの外で来る。@Sendable を付けないと、このクロージャが MainActor のものになり、
            // Swift 6 の実行時の確かめで落ちる（2026-11-26 に確かめ用の実行ファイルで見た）。中では続きを再開するだけにする
            let session = ASWebAuthenticationSession(url: attempt.startURL(baseURL: baseURL), callback: .customScheme(MinutesCloudAppleWeb.callbackScheme)) { @Sendable url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    continuation.resume(throwing: Failure.failed)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: Failure.couldNotStart)
            }
        }
        session = nil
        do {
            return try MinutesCloudAppleWeb.code(fromCallback: url)
        } catch MinutesCloudAppleWeb.CallbackError.cancelled {
            throw Failure.cancelled
        } catch {
            throw Failure.failed
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }
}
