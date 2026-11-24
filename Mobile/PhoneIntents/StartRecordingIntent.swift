import AppIntents
import Foundation

/// 「録音を始める」（SPEC §5.7）。ホーム画面・ロック画面のウィジェット（`RecordWidget` のボタン）、コントロールセンター・ロック画面・
/// アクションボタンのコントロール（`RecordControl`）、Siri・Spotlight・ショートカット（`MinutesPhoneShortcuts`）から使う。
/// アプリを前面に出してから `QuickRecord` に求めを立てる（録音を始めるのはアプリの画面）。Watch の同じ名前の Intent は Mobile/WatchIntents。
/// アプリを開く Intent は、アプリと拡張の両方に入れる（WidgetKit の文書「Open your app with a control」）ので、このフォルダ（PhoneIntents）は
/// iPhone のアプリと MinutesWidgets の両方のターゲットに入る。
/// 確認済み（Xcode 27.2 の iOS 27.2 SDK の AppIntents の swiftinterface）: `openAppWhenRun` は iOS 26.0 で非推奨（"Please provide
/// 'supportedModes' instead"）、`AppIntent.supportedModes: IntentModes` は iOS 26 から、`IntentModes.foreground(.immediate)` は
/// perform() の前にアプリを前面に出す（ビルドの Metadata.appintents には openAppWhenRun: true と書かれる）。
/// シミュレータ（iOS 26.5）で確かめたこと: Spotlight のショートカット、ホーム画面のウィジェットの `Button(intent:)`、コントロールセンターの
/// コントロール、アクションボタンに割り当てたコントロールのどれでも、アプリが前面に出て、perform() はアプリのプロセスで動く（拡張では動かない）。
/// シミュレータでは、チーム ID のない署名（Sign to Run Locally）のアプリだと、Spotlight のショートカットが linkd に断られた
/// （「ショートカットが見つかりません」）。ホーム画面のウィジェットは、この署名のままで動いた（コントロールは、この署名では試していない）。
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "録音を始める"
    static let description: IntentDescription? = "Minutes で会議の録音を始めます。初めて録音するときは、その前に告知を出します。録音中なら、録音の画面を出します。"
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickRecord.shared.request()
        return .result()
    }
}
