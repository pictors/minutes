import AppKit
import MinutesCore
import SwiftUI

// MARK: - 状態・種別の表示（記号・色・文言を 1 か所にまとめる）

extension SessionState {
    var title: String {
        switch self {
        case .idle: "待機中"
        case .armed: "録音準備中"
        case .recording: "録音中"
        case .finalizing: "録音終了待ち"
        case .done: "完了"
        case .failed: "失敗"
        }
    }

    var detail: String {
        switch self {
        case .idle: "メニューバーまたはツールバーから録音を開始できます"
        case .armed: "会議アプリの音声を検知したら自動で録音を開始します"
        case .recording: "会議アプリと自分の声を録音しています"
        case .finalizing: "録音の終了を待っています。終了後は次の録音を開始できます"
        case .done: "議事録ができました"
        case .failed: "録音または後処理に失敗しました"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "waveform"
        case .armed: "waveform.badge.magnifyingglass"
        case .recording: "record.circle.fill"
        case .finalizing: "hourglass"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .idle: .secondary
        case .armed: Palette.amber
        case .recording: Palette.record
        case .finalizing: Palette.periwinkle
        case .done: Palette.mint
        case .failed: Palette.record
        }
    }
}

extension MeetingStatus {
    var title: String {
        switch self {
        case .recording: "録音中"
        case .finalizing: "処理中"
        case .done: "完了"
        case .failed: "失敗"
        }
    }

    var symbol: String {
        switch self {
        case .recording: "record.circle.fill"
        case .finalizing: "hourglass"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .recording: Palette.record
        case .finalizing: Palette.amber
        case .done: Palette.mint
        case .failed: Palette.record
        }
    }
}

extension MeetingPlatform {
    var title: String {
        switch self {
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .other: "会議"
        }
    }

    var symbol: String {
        switch self {
        case .meet: "video.fill"
        case .teams: "person.2.fill"
        case .other: "waveform"
        }
    }

    var tint: Color {
        switch self {
        case .meet: Palette.mint
        case .teams: Palette.violet
        case .other: Palette.periwinkle
        }
    }
}

extension PrivacyMode {
    var title: String {
        switch self {
        case .cloudOk: "クラウド OK"
        case .localOnly: "ローカルのみ"
        }
    }

    var symbol: String {
        switch self {
        case .cloudOk: "icloud"
        case .localOnly: "lock.fill"
        }
    }
}

extension MinutesSummary.ActionKind {
    var title: String {
        switch self {
        case .ownCommitment: "自分のタスク"
        case .theirTask: "相手のタスク"
        case .delegable: "委任できる"
        }
    }

    var tint: Color {
        switch self {
        case .ownCommitment: .accentColor
        case .theirTask: .secondary
        case .delegable: Palette.violet
        }
    }
}

// MARK: - プロバイダの表示名と API キーの状態

enum ProviderCatalog {
    struct Entry: Identifiable, Hashable {
        let id: String
        let title: String
        let shortTitle: String
        let detail: String
        let keyName: String?
    }

    static let finalProviders: [Entry] = [
        Entry(id: "elevenlabs.scribe_v2", title: "ElevenLabs Scribe v2", shortTitle: "Scribe v2", detail: "既定。話者分離込みで最も自然な日本語", keyName: APIKeys.elevenLabs),
        Entry(id: "openai.gpt-4o-transcribe-diarize", title: "OpenAI gpt-4o-transcribe-diarize", shortTitle: "gpt-4o", detail: "処理が遅く発話を落とすことがある", keyName: APIKeys.openAI),
        Entry(id: "local.speechanalyzer+fluidaudio", title: "ローカル（SpeechAnalyzer + FluidAudio）", shortTitle: "ローカル", detail: "端末内で処理。クラウド失敗時のフォールバックにも使う", keyName: nil),
    ]

    static func final(_ id: String) -> Entry? { finalProviders.first { $0.id == id } }
    static func finalTitle(_ id: String) -> String { final(id)?.title ?? id }
    static func finalShortTitle(_ id: String) -> String { final(id)?.shortTitle ?? id }

    /// pipeline_runs の provider（"system: elevenlabs.scribe_v2; mic: local.…" 等）を短い表示名にする。
    static func summarizeRunProvider(_ raw: String) -> String {
        let names = finalProviders.filter { raw.contains($0.id) }.map(\.shortTitle)
        if names.isEmpty { return raw }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique.joined(separator: " + ")
    }

    /// notes.model（"codex/gpt-6-astra / prompt v2" 等）からプロンプト版を落とす。
    static func summarizeModel(_ raw: String) -> String {
        raw.components(separatedBy: " / prompt").first ?? raw
    }
}

enum KeyStatus: Equatable {
    case keychain, environment, missing

    static func resolve(_ name: String) -> KeyStatus {
        if let stored = try? KeychainStore.get(account: name), !stored.isEmpty { return .keychain }
        if DotEnv.value(for: name) != nil { return .environment }
        return .missing
    }

    var title: String {
        switch self {
        case .keychain: "Keychain に保存済み"
        case .environment: ".env / 環境変数から取得"
        case .missing: "未設定"
        }
    }

