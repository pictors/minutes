import AppIntents
import Foundation

/// 「録音を始める」（SPEC §5.7）。コントロールセンターのコントロール（`RecordControl`）、Siri とショートカット（`MinutesWatchShortcuts`）、
/// Ultra のアクションボタンから使う。アプリを前面に出してから、`QuickRecord` に求めを立てる（録音を始めるのはアプリの画面）。
/// アプリを開く Intent は、アプリと拡張の両方に入れる決まり（WidgetKit の文書「Open your app with a control」）なので、
/// このフォルダ（WatchIntents）は Watch のアプリと MinutesWatchWidgets の両方のターゲットに入る。
/// 確認済み（Xcode 27.2 の watchOS 27.2 SDK の AppIntents の swiftinterface）: `AppIntent.supportedModes`（watchOS 26 から。
/// `openAppWhenRun` は 26 で非推奨）、`IntentModes.foreground`（= `.foreground(.immediate)`: 引数を決めたらすぐアプリを前面に出す）、
/// `static var description: IntentDescription?`、`IntentDescription` は Sendable。
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "録音を始める"
    static let description: IntentDescription? = "Minutes で会議の録音を始めます。初めて録音するときは、その前に告知を出します。録音中なら、録音の画面を出します。"
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickRecord.shared.request()
        return .result()
    }
}
