import MinutesKit
import Observation
import UIKit
import UserNotifications

/// 処理が終わったときの通知（製品版。SPEC §5.7）。サーバーが APNs で「議事録ができた」「処理できなかった」を送る
/// （iPhone・Watch で録った会議だけ。文面は録った日時・機器・長さだけで、会議の名前や中身は入れない）。
/// - 許可は、議事録を待つ会議ができてから一覧の上で聞く（いきなり OS の確認を出さない。断られると設定のアプリからしか戻せない）。
///   アカウントの画面からも聞ける。
/// - 許されていれば起動のたびに APNs に登録し、届いたトークンをいまのログインに登録する（PUT /v1/push-devices）。
///   サーバーは、ログアウト・ログインの取り消し・アカウントの削除で登録を消し、ログインが生きている端末にだけ送る。
/// - 押した通知は、その会議を開く（`openRequest`）。アプリが前に出ているときは通知を出さず、一覧を読み直す。
/// - Watch には、iPhone の通知が転送される（iPhone がロック中で、Watch を着けているとき）。Watch は登録しない（二重に出ないように）。
@MainActor
@Observable
final class PushNotifications {
    static let shared = PushNotifications()

    /// 通知の許可。起動と、アプリが前に出たときに読み直す（設定のアプリで変えられる）
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// 許可を一度でも読めたか（読むまでは、一覧の誘いを出さない）
    private(set) var authorizationLoaded = false
    /// 一覧の上の誘いを「あとで」で閉じた（覚えておく。アカウントの画面からは、いつでも受け取れる）
    private(set) var promptDismissed: Bool
    /// 押した通知の会議（client_id）。一覧がその会議を開いたら消す
    var openRequest: String?
    /// アプリが前に出ているときに通知が届いた（一覧を読み直す）
    @ObservationIgnored var onForegroundNotification: (() -> Void)?

    @ObservationIgnored private let centerDelegate = NotificationCenterDelegate()
    @ObservationIgnored private var deviceToken: Data?
    /// いまのログインに登録したトークンと環境（同じなら送り直さない。ログインが替わったら消す）
    @ObservationIgnored private var registered: String?

    private static let promptDismissedKey = "notificationPromptDismissed"

    private init() {
        promptDismissed = UserDefaults.standard.bool(forKey: Self.promptDismissedKey)
    }

    var isAllowed: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// 起動したとき（AppDelegate の didFinishLaunching の中）: delegate を付け（押して起動した通知も受け取れるように）、許可を読む。
    func activate() {
        UNUserNotificationCenter.current().delegate = centerDelegate
        Task { await refreshAuthorization() }
    }

