import MinutesKit
import SwiftUI
import UIKit

/// Minutes の iPhone アプリ（製品版の P4）。録音して Minutes のサーバーへ送り、議事録を見る。
@main
struct MinutesPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
        }
    }
}

final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    @MainActor lazy var model = PhoneModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 通知の delegate は起動の中で付ける（押した通知でアプリが起動したときも、その通知を受け取れるように）
        PushNotifications.shared.activate()
        model.onLaunch()
        return true
    }

    /// 処理が終わったときの通知（SPEC §5.7）: APNs のトークンが届いた。いまのログインに登録する。
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.shared.didFailToRegister(error)
    }

    /// 裏の送信が終わって OS に起こされた（UploadEngine の delegate が結果を書き終えたら completionHandler を呼ぶ）。
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == UploadEngine.sessionIdentifier else {
            completionHandler()
            return
        }
        model.uploads.backgroundCompletion = completionHandler
    }
}
