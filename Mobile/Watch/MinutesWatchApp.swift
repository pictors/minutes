import MinutesKit
import SwiftUI
import WatchKit

/// Minutes の Watch アプリ（製品版の P4）。Watch だけで録音・一覧・再生・削除ができる（ガイドライン 4.2.3(i)）。
/// 録った音声は iPhone から受け取ったログインで、Watch から直接サーバーへ上げる（iPhone が近くにあれば watchOS は iPhone を通して送る）。
/// 議事録は iPhone のアプリで見る。
@main
struct MinutesWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(delegate.model)
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    @MainActor lazy var model = WatchModel()

    func applicationDidFinishLaunching() {
        model.onLaunch()
    }

    /// 裏の送信が終わって OS に起こされた。UploadEngine の delegate が結果を書き終えたら、タスクを終える。
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlTask = task as? WKURLSessionRefreshBackgroundTask, urlTask.sessionIdentifier == UploadEngine.sessionIdentifier {
                let previous = model.uploads.backgroundCompletion
                model.uploads.backgroundCompletion = {
                    previous?()
                    urlTask.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
