import Foundation
import Observation

/// Watch で「録音を始める」の求め（文字盤のコンプリケーション・コントロールセンター・Siri・ショートカット。SPEC §5.7）を、
/// アプリの最初の画面へ渡す口。Watch のアプリと拡張（MinutesWatchWidgets）の両方に入る。
/// どの入口も録音そのものは始めず、ここに求めを立てるだけにする。始めるのは、アプリが前面で動いているときの `WatchRootView` で、
/// 「録音」のボタンと同じ流れ（最初の録音の前の告知、録音中なら何もしない）を通る。
/// watchOS は前面で始めた録音だけを、手首を下ろしても続けさせるので、前面になる前には始めない。
@MainActor
@Observable
final class QuickRecord {
    static let shared = QuickRecord()

    /// コンプリケーションを押したときに開く URL（`widgetURL`）。WidgetKit の文書（「Linking to specific app scenes from your widget」）では、
    /// システムが元のアプリを開いて `onOpenURL` に渡す。watchOS の実機で届くかはまだ確かめていない（届かなければ、押すとアプリが開くだけ）。
    /// watchOS は他社のアプリの URL スキームを登録しない（シミュレータで、Info.plist の CFBundleURLTypes は効かず、
    /// `simctl openurl` は「受け手がない」だった）ので、ほかからこの URL を開くことはできない。
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