    var symbol: String {
        switch self {
        case .keychain: "checkmark.circle.fill"
        case .environment: "checkmark.circle"
        case .missing: "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .keychain, .environment: Palette.mint
        case .missing: .secondary
        }
    }

    var isAvailable: Bool { self != .missing }
}

// MARK: - 書式

enum Formatting {
    static let ja = Locale(identifier: "ja_JP")

    /// 45 分 / 1 時間 12 分
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "1 分未満" }
        if minutes < 60 { return "\(minutes) 分" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60) 時間" : "\(minutes / 60) 時間 \(remainder) 分"
    }

    /// 10:00 – 10:45（終了がなければ 10:00 –）
    static func timeRange(_ start: Date, _ end: Date?) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: ja)
        guard let end else { return start.formatted(style) + " –" }
        return start.formatted(style) + " – " + end.formatted(style)
    }

    /// 2026年9月17日（木）10:00 – 10:45 · 45 分
    static func dateLine(_ start: Date, _ end: Date?) -> String {
        var line = start.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: ja).weekday(.short)) + " " + timeRange(start, end)
        if let end { line += " · " + duration(end.timeIntervalSince(start)) }
        return line
    }

    /// 今日 / 昨日 / 9月15日（月）/ 2025年12月1日（月）
    static func dayTitle(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今日" }
        if calendar.isDateInYesterday(date) { return "昨日" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = sameYear
            ? Date.FormatStyle(locale: ja).month().day().weekday(.short)
            : Date.FormatStyle(locale: ja).year().month().day().weekday(.short)
        return date.formatted(style)
    }
}

// MARK: - カード・チップ・バッジ

extension View {
    /// 詳細ビューのセクションや設定内カードの共通背景。
    func cardBackground(cornerRadius: CGFloat = 16) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

/// 枠線を使わず、背景より 1 段明るい（ライトでは濃い）面で区切る。
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Surface.card, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 見出し + 内容のカード。件数バッジと右上の操作を任意で持てる。
struct SectionCard<Content: View, Trailing: View>: View {
    let title: String
    let systemImage: String
    var count: Int?
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    init(_ title: String, systemImage: String, count: Int? = nil, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
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
    init(_ title: String, systemImage: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, systemImage: systemImage, count: count, content: content, trailing: { EmptyView() })
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
            .background(.fill.tertiary, in: .capsule)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
    }
}

/// 状態のピル（会議リスト・詳細）。
struct StatusPill: View {
    let status: MeetingStatus
    var titleOverride: String?
    var tintOverride: Color?
    var symbolOverride: String?

    var body: some View {
        let tint = tintOverride ?? status.tint
        let symbol = symbolOverride ?? status.symbol
        Label {
            Text(titleOverride ?? status.title)
        } icon: {
            // 録音中の点滅は `AnimatedSymbol` で描く
            if status == .recording && titleOverride == nil {
                AnimatedSymbol(systemName: symbol, pointSize: NSFont.TextStyle.caption1.pointSize, weight: .medium, color: tint, effect: .pulse)
            } else {
                Image(systemName: symbol)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: .capsule)
        .foregroundStyle(tint)
    }
}

/// 情報チップ（プロバイダ名・種別など）。
struct InfoChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.fill.tertiary, in: .capsule)
        .foregroundStyle(tint)
    }
}

/// 名前の頭文字を使った丸アバター。
struct AvatarView: View {
    let name: String
    var size: CGFloat = 22

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(AvatarView.color(for: name).gradient, in: .circle)
    }

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        if first.isLetter, first.isASCII {
            let parts = trimmed.split(separator: " ")
            let letters = parts.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
            return letters.joined()
        }
        return String(first)
    }

    static func color(for name: String) -> Color {
        let palette: [Color] = [.blue, .teal, .indigo, .purple, .pink, .orange, .mint, .cyan]
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// 会議のアイコン。記号は会議アプリ（Meet / Teams / その他）、色は会議シリーズ（`Palette.color(for:)`）か会議アプリ。
struct PlatformIcon: View {
    let platform: MeetingPlatform?
    var size: CGFloat = 32
    var isLive = false
    var tint: Color?

    var body: some View {
        let platform = platform ?? .other
        TintedTile(
            systemImage: isLive ? "record.circle.fill" : platform.symbol,
            tint: isLive ? Palette.record : (tint ?? platform.tint),
            size: size,
            pulse: isLive
        )
    }
}

/// 参加者チップ。
struct AttendeeChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            AvatarView(name: name, size: 18)
            Text(name).font(.callout).lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background(.fill.tertiary, in: .capsule)
    }
}

/// 音量メーター（dB → 0…1）。
/// 1 秒に何度も変わる音量を、SwiftUI の状態を通さずに AppKit の view（メーターと dB の数字）へ渡す。
/// SwiftUI の状態を変えると、そのたびにウィンドウ全体のレイアウトをやり直す。録音画面で 1 秒 5 回の更新が main スレッドを 18% 使っていた（G7）。
@MainActor final class LevelFeed {
    private(set) var db: Float = -.infinity
    fileprivate weak var meter: LevelMeterLayerView?
    fileprivate weak var readout: LevelReadoutField?

    func send(_ db: Float) {
        guard db != self.db else { return }
        self.db = db
        meter?.setLevel(LevelFeed.level(db), animated: true)
        readout?.show(db)
    }

