import ActivityKit
import Foundation

/// 録音中の Live Activity（ロック画面とダイナミックアイランド。SPEC §5.7）の中身。iPhone のアプリと拡張（MinutesWidgets）の両方に入る。
/// アプリ（`RecordingActivityController`）が録音の始まり・中断・再開・終わりで出し入れし、拡張（`RecordingLiveActivity`）が描く。
/// 会議の名前は入れない（ロック画面に出るので。処理が終わったときの通知と同じ決まり）。
/// 確認済み（Xcode 27.2 の iOS 27.2 SDK の ActivityKit の swiftinterface）: `ActivityAttributes`（`ContentState: Codable & Hashable`）。
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 録音している（false は、電話・Siri などで止まっていて再開を待つ）
        var isRecording: Bool
        /// 経過時間の数え始め（いまの走の始まりから、閉じた走の合計を引いた時刻）。録音しているあいだだけ
        var timerStart: Date?
        /// 止まっているあいだに出す経過時間（閉じた走の合計の秒数）
        var elapsed: Double
    }
}
