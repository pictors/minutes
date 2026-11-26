import MinutesKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// iPhone と Watch の見た目の決まり。Mac のアプリ（Sources/MinutesApp/Views/DesignSystem.swift）と同じ言葉で組む:
// 大きなタイマーの数字（コロンは薄く、1 時間を超えたら秒を小さく）、丸い記号つきのカプセルのボタン、
// 枠線を使わず面の濃さで区切るカード、同じ配色（Palette）と動きの時間（Motion）。system の赤・橙は直接使わない。

// MARK: - 配色

extension Color {
    /// ライト / ダークで値を変える色（0xRRGGBB）。Watch はいつもダーク。
    init(light: UInt32, dark: UInt32) {
        #if os(watchOS)
        self.init(rgb: dark)
        #else
        self.init(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
        #endif
    }

    init(rgb value: UInt32) {
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// 分類色と録音の赤（Mac と同じ値。ダークは鮮やかに、ライトは白地で読める濃さに）。
enum Palette {
    static let periwinkle = Color(light: 0x4F54D9, dark: 0x8C91FA)
    static let vermilion = Color(light: 0xD63F0A, dark: 0xFF5A24)
    static let amber = Color(light: 0xA87400, dark: 0xF7C62F)
    static let cyan = Color(light: 0x0A84A8, dark: 0x33C9EB)
    static let rose = Color(light: 0xCC4466, dark: 0xF79CA6)
    static let mint = Color(light: 0x10874F, dark: 0x34D683)
    static let violet = Color(light: 0x7B45E6, dark: 0xB58DFA)
    static let teal = Color(light: 0x0B7A71, dark: 0x3CC6B4)
    static let record = Color(light: 0xD92D22, dark: 0xFF4A3D)
}

/// 面の色。公開ページ（site/src/site.css の canvas・card）と同じ値。
enum Surface {
    /// 画面の地
    static let page = Color(light: 0xF5F5F7, dark: 0x000000)
    /// カード（地より 1 段だけ違う面。枠線は使わない）
    static let card = Color(light: 0xFFFFFF, dark: 0x131316)
    /// ボタン
    static let raised = Color.primary.opacity(0.09)
    static let pressed = Color.primary.opacity(0.16)
    static let hairline = Color.primary.opacity(0.1)
    /// タブの選んだ面
    static let selectedTab = Color(light: 0xFFFFFF, dark: 0x3A3A40)
}

enum SpeakerPalette {
    static let colors: [Color] = [Palette.periwinkle, Palette.amber, Palette.cyan, Palette.rose, Palette.mint, Palette.violet, Palette.teal]

    static func color(for label: String?) -> Color {
        guard let label else { return .gray }
        if label == "me" { return Palette.vermilion }
        if label.hasPrefix("spk_"), let index = Int(label.dropFirst(4)) { return colors[((index % colors.count) + colors.count) % colors.count] }
        var hash: UInt64 = 5381
        for byte in label.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

// MARK: - ことば・文字

/// ブランドのことば（公開ページの見出しと同じ調子: 短い 2 つの句、句点で終える）。
enum BrandCopy {
    /// 公開ページの最初の見出し
    static let promise = "会議は、\n話すことに集中しよう。"
    static let promiseDetail = "録音するだけ。議事録は、Minutes が書きます。"
}

extension View {
    /// 大きな見出し（公開ページの display: 太く、少し詰める）。
    func brandDisplay(size: CGFloat = 34) -> some View {
        font(.system(size: size, weight: .bold))
            .tracking(-size * 0.012)
            .lineSpacing(size * 0.06)
    }
}

// MARK: - 動き

/// 押下は速く、面の出し入れは smooth、記号の置き換えは snappy。Reduce Motion では移動・拡縮を省いてフェードだけにする。
enum Motion {
    static var press: Animation { .snappy(duration: 0.18) }
    static var layout: Animation { .smooth(duration: 0.35) }
    static var symbol: Animation { .snappy(duration: 0.25) }
    static var follow: Animation { .smooth(duration: 0.3) }
    /// 祝う面（購入のあとのカード）。少し弾んで出る（Reduce Motion では使わず、フェードだけにする）
    static var pop: Animation { .spring(duration: 0.5, bounce: 0.3) }

    /// カードの中身や行。出るときは少し下から浮かぶ。
    static func content(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)), removal: .opacity)
    }
}

// MARK: - カード・チップ

extension View {
    func cardBackground(cornerRadius: CGFloat = 20) -> some View {
        background(Surface.card, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 見出し + 内容のカード。
struct SectionCard<Content: View, Trailing: View>: View {
    let title: String
    let systemImage: String
    var count: Int?
    var tint: Color = .secondary
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                Text(title).font(.headline)
                if let count, count > 0 { CountBadge(count: count) }
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension SectionCard where Trailing == EmptyView {
    init(_ title: String, systemImage: String, count: Int? = nil, tint: Color = .secondary, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, count: count, tint: tint, content: content, trailing: { EmptyView() })
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Surface.raised, in: .capsule)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
    }
}

/// 状態のピル（録音中・送っています・文字起こし中など）。動いている状態は記号が脈打つ。
struct StatusPill: View {
    let text: String
    var tint: Color
    var systemImage: String
    var isBusy = false

    var body: some View {
        Label {
            Text(text).lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .symbolEffect(.pulse, options: .repeating, isActive: isBusy)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: .capsule)
        .foregroundStyle(tint)
    }
}

struct InfoChip: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Surface.raised, in: .capsule)
        .foregroundStyle(.secondary)
    }
}

/// 色付きの角丸タイル（同系色の淡い地に記号）。
struct TintedTile: View {
    let systemImage: String
    var tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// 話者の丸い印（名前の頭文字か、話者の番号）。
struct SpeakerBadge: View {
    let label: String?
    let name: String
    var size: CGFloat = 26

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(SpeakerPalette.color(for: label).gradient, in: .circle)
            .accessibilityHidden(true)
    }