    /// -60 dB を 0、0 dB を 1 とする。
    fileprivate static func level(_ db: Float) -> Double {
        guard db.isFinite else { return 0 }
        return max(0, min(1, (Double(db) + 60) / 60))
    }
}

/// 音量メーター。値は 1 秒に 5 回変わり、0.35 秒かけて追う。値は `LevelFeed` から直接受け取り、追う動きは Core Animation に任せる
/// （SwiftUI の `.animation` で追うと、ほぼ常に動いているのでフレームごとの描き直しが main スレッドで続く。G7）。
struct LevelMeter: View {
    let feed: LevelFeed
    var tint: Color = .accentColor

    var body: some View {
        LevelMeterBar(feed: feed, tint: NSColor(tint))
            .frame(height: 6)
    }
}

private struct LevelMeterBar: NSViewRepresentable {
    let feed: LevelFeed
    let tint: NSColor

    func makeNSView(context: Context) -> LevelMeterLayerView { LevelMeterLayerView() }

    func updateNSView(_ view: LevelMeterLayerView, context: Context) {
        view.tint = tint
        if feed.meter !== view {
            feed.meter = view
            view.setLevel(LevelFeed.level(feed.db), animated: false)
        }
    }
}

/// メーターの見出し（名前と dB の数字）。数字は `LevelFeed` から直接書き換える。
/// 元の `HStack(spacing: 4) { Text(名前); Text(数字) }` と同じく右にそろえて並べるが、数字が変わっても SwiftUI のレイアウトはやり直さない
/// （大きさは「-120 dB」が入る幅で固定し、数字が短いときは右へ寄せる）。
struct LevelReadout: NSViewRepresentable {
    let title: String
    let feed: LevelFeed

    func makeNSView(context: Context) -> LevelReadoutField { LevelReadoutField() }

    func updateNSView(_ view: LevelReadoutField, context: Context) {
        view.title = title
        if feed.readout !== view {
            feed.readout = view
            view.show(feed.db)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LevelReadoutField, context: Context) -> CGSize? {
        LevelReadoutField.size(title: title)
    }
}

final class LevelReadoutField: NSTextField {
    var title = "" {
        didSet { if title != oldValue { render() } }
    }

    private var db: Float = -.infinity

    convenience init() {
        self.init(labelWithString: "")
        lineBreakMode = .byClipping
        setAccessibilityElement(false)
        // 既定のラベルは横に伸びる（SwiftUI が余った幅を渡す）。大きさを固定する
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: orientation)
            setContentCompressionResistancePriority(.required, for: orientation)
        }
    }

    override var intrinsicContentSize: NSSize { Self.size(title: title) }

    /// 数字を替えても大きさは変わらない。親（SwiftUI）にレイアウトのやり直しを頼まない
    override func invalidateIntrinsicContentSize() {}

    func show(_ db: Float) {
        self.db = db
        render()
    }

    private func render() {
        attributedStringValue = Self.text(title: title, value: db.isFinite ? "\(Int(db)) dB" : "–")
    }

    /// 名前（caption2・secondary）と数字（caption2 の等幅数字・tertiary）を 4pt 空けて並べ、右にそろえる。
    private static func text(title: String, value: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byClipping
        let size = NSFont.TextStyle.caption2.pointSize
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
        if text.length > 0 { text.addAttribute(.kern, value: 4, range: NSRange(location: text.length - 1, length: 1)) }
        text.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
        ]))
        return text
    }

    /// 「-120 dB」が入る大きさ。数字が変わっても変えない。
    static func size(title: String) -> NSSize {
        measuring.attributedStringValue = text(title: title, value: "-120 dB")
        let size = measuring.cell?.cellSize ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private static let measuring = NSTextField(labelWithString: "")
}

/// 地のカプセルと、色の付いたカプセル（`tint.gradient` と同じく上を少し明るく）。
final class LevelMeterLayerView: NSView {
    private let track = CALayer()
    private let fill = CAGradientLayer()
    private var level: Double = 0

    var tint: NSColor = .controlAccentColor {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    /// 色はここで当てる（描画中は外観が effectiveAppearance になるので、動的な色がライト / ダークに合う）。
    override func updateLayer() {
        track.backgroundColor = NSColor.tertiarySystemFill.cgColor
        let base = tint.usingColorSpace(.sRGB) ?? tint
        fill.colors = [(base.blended(withFraction: 0.18, of: .white) ?? base).cgColor, base.cgColor]
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    func setLevel(_ value: Double, animated: Bool) {
        guard value != level else { return }
        level = value
        place(animated: animated)
    }

    private func place(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        let radius = bounds.height / 2
        track.frame = bounds
        track.cornerRadius = radius
        fill.frame = CGRect(x: 0, y: 0, width: max(4, bounds.width * level), height: bounds.height)
        fill.cornerRadius = radius
        CATransaction.commit()
    }
}

/// 上部に出す注意・エラーバナー。右端に操作（再試行など）を 1 つ置ける。
struct Banner: View {
    enum Kind { case error, warning, info }

    let kind: Kind
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    init(kind: Kind, text: String, actionTitle: String? = nil, action: (() -> Void)? = nil, secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil) {
        self.kind = kind
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label {
                Text(text).textSelection(.enabled)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .controlSize(.small)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.13), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var symbol: String {
        switch kind {
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .error: Palette.record
        case .warning: Palette.amber
        case .info: Palette.periwinkle
        }
    }
}

/// ホバー時にうっすら背景を付ける（行の操作対象を示す）。`isActive` の間（行から出したポップオーバーの表示中など）も付けたままにする。
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 8
    var isActive = false
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovered || isActive ? Surface.hover : .clear)
                    .animation(.easeOut(duration: 0.12), value: isActive)
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 8, isActive: Bool = false) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isActive: isActive))
    }

    /// `List` の見出しの下線を消す（見出しのビューに付ける）。macOS 26 はスクロール上端に貼り付いた見出しに AppKit が全幅の区切り線を引き、
    /// List が左右をインセットして引く下線と同じ位置で重なる（先頭の見出しは一番上で常に貼り付いているので、そこが二重線に見える）。
    func listHeaderSeparatorHidden() -> some View {
        listRowSeparator(.hidden, edges: .bottom)
    }
}

