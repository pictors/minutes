import SwiftUI
import WidgetKit

/// 文字盤のコンプリケーション「録音」（SPEC §5.7）。押すとアプリが開き、録音を始める（`widgetURL` → アプリの `onOpenURL` → `QuickRecord`）。
/// 中身は変わらないので、タイムラインは 1 つの項目だけで、更新しない。
/// 確認済み（Xcode 27.2 の watchOS 27.2 SDK の WidgetKit・SwiftUI の swiftinterface）: `View.widgetURL(_:)`（watchOS 9 から）、
/// `AccessoryWidgetBackground`・`widgetAccentable(_:)`・`widgetLabel(_:)`（watchOS 9 から）、`WidgetFamily.accessoryCorner`、
/// `containerBackground(for:alignment:content:)`（watchOS 10 から）。
struct RecordComplication: Widget {
    static let kind = "jp.pictors.minutes.watch.record"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider()) { _ in
            RecordComplicationView()
                .widgetURL(QuickRecord.url)
                .containerBackground(for: .widget) { WidgetPalette.card }
        }
        .configurationDisplayName("録音")
        .description("押すと Minutes で会議の録音を始めます。")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }

    struct Entry: TimelineEntry {
        let date: Date
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry(date: Date())
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(Entry(date: Date()))
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry(date: Date())], policy: .never))
        }
    }
}

private struct RecordComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: "record.circle.fill")
                .font(.title2)
                .foregroundStyle(WidgetPalette.record)
                .widgetAccentable()
                .widgetLabel("録音")
                .accessibilityLabel("Minutes で録音を始める")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                RecordGlyph()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Minutes")
                        .font(.headline)
                        .widgetAccentable()
                    Text("押して録音を始める")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Minutes で録音を始める")
        case .accessoryInline:
            Label("Minutes で録音", systemImage: "record.circle.fill")
        default:
            ZStack {
                AccessoryWidgetBackground()
                RecordGlyph()
                    .padding(9)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Minutes で録音を始める")
        }
    }
}

/// アプリの「録音」のボタンと同じ記号（赤い丸に白い点。Mobile/Shared の PillGlyph の .record）。
/// 色を絞った文字盤では、丸が文字盤の色になり、点は白のまま残る。
private struct RecordGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(WidgetPalette.record)
                    .widgetAccentable()
                Circle()
                    .fill(.white)
                    .frame(width: size * 0.34, height: size * 0.34)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
