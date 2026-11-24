import Foundation
import Observation

/// iPhone で「録音を始める」の求め（ホーム画面・ロック画面のウィジェット、コントロールセンター・ロック画面・アクションボタンのコントロール、
/// Siri・Spotlight・ショートカット。SPEC §5.7）を、アプリの画面へ渡す口。iPhone のアプリと拡張（MinutesWidgets）の両方に入る。
/// Watch には同じ名前・同じ形のものが Mobile/WatchIntents にある（入るターゲットが別なので、名前はぶつからない）。
/// どの入口も録音そのものは始めず、ここに求めを立てるだけにする。始めるのは、アプリが前面にいるときの `QuickRecordHandler`（RootView）。
/// 前面になる前には始めない（マイクの許可を尋ねる画面は前面でないと出ず、裏から始める録音は AVAudioSession に断られることがある '!rec'）。
@MainActor
@Observable
final class QuickRecord {
    static let shared = QuickRecord()

    /// ウィジェットのボタンが Intent を動かさないとき（ロック画面の円）に開く URL（`widgetURL`）。システムが元のアプリを開いて `onOpenURL` に渡す
    /// （シミュレータの iOS 26.5 で確かめた。iPhone のアプリは URL スキームを登録しないので、ほかのアプリからは開けない）。
    nonisolated static let url = URL(string: "minutes://record")!

    /// 求めの有効な時間。前面にならないまま残った求めで、あとでアプリを開いたときに録音が始まらないようにする。
    nonisolated static let lifetime: TimeInterval = 30

    private(set) var requestedAt: Date?

    var isPending: Bool { requestedAt != nil }

    func request(at date: Date = Date()) {
        requestedAt = date
    }

    /// 求めを受け取る。立っていれば下ろし、有効な時間のうちなら true。
    func take(at date: Date = Date()) -> Bool {
        guard let requestedAt else { return false }
        self.requestedAt = nil
        return date.timeIntervalSince(requestedAt) <= Self.lifetime
    }

    nonisolated static func isRecordURL(_ url: URL) -> Bool {
        url.scheme == Self.url.scheme && url.host() == Self.url.host()
    }
}
