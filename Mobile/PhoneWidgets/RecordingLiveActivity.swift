import ActivityKit
import SwiftUI
import WidgetKit

/// 録音中の Live Activity（SPEC §5.7）: ロック画面の帯と、ダイナミックアイランド。
/// 録れていること（赤い録音の印と「録音中」）と経過時間を出す。止まっているあいだ（電話・Siri）は琥珀色の印と「止まっています」にして、時間は進めない。
/// 止めるボタンは置かない（誤って止めないため。コントロール・Watch と同じ）。押すとアプリが開き、録音の画面で止める。
/// 会議の名前は出さない（ロック画面に出るので）。色は Mobile/Shared/DesignSystem.swift の Palette のダークの値（拡張には Shared を入れない）。
/// 確認済み（Xcode 27.2 の iOS 27.2 SDK の WidgetKit・SwiftUI の swiftinterface）: `ActivityConfiguration(for:content:dynamicIsland:)`・
/// `DynamicIsland(expanded:compactLeading:compactTrailing:minimal:)`・`DynamicIslandExpandedRegion`・`keylineTint(_:)`・
/// `activityBackgroundTint(_:)`・`activitySystemActionForegroundColor(_:)`・`Text(timerInterval:countsDown:)`。
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(rgb: 0x131316))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        ActivityMark(height: 16)
                        Text("Minutes").font(.subheadline.weight(.semibold))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: state)
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: 96, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        StatusLabel(state: state)
                        Spacer(minLength: 8)
                        Text("押すと Minutes を開きます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                StatusSymbol(state: state)
            } compactTrailing: {
                ElapsedText(state: state)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: 52, alignment: .trailing)
            } minimal: {
                StatusSymbol(state: state)
            }
            .keylineTint(ActivityColor.tint(state))
        }
    }
}

private enum ActivityColor {
    /// Palette.record・amber・periwinkle のダークの値（Live Activity の地はいつも暗い）
    static let record = Color(rgb: 0xFF4A3D)
    static let amber = Color(rgb: 0xF7C62F)
    static let periwinkle = Color(rgb: 0x8C91FA)

    static func tint(_ state: RecordingActivityAttributes.ContentState) -> Color {
        state.isRecording ? record : amber
    }
}

/// ロック画面の帯: 左にマークと状態、右に大きな経過時間（アプリの録音の画面と同じく、数字を主役にする）。
private struct LockScreenView: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            ActivityMark(height: 26)
            VStack(alignment: .leading, spacing: 3) {
                StatusLabel(state: state)
                Text("Minutes")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 8)
            ElapsedText(state: state)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(state.isRecording ? 1 : 0.5))
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}

/// 経過時間。録音しているあいだは system が 1 秒ごとに進める（アプリが裏にいても進む）。止まっているあいだは、止まった時点の時間。
private struct ElapsedText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isRecording, let start = state.timerStart {
                Text(timerInterval: start...start.addingTimeInterval(24 * 3600), countsDown: false)
            } else {
                Text(Self.clock(state.elapsed))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// 12:34 か 1:02:03（アプリの Formatting.clock と同じ）
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct StatusSymbol: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.isRecording ? "record.circle.fill" : "pause.circle.fill")
            .foregroundStyle(ActivityColor.tint(state))
            .accessibilityLabel(state.isRecording ? "録音中" : "録音が止まっています")
    }
}

private struct StatusLabel: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            StatusSymbol(state: state)
            Text(state.isRecording ? "録音中" : "止まっています")
        }
        .font(.headline)
        .foregroundStyle(ActivityColor.tint(state))
    }
}

private struct ActivityMark: View {
    let height: CGFloat

    var body: some View {
        BrandShape(part: .mark)
            .fill(ActivityColor.periwinkle, style: FillStyle(eoFill: true))
            .frame(width: height * BrandLogo.markBounds.width / BrandLogo.markBounds.height, height: height)
            .accessibilityHidden(true)
    }
}