    private var initial: String {
        if name.hasPrefix("話者 "), let number = name.split(separator: " ").last { return String(number) }
        return name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

// MARK: - 数字

/// 経過時間の大きな数字。コロンは薄く、1 時間を超えたら秒を小さく添える。数字は 1 秒ごとに転がる（Reduce Motion では入れ替えるだけ）。
struct BigTimerText: View {
    let seconds: Double
    var size: CGFloat = 64
    var isDimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if hours > 0 {
                digits("\(hours)", total)
                colon
                digits(String(format: "%02d", minutes), total)
                Text(String(format: "%02d", rest))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(total)))
                    .padding(.leading, size * 0.08)
            } else {
                digits("\(minutes)", total)
                colon
                digits(String(format: "%02d", rest), total)
            }
        }
        .kerning(-size * 0.015)
        .opacity(isDimmed ? 0.45 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.4), value: total)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hours > 0 ? "\(hours) 時間 \(minutes) 分 \(rest) 秒" : "\(minutes) 分 \(rest) 秒")
    }

    private func digits(_ text: String, _ total: Int) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText(value: Double(total)))
    }

    private var colon: some View {
        Text(":")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.tertiary)
            .baselineOffset(size * 0.06)
            .padding(.horizontal, size * 0.01)
    }
}

/// 所要時間（2 時間 35 分）。数字を大きく、単位を小さく組む。
struct DurationText: View {
    let seconds: TimeInterval
    var size: CGFloat = 24