/// 折り返すチップ配置。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width.map { $0.isFinite ? $0 : .infinity } ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            let (size, _) = fit(subview, maxWidth: maxWidth)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        let proposed = proposal.width ?? width
        return CGSize(width: proposed.isFinite ? proposed : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let (size, fitted) = fit(subview, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: fitted)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// 子は本来の大きさで並べる。1 行に収まらない子（長い名前のチップなど）だけ行幅を提案して縮め、枠からはみ出さないようにする。
    private func fit(_ subview: LayoutSubview, maxWidth: CGFloat) -> (CGSize, ProposedViewSize) {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return (ideal, .unspecified) }
        let fitted = ProposedViewSize(width: maxWidth, height: nil)
        return (subview.sizeThatFits(fitted), fitted)
    }
}

/// 話者ごとの色。自分（mic）は朱色、クラスタは出現順（spk_0, spk_1, …）で隣り合う色が離れるように割り当てる。
enum SpeakerPalette {
    static let colors: [Color] = [Palette.periwinkle, Palette.amber, Palette.cyan, Palette.rose, Palette.mint, Palette.violet, Palette.teal]
    static let me = Palette.vermilion

    static func color(for label: String?) -> Color {
        guard let label else { return .gray }
        if label == TrackMerger.micSpeakerLabel { return me }
        if label.hasPrefix("spk_"), let index = Int(label.dropFirst(4)) { return color(index: index) }
        var hash: UInt64 = 5381
        for byte in label.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return colors[Int(hash % UInt64(colors.count))]
    }

    static func color(index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// 話者の表示名。未割当のクラスタは "spk_0" ではなく「話者 1」と出す。
enum SpeakerNaming {
    static func title(for speaker: SpeakerRecord?, clusterLabel: String?, selfName: String) -> String {
        if let name = speaker?.displayName, !name.isEmpty { return name }
        let label = speaker?.clusterLabel ?? clusterLabel
        guard let label else { return "?" }
        if label == TrackMerger.micSpeakerLabel { return selfName }
        if label.hasPrefix("spk_"), let index = Int(label.dropFirst(4)) { return "話者 \(index + 1)" }
        if label.hasPrefix("manual_") { return "（名前なし）" }
        if label.hasPrefix("c"), let underscore = label.firstIndex(of: "_") { return "話者 \(label[label.index(after: underscore)...])" }
        return label
    }
}

extension Formatting {
    /// 期限（YYYY-MM-DD）を「今日 / 明日 / 9月20日（土）」と、超過なら「期限超過」の印で返す。
    static func due(_ raw: String, now: Date = Date()) -> (text: String, overdue: Bool) {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: raw) else { return (raw, false) }
        let calendar = Calendar.current
        let overdue = calendar.startOfDay(for: date) < calendar.startOfDay(for: now)
        if calendar.isDateInToday(date) { return ("今日", false) }
        if calendar.isDateInTomorrow(date) { return ("明日", false) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = sameYear ? Date.FormatStyle(locale: ja).month().day().weekday(.short) : Date.FormatStyle(locale: ja).year().month().day().weekday(.short)
        return (date.formatted(style), overdue)
    }
}

// MARK: - 配色（ダークは鮮やかに、ライトは同じ色相を白地で読める濃さに）

extension Color {
    /// ライト / ダークで値を変える色（0xRRGGBB）。ウィンドウの外観（テーマ設定）に追従する。
    init(light: UInt32, dark: UInt32, lightOpacity: CGFloat = 1, darkOpacity: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.rgb(dark, alpha: darkOpacity)
                : NSColor.rgb(light, alpha: lightOpacity)
        })
    }
}

extension NSColor {
    static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

/// 分類色（会議シリーズ・話者・積み上げバー）と録音の赤。
enum Palette {
    static let periwinkle = Color(light: 0x4F54D9, dark: 0x8C91FA)
    static let vermilion = Color(light: 0xD63F0A, dark: 0xFF5A24)
    static let amber = Color(light: 0xA87400, dark: 0xF7C62F)
    static let cyan = Color(light: 0x0A84A8, dark: 0x33C9EB)
    static let rose = Color(light: 0xCC4466, dark: 0xF79CA6)
    static let mint = Color(light: 0x10874F, dark: 0x34D683)
    static let violet = Color(light: 0x7B45E6, dark: 0xB58DFA)
    static let teal = Color(light: 0x0B7A71, dark: 0x3CC6B4)
    /// 録音・停止・失敗
    static let record = Color(light: 0xD92D22, dark: 0xFF4A3D)

