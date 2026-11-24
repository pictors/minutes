import AppIntents
import SwiftUI
import WidgetKit

/// ウィジェット「録音を始める」（SPEC §5.7）: ホーム画面（小）と、ロック画面（円・長方形）。
/// ボタンは `StartRecordingIntent` を動かし、アプリが前面に出て録音を始める。ボタンが Intent を動かさないとき（ロック画面）は、
/// `widgetURL` で同じ求めを渡す（アプリの `onOpenURL` → `QuickRecord`）。中身は変わらないので、タイムラインは 1 つの項目だけで、更新しない。
/// 見た目（ホーム画面。2026-11-25 に 4 案から選んだ「白いカード」）: iOS の標準のウィジェットと同じ白いカード（ダークでは暗い面）に、
/// 左上にマーク（青紫）、右上に赤い録音のボタン（アプリの「録音」のボタン PillGlyph の .record と同じ、赤い円に白い点）、
/// 下に「録音を始める」と「押すと、すぐに録音」。色を絞った表示（色合い・透明のホーム画面）でも同じ並びのまま、地は system に任せ、
/// マークとボタンに色合いを付ける（ボタンは輪と点の形にする。赤い円と白い点は、1 色にすると点が消える）。
/// 確認済み（Xcode 27.2 の iOS 27.2 SDK の _AppIntents_SwiftUI・WidgetKit・SwiftUI の swiftinterface）: `Button(intent:label:)`（iOS 17 から）、
/// `View.widgetURL(_:)`（iOS 14 から）、`AccessoryWidgetBackground`・`widgetAccentable(_:)`・`EnvironmentValues.widgetRenderingMode`
/// （iOS 16 から）、`containerBackground(for:alignment:content:)`（iOS 17 から）、`WidgetFamily.accessoryRectangular`（iOS 16 から）。
/// シミュレータ（iOS 26.5）で確かめたこと: ホーム画面では `Button(intent:)` を押すと、アプリが前面に出て、Intent はアプリのプロセスで動く。
/// ロック画面の円を押すと、Intent は動かず、アプリが `widgetURL` で開いた（`widgetURL` がないと、アプリが開くだけで録音は始まらない）。
/// ロック画面の長方形も、押すと `widgetURL` でアプリが開いて録音が始まった。
struct RecordWidget: Widget {
    static let kind = "jp.pictors.minutes.record"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider()) { _ in
            RecordWidgetView()
                .widgetURL(QuickRecord.url)
        }
        .configurationDisplayName("録音を始める")
        .description("押すと Minutes が開き、すぐに会議の録音を始めます。")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
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

private struct RecordWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(intent: StartRecordingIntent()) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Minutes で録音を始める")
        .containerBackground(for: .widget) {
            if family == .systemSmall {
                // iOS の標準のウィジェットと同じ面（ダークでは暗い面）。色を絞った表示では system が地を描く
                colorScheme == .dark ? Color(rgb: 0x1C1C1E) : Color.white
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                RecordRing()
                    .padding(13)
            }
        case .accessoryRectangular:
            HStack(spacing: 10) {
                RecordRing()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("録音を始める")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Minutes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        default:
            SmallContent()
        }
    }
}

/// ホーム画面（小）: 左上にマーク、右上に録音のボタン、下に「録音を始める」と「押すと、すぐに録音」。
private struct SmallContent: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                BrandMark(height: 17, color: colorScheme == .dark ? Color(rgb: 0x8C91FA) : Color(rgb: 0x4F54D9))
                    .widgetAccentable()
                    .padding(.top, 3)
                Spacer(minLength: 0)
                Group {
                    if renderingMode == .fullColor {
                        RecordButtonArt()
                    } else {
                        RecordRing()
                            .padding(4)
                    }
                }
                .frame(width: 54, height: 54)
            }
            Spacer(minLength: 0)
            Text("録音を始める")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("押すと、すぐに録音")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// マーク（Mobile/Brand/BrandGeometry.swift の輪郭）。拡張には Palette がないので、色は呼ぶ側で渡す。
private struct BrandMark: View {
    var height: CGFloat
    var color: Color

    var body: some View {
        BrandShape(part: .mark)
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: height * BrandLogo.markBounds.width / BrandLogo.markBounds.height, height: height)
            .accessibilityHidden(true)
    }
}

/// 録音のボタン（フルカラー）: 赤い円に白い点（アプリの「録音」のボタン PillGlyph の .record と同じ記号）に、淡い赤の光を添える。
private struct RecordButtonArt: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let disc = size * 0.8
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(rgb: 0xFF6656), Color(rgb: 0xD92D22)], startPoint: .top, endPoint: .bottom))
                    .frame(width: disc, height: disc)
                    .shadow(color: Color(rgb: 0xE0352A).opacity(0.35), radius: size * 0.16, y: size * 0.05)
                Circle()
                    .fill(.white)
                    .frame(width: disc * 0.34, height: disc * 0.34)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// 色を絞った表示の録音の記号: 輪と点（SF Symbols の record.circle の形）。色合いを付ける（widgetAccentable）。
private struct RecordRing: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .strokeBorder(lineWidth: max(2, size * 0.085))
                Circle()
                    .frame(width: size * 0.5, height: size * 0.5)
            }
            .widgetAccentable()
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
