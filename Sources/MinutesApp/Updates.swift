import AppKit
import Observation
import Sparkle

/// 自動更新（Sparkle 2、SPEC §12 Phase 1.5）。確認するのは配布用のビルド（`scripts/build-app.sh --dist`）だけ。
/// 開発用のビルドは SUFeedURL を外して組み立て、`swift run` は .app でないので、どちらも動かさない
/// （署名の違う公式の版に置き換えようとしない）。
/// メニューバーに常駐するアプリなので、予定の確認で見つけた新しい版は、ほかのアプリの前に窓を出さず
/// （Sparkle の gentle reminder）、通知とメニューバーのパネルで知らせる。
@MainActor
@Observable
final class UpdateController: NSObject {
    /// 予定の確認で見つけたが、まだ見てもらっていない新しい版（表示用の版の番号）
    private(set) var pendingVersion: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    /// 自動更新を使うビルドか（使わないビルドでは更新の操作を出さない）
    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// 利用者が選んだ確認。メニューバーのアプリは前面にいないので、先に前へ出して Sparkle の窓を見えるようにする。
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 予定の確認で見つけた版は、Minutes が前面にいるときだけ Sparkle に窓を出させる。
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        pendingVersion = update.displayVersionString
        AppModel.postNotification(title: "Minutes の新しい版があります",
                                  body: "\(update.displayVersionString) に更新できます。メニューバーのパネルの設定のメニューから入れられます。")
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