    static let categorical: [Color] = [periwinkle, vermilion, amber, cyan, rose, mint, violet, teal]

    static func color(forKey key: String) -> Color {
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return categorical[Int(hash % UInt64(categorical.count))]
    }

    /// 会議シリーズの色。カレンダーの件名が同じ会議（定例など）は毎回同じ色になる。
    static func color(for meeting: MeetingRecord) -> Color {
        color(forKey: meeting.calendarTitle ?? meeting.title)
    }
}

/// 面の濃さ。枠線は使わず、ダークは白を・ライトは黒を薄く重ねて区切る。
enum Surface {
    /// カード・タブのトラック
    static let card = Color.primary.opacity(0.05)
    /// ボタン
    static let raised = Color.primary.opacity(0.09)
    static let pressed = Color.primary.opacity(0.16)
    static let hover = Color.primary.opacity(0.07)
    static let hairline = Color.primary.opacity(0.1)
    /// 選択中のタブ（ライトは白い面、ダークは 1 段明るい面）
    static let selectedTab = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightOpacity: 1, darkOpacity: 0.13)
}

extension AppAppearance {
    var title: String {
        switch self {
        case .system: "システムに合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

// MARK: - アイコン・数字

/// 色付きの角丸タイル。同系色の淡い地に記号、縁に細い線（会議・予定のアイコン）。記号が変わるときは置き換えの効果で見せる（状態の変化）。
struct TintedTile: View {
    let systemImage: String
    var tint: Color
    var size: CGFloat = 28
    var pulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        symbol
            .frame(width: size, height: size)
            .background(tint.opacity(0.17), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(0.32), lineWidth: 1))
    }

    /// 点滅（録音中）は `AnimatedSymbol` で描く。点滅しない記号は SwiftUI のまま（会議リストの行など数が多い）。
    @ViewBuilder private var symbol: some View {
        if pulse {
            AnimatedSymbol(systemName: systemImage, pointSize: size * 0.44, weight: .semibold, color: tint, effect: .pulse)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

/// 動き続ける記号（録音中の点滅、字幕の途中経過、後処理中など）。
/// SwiftUI の `.symbolEffect` はフレームごとに main スレッドで描き直し、ウィンドウやパネルを閉じても止まらない。
/// 録音中の CPU の大半はこれだった（G7）。AppKit の `NSImageView` に任せると
/// Core Animation が描くので、main スレッドはほぼ使わない。記号が変わるときは、変化がアニメーションの中で起きたときだけ置き換えの効果で見せる
/// （SwiftUI の `.contentTransition(.symbolEffect(.replace))` と同じ）。
struct AnimatedSymbol: NSViewRepresentable {
    enum Effect: Equatable {
        case pulse
        case breathe
        /// 記号の層を順に光らせる（`variableColor.iterative`）
        case variableColor
        /// 順に光らせて逆順に戻す（`variableColor.iterative.reversing`）
        case variableColorReversing
    }

    let systemName: String
    let pointSize: CGFloat
    var weight: NSFont.Weight = .regular
    let color: Color
    var effect: Effect?

    final class Coordinator {
        fileprivate var symbol: SymbolKey?
        fileprivate var effect: Effect?
    }

    fileprivate struct SymbolKey: Equatable {
        var name: String
        var pointSize: CGFloat
        var weight: NSFont.Weight
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SymbolImageView {
        let view = SymbolImageView()
        view.imageScaling = .scaleNone
        // 意味は隣の文字やヘルプが持つので、読み上げでは飛ばす
        view.setAccessibilityElement(false)
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentHuggingPriority(.required, for: orientation)
            view.setContentCompressionResistancePriority(.required, for: orientation)
        }
        return view
    }

    func updateNSView(_ view: SymbolImageView, context: Context) {
        let coordinator = context.coordinator
        // SwiftUI の色を NSColor にしても、ライト / ダークの切り替えには追従する（Palette の動的な色はそのまま戻る）
        view.contentTintColor = NSColor(color)
        let symbol = SymbolKey(name: systemName, pointSize: pointSize, weight: weight)
        var imageChanged = false
        if coordinator.symbol != symbol,
           let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
               .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .medium)) {
            if let previous = coordinator.symbol, previous.name != systemName, context.transaction.animation != nil {
                view.setSymbolImage(image, contentTransition: .replace)
            } else {
                view.image = image
            }
            coordinator.symbol = symbol
            imageChanged = true
        }
        guard coordinator.effect != effect || (imageChanged && effect != nil) else { return }
        view.removeAllSymbolEffects(animated: false)
        // AppKit の効果は既定では数回で止まる（SwiftUI は繰り返す）。繰り返しを明示する
        switch effect {
        case .pulse: view.addSymbolEffect(.pulse, options: .repeat(.periodic))
        case .breathe: view.addSymbolEffect(.breathe, options: .repeat(.periodic))
        case .variableColor: view.addSymbolEffect(.variableColor.iterative, options: .repeat(.periodic))
        case .variableColorReversing: view.addSymbolEffect(.variableColor.iterative.reversing, options: .repeat(.periodic))
        case nil: break
        }
        coordinator.effect = effect
    }
}

/// `AnimatedSymbol` の中身。会議リストの選択行では、表の行が中の部品に「強調」の背景を伝え、NSImageView は記号を白く描く。
/// SwiftUI の Image と同じく、指定した色のまま描くよう、その指示を受け取らない。
final class SymbolImageView: NSImageView {
    override class var cellClass: AnyClass? {
        get { FixedBackgroundImageCell.self }
        set {}
    }
}

private final class FixedBackgroundImageCell: NSImageCell {
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set {}
    }
}

extension NSFont.TextStyle {
    /// SwiftUI の `.font(.caption2)` などと同じ大きさ（`AnimatedSymbol` の pointSize に渡す）。
    var pointSize: CGFloat { NSFont.preferredFont(forTextStyle: self).pointSize }
}

/// 大きな経過時間。1 時間未満は m:ss、1 時間以上は h:mm に小さく秒を添える。コロンは薄くする。
/// 幅が足りないとき（パネルで予定の残り時間と停止が並ぶときなど）は数字を折り返さず、入る大きさまで段階的に小さくする。
/// 数字が変わると、変わった桁だけを転がす（SwiftUI の `.contentTransition(.numericText())` と同じ動き）。描画と動きは
/// `RollingTimerView`（Core Animation）に任せる。SwiftUI の numericText は 1 秒ごとに約 0.7 秒動き続け、それだけで
/// main スレッドを 15% 使い、パネルを閉じても止まらなかった（G7）。
struct BigTimerText: View {
    let seconds: Double
    var size: CGFloat = 50
    var isDimmed = false