    /// 許可を読み直す（起動・前に出たとき）。許されていて、まだトークンがなければ APNs に登録する（トークンは AppDelegate に届く）。
    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
        authorizationLoaded = true
        guard isAllowed, deviceToken == nil else { return }
        #if DEBUG
        // 開発のビルドだけ: シミュレータは APNs につながらず、トークンが届かないことがある。
        // 環境変数 MINUTES_PUSH_TEST_TOKEN（16 進）の偽のトークンで、サーバーへの登録の道を確かめる（AGENTS.md）
        if let token = Self.debugToken {
            didRegister(deviceToken: token)
            return
        }
        #endif
        UIApplication.shared.registerForRemoteNotifications()
    }

    #if DEBUG
    private static var debugToken: Data? {
        guard let hex = ProcessInfo.processInfo.environment["MINUTES_PUSH_TEST_TOKEN"], !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
    #endif

    /// 「通知を受け取る」: OS の確認を出す。許されたら登録する。
    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.network.notice("push_authorization_failed \(error.localizedDescription, privacy: .public)")
        }
        await refreshAuthorization()
    }

    /// 一覧の上の誘いを閉じる（「あとで」）。
    func dismissPrompt() {
        promptDismissed = true
        UserDefaults.standard.set(true, forKey: Self.promptDismissedKey)
    }

    // MARK: APNs とサーバー

    /// APNs のトークンが届いた（AppDelegate）。ログインしていれば、いまのログインに登録する。
    func didRegister(deviceToken: Data) {
        self.deviceToken = deviceToken
        Task { await registerWithServer() }
    }

    func didFailToRegister(_ error: Error) {
        Log.network.notice("push_register_failed \(error.localizedDescription, privacy: .public)")
    }

    /// いまのログインにトークンを登録する（トークンが届いたとき・ログインしたとき）。送れなければ、次の起動・ログインで送り直す。
    func registerWithServer() async {
        guard let token = deviceToken, TokenStore.shared.isSignedIn else { return }
        let environment = MinutesCloudPushEnvironment.current
        let key = MinutesCloudClient.pushTokenHex(token) + "|" + environment.rawValue
        guard key != registered else { return }
        do {
            try await CloudEnvironment.client().registerPushDevice(token: token, environment: environment)
            registered = key
            Log.network.notice("push_device_registered environment=\(environment.rawValue, privacy: .public)")
        } catch {
            Log.network.notice("push_device_register_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    /// ログインした（新しいログインに登録し直す。前のログインの登録は、サーバーがログアウトで消している）。
    func didSignIn() {
        registered = nil
        Task { await registerWithServer() }
    }

    /// ログアウトの前（ログインの印がまだあるうち）: このログインの登録を外す。送れなくても、サーバーはログアウトで登録を消す。
    func willSignOut() async {
        defer { registered = nil }
        guard let token = deviceToken, registered != nil else { return }
        try? await CloudEnvironment.client().unregisterPushDevice(token: token)
    }

    /// サーバーに断られてログアウトした（401。サーバーのログインはもうない）。
    func didSignOutLocally() {
        registered = nil
    }

    // MARK: 届いた通知

    fileprivate func receivedInForeground() {
        onForegroundNotification?()
    }

    fileprivate func open(_ payload: PushPayload) {
        openRequest = payload.clientID
    }
}

/// サーバーの通知の中身（"minutes" の欄）。会議の名前や議事録の中身は入っていない（題名は一覧から読む）。
struct PushPayload: Sendable, Equatable {
    /// "done"（議事録ができた・文字起こしだけできた）か "failed"
    var event: String
    var recordingID: String
    /// 一覧の会議の ID（MeetingItem.id）
    var clientID: String

    init?(_ userInfo: [AnyHashable: Any]) {
        guard let minutes = userInfo["minutes"] as? [String: Any],
              let clientID = minutes["client_id"] as? String, !clientID.isEmpty else { return nil }
        self.clientID = clientID
        recordingID = minutes["recording_id"] as? String ?? ""
        event = minutes["event"] as? String ?? ""
    }
}

/// UNUserNotificationCenter の delegate（NSObject が要る）。受けたものを PushNotifications に渡す。
/// 完了の知らせ（completionHandler）は、呼ばれたスレッド（メインスレッド）のまま、その場で返す。
/// async 版で書くと、完了の知らせが裏のスレッドから呼ばれ、押した通知でアプリが開くときに UIKit の確かめで落ちた
/// （-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]。2026-11-25 にシミュレータで確かめた）。
private final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// アプリが前に出ているとき: Minutes の通知は出さず、一覧を読み直す（処理中の会議は、一覧が数秒ごとに読み直して出している）。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard PushPayload(notification.request.content.userInfo) != nil else {
            completionHandler([.banner, .list, .sound])
            return
        }
        Self.onMain { PushNotifications.shared.receivedInForeground() }
        completionHandler([])
    }

    /// 通知を押した: その会議を開く。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let payload = PushPayload(response.notification.request.content.userInfo) {
            Self.onMain { PushNotifications.shared.open(payload) }
        }
        completionHandler()
    }

    /// UserNotifications は delegate をメインスレッドで呼ぶ。そうでなかったときだけ、メインスレッドへ回す。
    private nonisolated static func onMain(_ action: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            Task { @MainActor in action() }
        }
    }
}

extension MinutesCloudPushEnvironment {
    /// このビルドの APNs の環境。シミュレータは sandbox。開発のビルド（Xcode・devicectl で入れたもの）は、埋め込みのプロファイルの
    /// aps-environment が development。TestFlight・App Store のビルドにはプロファイルが入らないので、本番とみなす
    /// （取り違えても、サーバーがもう一方の環境で試して直す）。
    static var current: MinutesCloudPushEnvironment {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return .production }
        return apsEnvironment(inProvisioningProfile: data) == "development" ? .sandbox : .production
        #endif
    }

    /// プロファイル（CMS で包んだ plist）の Entitlements の aps-environment。署名は確かめない（読むのは環境の名前だけ）。
    static func apsEnvironment(inProvisioningProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entitlements = object["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }
}
