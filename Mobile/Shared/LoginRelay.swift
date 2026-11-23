import Foundation
import MinutesKit
import WatchConnectivity

/// iPhone のログインを Watch に渡す（製品版の P4）。WatchConnectivity の applicationContext で送る（対の端末のあいだは暗号化される）。
/// - iPhone: 起動・ログイン・ログアウトのたびに今のログインを送る。ログアウトしたら印のない内容を送り、Watch でも消す。
/// - Watch: 受け取った印を自分の Keychain に置き、録音を直接サーバーへ上げるのに使う（iPhone が近くにあれば、watchOS は iPhone を通して送る）。
///   送り先のサーバーが Watch と違う印（手元のサーバーの印など）は受け取らない。
final class LoginRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = LoginRelay()

    /// Watch: ログインが変わった
    @MainActor var onChange: (() -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    #if os(iOS)
    /// iPhone: 今のログインを Watch に送る。
    func sendLogin() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        var context: [String: Any] = ["host": CloudEnvironment.baseURL.host ?? "", "sent_at": Date().timeIntervalSince1970]
        if let token = TokenStore.shared.token() {
            context["token"] = token
            context["user_id"] = TokenStore.shared.stored?.user?.id ?? ""
            context["email"] = TokenStore.shared.stored?.user?.email ?? ""
        }
        do {
            try session.updateApplicationContext(context)
        } catch {
            Log.network.error("watch_login_send_failed \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        sendLogin()
    }
    #endif

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        #if os(iOS)
        sendLogin()
        #else
        apply(session.receivedApplicationContext)
        #endif
    }

    #if os(watchOS)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    private func apply(_ context: [String: Any]) {
        guard !context.isEmpty else { return }
        // 違うサーバーの印は使わない（開発のビルドの手元のサーバーの印を、本番に送らないように）
        guard (context["host"] as? String) == CloudEnvironment.baseURL.host else { return }
        if let token = context["token"] as? String, !token.isEmpty {
            let id = (context["user_id"] as? String) ?? ""
            let email = (context["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            try? TokenStore.shared.save(token: token, user: id.isEmpty ? nil : MinutesCloudUser(id: id, email: email), method: .phone)
        } else {
            TokenStore.shared.clear()
        }
        Task { @MainActor [weak self] in self?.onChange?() }
    }
    #endif
}