    var body: some View {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        RollingTimer(seconds: total, size: size, isDimmed: isDimmed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hours > 0 ? "\(hours) 時間 \(minutes) 分 \(rest) 秒" : "\(minutes) 分 \(rest) 秒")
    }
}

private struct RollingTimer: NSViewRepresentable {
    let seconds: Int
    let size: CGFloat
    let isDimmed: Bool

    func makeNSView(context: Context) -> RollingTimerView { RollingTimerView() }

    func updateNSView(_ view: RollingTimerView, context: Context) {
        view.update(seconds: seconds, size: size, isDimmed: isDimmed, animated: !context.transaction.disablesAnimations)
    }

    /// 幅に入る大きさを選ぶ（入らなければいちばん小さい段）。高さは `size` のときのまま保つ。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingTimerView, context: Context) -> CGSize? {
        nsView.availableWidth = proposal.width
        let layout = RollingTimerView.fittingLayout(seconds: seconds, size: size, isDimmed: isDimmed, width: proposal.width, backing: nsView.backingScale)
        return CGSize(width: layout.width, height: RollingTimerView.lineHeight(size: size))
    }
}

/// 所要時間（2 時間 35 分）。数字を大きく、単位を小さく組む。
struct DurationText: View {
    let seconds: TimeInterval
    var size: CGFloat = 24

    private var parts: [(value: Int, unit: String)] {
        let minutes = Int((max(0, seconds) / 60).rounded())
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

// MARK: - 動き（時間と遷移を 1 か所にまとめる）

/// アプリ共通のアニメーション。押下・ホバーは速く、面の出し入れは `smooth`、記号の置き換えは `snappy`。
/// Reduce Motion（システム設定 > アクセシビリティ > 視差効果を減らす）では移動・拡縮を省き、フェードだけにする。
/// 会議どうしの切り替えや本文の編集など、ユーザーが何度も行う操作は動かさない。
enum Motion {
    /// 押下（ボタンの縮みと面の濃さ）
    static var press: Animation { .snappy(duration: 0.18) }
    /// ホバー（面の濃さ）
    static var hover: Animation { .easeOut(duration: 0.12) }
    /// 面の出し入れ・カードの伸縮（会議詳細の組み替え）
    static var layout: Animation { .smooth(duration: 0.35) }
    /// 状態の記号の置き換え
    static var symbol: Animation { .snappy(duration: 0.25) }
    /// 再生位置への追従スクロールと、再生中の行の強調
    static var follow: Animation { .smooth(duration: 0.3) }

    /// 上端から出し入れするバナー。
    static func banner(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    /// カードの中身や行。出るときは少し下から浮かび、消えるときは残さない（前後の文字を重ねない）。
    static func content(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)), removal: .identity)
    }

    /// チップ。出るときは少し小さい状態から、消えるときは残さない。
    static func chip(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)), removal: .identity)
    }

    /// 「まだありません」などの代替表示。中身と入れ替わるので、消えるときは残さない。
    static var placeholder: AnyTransition { .asymmetric(insertion: .opacity, removal: .identity) }
}

// MARK: - ボタン

/// 主操作ボタンの左に置く丸い記号（録音: 赤地に白丸、停止: 反転色の地に角丸の四角）。
struct PillGlyph: View {
    enum Kind { case record, stop }

