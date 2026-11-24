import SwiftUI
import WidgetKit

/// Watch の拡張（MinutesWatchWidgets）: 録音をすぐ始める入口（SPEC §5.7）。
/// - 文字盤のコンプリケーション（Smart Stack にも置ける）: `RecordComplication`
/// - コントロールセンターのコントロール（Ultra のアクションボタンにも割り当てられる）: `RecordControl`
/// どちらも状態を持たない（App Group も使わない）。押すとアプリを前面に出し、アプリが録音を始める（`QuickRecord`）。
/// 拡張には Mobile/Shared を入れない（UploadEngine の裏の送信の識別子などを、別のプロセスに持ち込まないため）。
/// コントロールをコントロールセンター・アクションボタン（Ultra）・Smart Stack に置けるのは watchOS 26 から（Apple の「What's new in watchOS 26」）。
/// コンプリケーションの長方形は Smart Stack にも出る（WidgetKit の文書「Creating accessory widgets and watch complications」）。
/// 確認済み（Xcode 27.2 の watchOS 27.2 SDK の SwiftUI の swiftinterface）: `ControlWidget` は watchOS 26 から、
/// `WidgetBundleBuilder.buildExpression(_:)` は `ControlWidget` を受ける（watchOS 26 から）。
@main
struct MinutesWatchWidgets: WidgetBundle {
    var body: some Widget {
        RecordComplication()
        RecordControl()
    }
}

/// 拡張で使う色（Mobile/Shared の Palette・Surface の、Watch で使うダークの値と同じ。system の赤は使わない）。
enum WidgetPalette {
    /// Palette.record
    static let record = Color(.sRGB, red: 0xFF / 255, green: 0x4A / 255, blue: 0x3D / 255)
    /// Surface.card
    static let card = Color(.sRGB, red: 0x13 / 255, green: 0x13 / 255, blue: 0x16 / 255)
}
