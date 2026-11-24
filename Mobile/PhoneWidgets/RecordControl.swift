import AppIntents
import SwiftUI
import WidgetKit

/// コントロール「録音を始める」（SPEC §5.7）。コントロールセンター・ロック画面に置け、アクションボタンにも割り当てられる（iOS 18 から）。
/// 押すと `StartRecordingIntent` がアプリを前面に出し、アプリが録音を始める。録音を止めるボタンにはしない（誤って止めないため。Watch と同じ）。
/// 確認済み（Xcode 27.2 の iOS 27.2 SDK の WidgetKit の swiftinterface）: `StaticControlConfiguration(kind:content:)`・
/// `ControlWidgetButton(action:label:)`（`Action: AppIntent`）・`ControlWidgetConfiguration.displayName(_:)`・`description(_:)`・
/// `ControlWidgetTemplate.tint(_:)`（どれも iOS 18 から）。コントロールの絵は SF Symbols だけ。
/// アプリを開く Intent は、`OpenIntent` でなくても `supportedModes` が前面なら、押すとアプリが開いて Intent はアプリのプロセスで動く
/// （シミュレータの iOS 26.5 で、コントロールセンターと、アクションボタンに割り当てたもの（XCUITest で押した）を確かめた）。
struct RecordControl: ControlWidget {
    static let kind = "jp.pictors.minutes.record-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("録音を始める", systemImage: "record.circle.fill")
            }
            // コントロールセンターの暗い面で読める、ダークの Palette.record
            .tint(WidgetPalette.record(.dark))
        }
        .displayName("録音を始める")
        .description("Minutes を開いて、すぐに会議の録音を始めます。")
    }
}