    let kind: Kind
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            switch kind {
            case .record:
                Circle().fill(Palette.record)
                Circle().fill(.white).frame(width: size * 0.34, height: size * 0.34)
            case .stop:
                Circle().fill(Color.primary)
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(.background)
                    .frame(width: size * 0.34, height: size * 0.34)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 主操作のピルの内容（記号・文字・ヘルプ・ショートカット）。状態ごとに別のボタンを差し替えるのではなく、
/// 1 つのボタンの内容を変えることで、カプセルが幅を変えながら記号と文字が入れ替わる。
struct PrimaryPill {
    var glyph: PillGlyph.Kind
    var title: String
    var help: String
    var shortcut: KeyboardShortcut? = nil
}

/// 録音・停止などの主操作（丸い記号 + 文字のカプセル）。
struct PillButtonStyle: ButtonStyle {
    var height: CGFloat = 38

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, height: height)
    }

    private struct PillButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: height * 0.38, weight: .semibold))
                .padding(.leading, height * 0.16)
                .padding(.trailing, height * 0.42)
                .frame(height: height)
                .background(configuration.isPressed ? Surface.pressed : Surface.raised, in: .capsule)
                .contentShape(.capsule)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// 補助操作の丸いボタン（キャンセル・ウィンドウで表示など）。
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 38

    func makeBody(configuration: Configuration) -> some View {
        CircleIconButtonBody(configuration: configuration, size: size)
    }

    private struct CircleIconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .background(configuration.isPressed ? Surface.pressed : Surface.raised, in: .circle)
                .contentShape(.circle)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// 一覧の行の小さい「録音」ボタンの中身。面と押下の応答は `MiniPillButtonStyle` が持つ。
struct MiniRecordLabel: View {
    var title = "録音"

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Palette.record).frame(width: 7, height: 7)
            Text(title).font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
    }
}

/// 一覧の行の小さいカプセルボタン（`MiniRecordLabel` 用）。`PillButtonStyle` と同じ値で押下に応える。
struct MiniPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MiniPillButtonBody(configuration: configuration)
    }

    private struct MiniPillButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background(configuration.isPressed ? Surface.pressed : Surface.raised, in: .capsule)
                .contentShape(.capsule)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// 記号だけのボタン（次の会議カードの録音の丸など）。押下で少し縮み、薄くする。
struct GlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlyphButtonBody(configuration: configuration)
    }

    private struct GlyphButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.75 : 1)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// 押せるチップ（根拠リンクなど）。ホバーで塗りを濃くし、押下でさらに濃くして、押せない `InfoChip` と見分けられるようにする。
/// 塗りは `InfoChip` と同じ `.fill.tertiary` を地にして、その上に薄い黒（ライト）/ 白（ダーク）を重ねる。
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipButtonBody(configuration: configuration)
    }

    private struct ChipButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    ZStack {
                        Capsule().fill(.fill.tertiary)
                        Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.1 : (hovering ? 0.05 : 0)))
                    }
                }
                .contentShape(.capsule)
                .onHover { hovering = $0 }
                .animation(Motion.hover, value: hovering)
                .animation(Motion.hover, value: configuration.isPressed)
        }
    }
}

/// 上辺の中央から時計回りに一周するカプセルの輪郭（進捗の枠線用）。
struct TopStartCapsule: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.midY), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.midY), radius: radius, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// 予定の残り時間。実線が残り、点線が経過（予定を過ぎたら琥珀色で超過分）。
struct ScheduleProgressPill: View {
    let start: Date
    let end: Date
    let now: Date
    var height: CGFloat = 38

    var body: some View {
        let remaining = end.timeIntervalSince(now)
        let elapsed = min(1, max(0, now.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))))
        let over = remaining < 0
        let minutes = max(1, Int((abs(remaining) / 60).rounded(.up)))
        Text(over ? "\(minutes) 分超過" : "残り \(minutes) 分")
            .font(.system(size: height * 0.35, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(over ? Palette.amber : .primary)
            .padding(.horizontal, height * 0.38)
            .frame(height: height)
            .background {
                TopStartCapsule()
                    .stroke(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                TopStartCapsule()
                    .trim(from: over ? 0 : elapsed, to: 1)
                    .stroke(over ? Palette.amber : Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            .padding(0.75)
            .help(over ? "予定の終了（\(end.formatted(date: .omitted, time: .shortened))）を過ぎています" : "予定の終了（\(end.formatted(date: .omitted, time: .shortened))）まで")
    }
}

// MARK: - タブ・バー・グラフ

/// 面で選択を示すタブ切り替え。
struct SegmentedTabs<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.28)) { selection = tab }
                } label: {
                    Text(title(tab))
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Surface.selectedTab)
                                    .shadow(color: .black.opacity(0.16), radius: 1.5, y: 1)
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
        .background(Surface.card, in: .rect(cornerRadius: 11, style: .continuous))
    }
}

/// 値の比に長さを割り振る。短すぎる区切りも `minimum` は残し、隙間を除いた長さに収める。
enum ProportionalLayout {
    static func lengths(_ values: [Double], total: CGFloat, gap: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard !values.isEmpty else { return [] }
        let usable = max(0, total - gap * CGFloat(values.count - 1))
        let sum = values.reduce(0, +)
        let floor = min(minimum, usable / CGFloat(values.count))
        guard sum > 0 else { return values.map { _ in usable / CGFloat(values.count) } }
        let flexible = usable - floor * CGFloat(values.count)
        return values.map { floor + flexible * CGFloat($0 / sum) }
    }
}

