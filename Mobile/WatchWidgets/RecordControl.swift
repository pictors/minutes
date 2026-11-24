import AppIntents
import SwiftUI
import WidgetKit

/// コントロールセンターのコントロール「Minutes で録音」（SPEC §5.7）。Ultra のアクションボタンにも割り当てられる。
/// 押すと `StartRecordingIntent` がアプリを前面に出し、アプリが録音を始める。録音を止めるボタンにはしない（誤って止めないため）。
/// 確認済み（Xcode 27.2 の watchOS 27.2 SDK の WidgetKit の swiftinterface）: `StaticControlConfiguration(kind:content:)`・
/// `ControlWidgetButton(action:label:)`・`ControlWidgetConfiguration.displayName(_:)`・`description(_:)`・
/// `ControlWidgetTemplate.tint(_:)`（どれも watchOS 26 から）。コントロールの絵は SF Symbols だけ。
struct RecordControl: ControlWidget {
    static let kind = "jp.pictors.minutes.watch.record-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("録音", systemImage: "record.circle.fill")
            }
            .tint(WidgetPalette.record)
        }
        .displayName("Minutes で録音")
        .description("会議の録音を始めます。")
    }
}
