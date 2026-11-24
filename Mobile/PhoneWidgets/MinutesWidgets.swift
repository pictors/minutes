import SwiftUI
import WidgetKit

/// iPhone の拡張（MinutesWidgets）: 録音をすぐ始める入口（SPEC §5.7）。
/// - ホーム画面（小）・ロック画面（円・長方形）のウィジェット: `RecordWidget`
/// - コントロールセンター・ロック画面・アクションボタンのコントロール: `RecordControl`
/// どちらも状態を持たない（App Group も使わない）。押すと `StartRecordingIntent` がアプリを前面に出し、アプリが録音を始める（`QuickRecord`）。
/// 拡張には Mobile/Shared を入れない（MinutesKit・録音・UploadEngine の裏の送信を、別のプロセスに持ち込まないため）。
/// 確認済み（Xcode 27.2 の iOS 27.2 SDK の SwiftUI・WidgetKit の swiftinterface）: `WidgetBundle`（iOS 14 から）、
/// `ControlWidget`（iOS 18 から。`WidgetBundleBuilder` が受ける）。
@main
struct MinutesWidgets: WidgetBundle {
    var body: some Widget {
        RecordWidget()
        RecordControl()
    }
}

/// 拡張で使う色（Mobile/Shared/DesignSystem.swift の Palette と同じ値。system の赤は使わない）。
/// ウィジェットのカード・マーク・ボタンの色は RecordWidget に置く。拡張には Mobile/Shared を入れず、ロゴの輪郭だけを Mobile/Brand から共有する。
enum WidgetPalette {
    /// Palette.record
    static func record(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(rgb: 0xFF4A3D) : Color(rgb: 0xD92D22)
    }
}

extension Color {
    /// 0xRRGGBB（拡張の中だけ。アプリの同じものは Mobile/Shared/DesignSystem.swift）
    init(rgb value: UInt32) {
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
