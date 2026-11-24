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
        model.onLaunch()
        return true
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