/// 割合の積み上げバー。区切りはカプセルと隙間で示す。値がなければトラックだけを出す。
struct StackedBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 8
    var gap: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let widths = ProportionalLayout.lengths(segments.map(\.value), total: geometry.size.width, gap: gap, minimum: height)
            HStack(spacing: gap) {
                if segments.isEmpty {
                    Capsule().fill(Surface.raised)
                }
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Capsule()
                        .fill(segment.color)
                        .frame(width: widths[index])
                }
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.35), value: segments.map(\.value))
    }
}

/// 1 週間の積み上げ棒グラフ。棒は会議ごとに区切り、今日の列を面で示す。
struct WeekBarChart: View {
    struct Column: Identifiable {
        let date: Date
        let segments: [StackedBar.Segment]
        let isToday: Bool
        let isFuture: Bool
        var id: Date { date }
        var total: Double { segments.reduce(0) { $0 + $1.value } }
    }

    let columns: [Column]
    var barHeight: CGFloat = 72
    var barWidth: CGFloat = 22

    /// 目盛りの上端（時間）。
    private var scaleHours: Int {
        let hours = (columns.map(\.total).max() ?? 0) / 3600
        return [1, 2, 3, 4, 6, 8, 10, 12, 16, 24].first { Double($0) >= hours } ?? Int(hours.rounded(.up))
    }

    var body: some View {
        let scale = Double(scaleHours) * 3600
        HStack(alignment: .top, spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(columns) { column in
                    VStack(spacing: 7) {
                        ZStack(alignment: .bottom) {
                            if column.isToday {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Surface.card)
                                    .padding(.horizontal, 3)
                            }
                            bar(column, scale: scale)
                        }
                        .frame(height: barHeight, alignment: .bottom)
                        labels(column)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                    .help(tooltip(column))
                }
            }
            .background(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle().fill(Surface.hairline).frame(height: 1)
                    Spacer(minLength: 0)
                    Rectangle().fill(Surface.hairline).frame(height: 1)
                }
                .frame(height: barHeight + 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("\(scaleHours)時間")
                Spacer(minLength: 0)
                Text(verbatim: "0")
            }
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(height: barHeight + 8)
            .offset(y: -4)
        }
    }

    private func bar(_ column: Column, scale: Double) -> some View {
        let height = barHeight * CGFloat(min(1, column.total / max(scale, 1)))
        let gap: CGFloat = 2
        // 下から開始順に積む
        let ordered = Array(column.segments.reversed())
        let heights = ProportionalLayout.lengths(ordered.map(\.value), total: max(height, CGFloat(ordered.count) * 2 + gap * CGFloat(max(0, ordered.count - 1))), gap: gap, minimum: 2)
        return VStack(spacing: gap) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, segment in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(segment.color)
                    .frame(height: heights[index])
            }
        }
        .frame(width: barWidth)
        .opacity(column.isFuture ? 0 : 1)
    }

    private func labels(_ column: Column) -> some View {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: column.date)
        return VStack(spacing: 4) {
            Text(Formatting.weekdaySymbols[(weekday + 6) % 7])
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(column.isFuture ? .tertiary : .secondary)
            Text(verbatim: "\(calendar.component(.day, from: column.date))")
                .font(.system(size: 12, weight: column.isToday ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(column.isToday ? AnyShapeStyle(.background) : (column.isFuture ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)))
                .frame(width: 24, height: 24)
                .background {
                    if column.isToday { Circle().fill(Color.primary) }
                }
        }
    }

    private func tooltip(_ column: Column) -> String {
        let day = column.date.formatted(Date.FormatStyle(locale: Formatting.ja).month().day().weekday(.short))
        guard column.total > 0 else { return "\(day) 会議なし" }
        return "\(day) \(Formatting.duration(column.total)) · \(column.segments.count) 件"
    }
}


/// 内訳の 1 行（アイコン・名前・時間・割合）。
struct BreakdownRow<Leading: View>: View {
    let title: String
    var subtitle: String?
    let seconds: TimeInterval
    var fraction: Double?
    /// 割合を出さない行でも割合の列を空ける（ほかの行と時間の列をそろえる）。
    var reservesFractionColumn = false
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(Formatting.duration(seconds))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            if let fraction {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            } else if reservesFractionColumn {
                Color.clear.frame(width: 38, height: 1)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 31)
        .contentShape(.rect)
    }
}

/// 話者の頭文字の丸（話者の色の淡い地）。
struct SpeakerBadge: View {
    let title: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Text(String(title.trimmingCharacters(in: .whitespaces).first.map(String.init) ?? "?").uppercased())
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.17), in: .circle)
            .overlay(Circle().strokeBorder(color.opacity(0.32), lineWidth: 1))
    }
}

extension Formatting {
    /// 曜日の 1 文字（Calendar の weekday 1 = 日曜）。システムの言語設定に関わらず日本語で出す。
    static let weekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]

    /// 会議カードの日付: 今日 10:00 / 昨日 15:30 / 9月22日（月）
    static func relativeStart(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: ja))
        if calendar.isDate(date, inSameDayAs: now) { return "今日 \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨日 \(time)" }
        return dayTitle(date, now: now)
    }
}
