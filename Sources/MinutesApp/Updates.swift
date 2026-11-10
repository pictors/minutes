import AppKit
import MinutesCore
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
    /// 録音中・後処理の実行中は、更新の再起動（Minutes の終了）を待たせる（SPEC §6.4）
    @ObservationIgnored private let relaunchGate = RelaunchGate()

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
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    /// 利用者が選んだ確認。メニューバーのアプリは前面にいないので、先に前へ出して Sparkle の窓を見えるようにする。
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// 録音中・後処理の実行中か（AppModel が状態の変わるたびに知らせる）。空いたら、遅らせていた再起動を続ける。
    func setBusy(_ busy: Bool) {
        relaunchGate.setBusy(busy)
    }
}

extension UpdateController: SPUUpdaterDelegate {
    /// 録音中・後処理の実行中に「インストールして再起動」を選んだら、再起動（Minutes の終了）をそれが終わるまで遅らせる（SPEC §6.4）。
    /// 確認済み（Sparkle 2.10.0 の SPUInstallerDriver.m）: true を返すと、インストーラに続き（Minutes の終了）を頼まない。
    /// 預けた続きを呼ぶと、もう一度は聞かずに終了を求める（`NSRunningApplication.terminate()`。Minutes の終了の確認を通る）。
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard relaunchGate.shouldPostpone(installHandler) else { return false }
        AppModel.postNotification(title: "録音のあとで Minutes を更新します",
                                  body: "\(item.displayVersionString) は、録音と議事録づくりが終わってから入れて、Minutes を開き直します。")
        return true
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