    private var parts: [(value: Int, unit: String)] {
        let total = max(0, seconds)
        if total < 60 { return [(Int(total.rounded()), "秒")] }
        let minutes = Int((total / 60).rounded())
        if minutes < 60 { return [(minutes, "分")] }
        let rest = minutes % 60
        return rest == 0 ? [(minutes / 60, "時間")] : [(minutes / 60, "時間"), (rest, "分")]
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Text(verbatim: "\(part.value)")
                    .font(.system(size: size, weight: .bold))
                    .monospacedDigit()
                Text(part.unit)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .padding(.trailing, index < parts.count - 1 ? size * 0.25 : 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ボタン

/// 主操作ボタンの左に置く丸い記号（録音: 赤地に白丸、停止: 反転色の地に角丸の四角、再開: 三角）。
struct PillGlyph: View {
    enum Kind { case record, stop, resume }

    let kind: Kind
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            switch kind {
            case .record:
                Circle().fill(Palette.record)
                Circle().fill(.white).frame(width: size * 0.34, height: size * 0.34)
            case .stop:
                Circle().fill(Color.primary)
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(Surface.page)
                    .frame(width: size * 0.34, height: size * 0.34)
            case .resume:
                Circle().fill(Palette.mint)
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: size * 0.03)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 録音・停止などの主操作（丸い記号 + 文字のカプセル）。押すと少し縮む。
struct PillButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    /// 画面に浮かぶボタン（一覧の「録音」）はガラスの面にする
    var floating = false
    /// 左に丸い記号（PillGlyph）を置くか。置くときは、丸がカプセルの端に沿うように左の余白を詰める。
    /// 文字だけ・SF Symbols と文字のボタンは false にして、左右の余白をそろえる（文字が真ん中に来る）
    var leadingGlyph = true

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, height: height, floating: floating, leadingGlyph: leadingGlyph)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let floating: Bool
        let leadingGlyph: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let label = configuration.label
                .font(.system(size: height * 0.34, weight: .semibold))
                .padding(.leading, height * (leadingGlyph ? 0.2 : 0.44))
                .padding(.trailing, height * (leadingGlyph ? 0.46 : 0.44))
                .frame(height: height)
                .contentShape(.capsule)
            Group {
                #if os(iOS)
                if floating {
                    label.glassEffect(.regular.interactive(), in: .capsule)
                } else {
                    label.background(configuration.isPressed ? Surface.pressed : Surface.raised, in: .capsule)
                }
                #else
                label.background(configuration.isPressed ? Surface.pressed : Surface.raised, in: .capsule)
                #endif
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// 色の面のカプセル（保存・ログインなどの決定）。
struct FilledPillButtonStyle: ButtonStyle {
    var tint: Color = Palette.periwinkle
    var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        FilledBody(configuration: configuration, tint: tint, height: height)
    }

    private struct FilledBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: height * 0.34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(tint.opacity(configuration.isPressed ? 0.8 : 1), in: .capsule)
                .contentShape(.capsule)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// 色を付けない面のカプセル（パスキーでログインなど、決定ほど強くない操作）。幅いっぱい。
struct QuietPillButtonStyle: ButtonStyle {
    var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration, height: height)
    }

    private struct QuietBody: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: height * 0.34, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(configuration.isPressed ? Surface.pressed : Surface.card, in: .capsule)
                .contentShape(.capsule)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// カードの行を押したときの応答（少し縮んで面が濃くなる）。
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

// MARK: - 入力欄・タブ・仮の表示

extension View {
    /// 入力欄の面。押すもの（カプセル）と形で見分けられるように、入力欄は角丸の四角にする。
    /// 地の上では card、カードやシートの上では raised（onCard）。
    func inputField(height: CGFloat = 50, onCard: Bool = false, horizontalPadding: CGFloat = 16) -> some View {
        padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(onCard ? Surface.raised : Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// 面で選択を示すタブ切り替え（Mac の SegmentedTabs と同じ組み。選んだ面が動く。Reduce Motion では入れ替えるだけ）。
/// badge はタブに添える短い印（プランの「2 か月分お得」など。緑の小さなカプセル。選んでいないときも見える）。
struct SegmentedTabs<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    var height: CGFloat = 36
    let title: (Tab) -> String
    var badge: (Tab) -> String? = { _ in nil }
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { selection = tab }
                } label: {
                    HStack(spacing: 6) {
                        Text(title(tab))
                            .font(.subheadline.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .lineLimit(1)
                        if let badge = badge(tab) {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Palette.mint.opacity(0.16), in: .capsule)
                                .foregroundStyle(Palette.mint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height - 6)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: (height - 6) / 2, style: .continuous)
                                .fill(Surface.selectedTab)
                                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Surface.raised, in: .capsule)
    }
}

/// 読み込み中の仮の表示（文字や数字の代わりの薄い面。ゆっくり明滅する。Reduce Motion では明滅しない）。
/// 読めたときと同じ高さにして、中身が入っても下がずれないようにする。
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat = 14
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: min(6, height / 2), style: .continuous)
            .fill(Surface.raised)
            .frame(maxWidth: width ?? .infinity)
            .frame(width: width, height: height)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - 音量の波

/// 録音中の音量の移り変わり（右が今）。棒の並びで、録れていることがひと目で分かるようにする。
struct LevelWaveform: View {
    let levels: [Float]
    var tint: Color = Palette.record
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, Int((proxy.size.width + spacing) / (barWidth + spacing)))
            let shown = Array(levels.suffix(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let offset = index - (count - shown.count)
                    let level = offset >= 0 ? CGFloat(shown[offset]) : 0
                    Capsule()
                        .fill(tint.opacity(0.35 + 0.65 * Double(index) / Double(count)))
                        .frame(width: barWidth, height: max(barWidth, proxy.size.height * min(1, level * 1.15)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
            .animation(.linear(duration: 0.09), value: levels.count)
        }
        .accessibilityHidden(true)
    }
}

/// 録音中の音量を一定の間隔で読み、波の履歴にする（画面が出ているあいだだけ動かす）。
@MainActor
@Observable
final class LevelHistory {
    private(set) var levels: [Float] = []
    private var task: Task<Void, Never>?

    func start(capacity: Int = 96, read: @escaping @MainActor () -> Float?) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                guard let self else { return }
                var next = self.levels
                next.append(read() ?? 0)
                if next.count > capacity { next.removeFirst(next.count - capacity) }
                self.levels = next
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: - 会議の状態

/// 一覧と詳細に出す状態（終わった会議は nil）。
struct MeetingState: Equatable {
    var text: String
    var tint: Color
    var systemImage: String
    var isBusy: Bool
    var isError: Bool
}

extension Formatting {
    static func state(_ item: MeetingItem, recordingClientId: String?) -> MeetingState? {
        let text = status(item, recordingClientId: recordingClientId)
        guard !text.isEmpty else { return nil }
        if item.id == recordingClientId || (item.local.map { !$0.stopped } ?? false) {
            return MeetingState(text: "録音中", tint: Palette.record, systemImage: "record.circle.fill", isBusy: true, isError: false)
        }
        if let local = item.local, !local.completed {
            if local.lastError != nil { return MeetingState(text: text, tint: Palette.rose, systemImage: "exclamationmark.triangle.fill", isBusy: false, isError: true) }
            if !CloudEnvironment.uploadsAllowed { return MeetingState(text: text, tint: .secondary, systemImage: "internaldrive", isBusy: false, isError: false) }
            return MeetingState(text: text, tint: Palette.periwinkle, systemImage: "arrow.up.circle.fill", isBusy: true, isError: false)
        }
        switch item.server?.status {
        case "uploading": return MeetingState(text: text, tint: Palette.periwinkle, systemImage: "arrow.up.circle.fill", isBusy: true, isError: false)
        case "queued", "transcribing": return MeetingState(text: text, tint: Palette.amber, systemImage: "waveform", isBusy: true, isError: false)
        case "summarizing": return MeetingState(text: text, tint: Palette.violet, systemImage: "sparkles", isBusy: true, isError: false)
        case "failed": return MeetingState(text: text, tint: Palette.rose, systemImage: "exclamationmark.triangle.fill", isBusy: false, isError: true)
        case "done": return MeetingState(text: text, tint: Palette.amber, systemImage: "exclamationmark.circle", isBusy: false, isError: false)
        case nil:
            return item.local?.lastError != nil
                ? MeetingState(text: text, tint: Palette.rose, systemImage: "exclamationmark.triangle.fill", isBusy: false, isError: true)
                : MeetingState(text: text, tint: Palette.amber, systemImage: "hourglass", isBusy: true, isError: false)
        default: return nil
        }
    }

    /// 今日 / 昨日 / 9月15日(月)
    static func dayTitle(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今日" }
        if calendar.isDateInYesterday(date) { return "昨日" }
        let ja = Locale(identifier: "ja_JP")
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = sameYear ? Date.FormatStyle(locale: ja).month().day().weekday(.abbreviated) : Date.FormatStyle(locale: ja).year().month().day().weekday(.abbreviated)
        return date.formatted(style)
    }

    /// 14:05
    static func timeOfDay(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Locale(identifier: "ja_JP")).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}
