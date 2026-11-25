import SwiftUI
import UIKit

// 購入のあとの演出（製品版の P6、SPEC §5.7）: 「Pro になりました」のカードと紙吹雪と成功の振動。
// 画面の購入で、無料から Pro になったのをサーバーで確かめたときだけ出す（BillingStore.celebration）。復元・承認待ちだった購入の承認・起動では出さない。
// 操作は止めない: カードはタップで閉じ、紙吹雪は触れても下の画面に届く。視差効果を減らす設定では、紙吹雪を出さず、カードをフェードで出すだけにする。

/// 「Pro になりました」のカード。使える量（試用のあいだは試用の合計と終わる日）を出す。
struct ProCelebrationCard: View {
    let celebration: BillingStore.Celebration
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = false

    var body: some View {
        Button(action: dismiss) {
            VStack(spacing: 16) {
                TintedTile(systemImage: "star.fill", tint: Palette.amber, size: 60)
                    .symbolEffect(.bounce, value: bounce)
                VStack(spacing: 6) {
                    Text("Pro になりました").brandDisplay(size: 26)
                    Text(BrandCopy.promiseDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows, id: \.text) { row in
                        Label {
                            Text(row.text).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: row.symbol).foregroundStyle(Palette.periwinkle)
                        }
                    }
                }
                .font(.subheadline)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Surface.raised, in: .rect(cornerRadius: 14, style: .continuous))
                Text("タップして閉じる")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
            .background(Self.surface, in: .rect(cornerRadius: 28, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Surface.hairline) }
            .shadow(color: .black.opacity(0.3), radius: 36, y: 16)
            .contentShape(.rect(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("閉じます")
        .accessibilityAction(.escape, dismiss)
        .accessibilityIdentifier("plan.celebration")
        .task {
            AccessibilityNotification.Announcement("Pro になりました").post()
            guard !reduceMotion else { return }
            // カードが出きるころに星を弾ませる
            try? await Task.sleep(for: .milliseconds(240))
            bounce.toggle()
        }
    }

    /// カードの面。後ろのカード（Surface.card）より 1 段明るくして、重なっていると分かるようにする
    private static let surface = Color(light: 0xFFFFFF, dark: 0x1E1E23)

    private struct Row {
        let symbol: String
        let text: String
    }

    private var rows: [Row] {
        if celebration.trial {
            var rows: [Row] = []
            if let limit = celebration.secondsLimit {
                rows.append(Row(symbol: "waveform", text: "試用のあいだは、文字起こしと議事録を合計 \(PlanView.hours(limit))まで"))
            }
            if let end = celebration.trialEndsAt {
                rows.append(Row(symbol: "calendar", text: "無料の試用は \(PlanView.date(end))まで"))
            }
            if let monthly = celebration.monthlySecondsLimit {
                rows.append(Row(symbol: "arrow.triangle.2.circlepath", text: "そのあとは、1 か月に \(PlanView.hours(monthly))まで"))
            }
            return rows
        }
        var rows: [Row] = []
        if let limit = celebration.secondsLimit ?? celebration.monthlySecondsLimit {
            rows.append(Row(symbol: "waveform", text: "文字起こしと議事録を、1 か月に \(PlanView.hours(limit))まで"))
        }
        rows.append(Row(symbol: "macbook.and.iphone", text: "iPhone・Apple Watch・Mac で使えます"))
        return rows
    }
}

/// 紙吹雪（Core Animation。1 枚ずつの層に、落ちる・揺れる・回る・裏返るアニメーションを付ける。動かすのは描画のサーバーなので、
/// アプリの CPU をほとんど使わない）。trigger が変わるたびに、画面の上の端から降らせ、落ちきったら層を外す。触れても下の画面に届く。
/// CAEmitterLayer は使わない: 2026-11-26 にシミュレータで、ときどき 1 粒も降らなかった（止める時刻を描画の時計にした形でも 9 回中 3 回。
/// 層を置くまでの流れはいつもどおりで、原因は分からなかった）。1 枚ずつの層のアニメーションは、描画に載った時点から始まり、7 回とも降った。
struct ConfettiView: UIViewRepresentable {
    let trigger: UUID
    var colors: [Color] = ConfettiView.brandColors

    /// ブランドの色（Palette）。録音の赤と朱色は使わない
    static let brandColors: [Color] = [Palette.periwinkle, Palette.violet, Palette.cyan, Palette.teal, Palette.mint, Palette.amber, Palette.rose]

    func makeUIView(context: Context) -> ConfettiBurstView { ConfettiBurstView() }

    func updateUIView(_ view: ConfettiBurstView, context: Context) {
        // ライト / ダークの色を、いまの見た目で決めてから渡す
        view.burst(trigger, colors: colors.map { $0.resolve(in: context.environment).cgColor })
    }
}

final class ConfettiBurstView: UIView {
    private var pending: [CGColor]?
    private var lastTrigger: UUID?

    /// 紙の枚数
    private static let pieceCount = 110

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    func burst(_ trigger: UUID, colors: [CGColor]) {
        guard trigger != lastTrigger else { return }
        lastTrigger = trigger
        pending = colors
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 大きさが決まってから降らせる（最初の配置の前は 0）
        guard let colors = pending, !colors.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        pending = nil
        start(colors: colors)
    }

    private func start(colors: [CGColor]) {
        let container = CALayer()
        container.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 全部が落ちきったら外す（アニメーションが終わったときに呼ばれる）
        CATransaction.setCompletionBlock { [weak container] in container?.removeFromSuperlayer() }
        for index in 0..<Self.pieceCount {
            container.addSublayer(Self.piece(color: colors[index % colors.count], shape: Shape.allCases[index % Shape.allCases.count], in: bounds.size))
        }
        layer.addSublayer(container)
        CATransaction.commit()
    }

    private enum Shape: CaseIterable {
        /// 細長い四角
        case strip
        /// 丸
        case dot
        /// 短いリボン
        case ribbon

        var size: CGSize {
            switch self {
            case .strip: CGSize(width: 10, height: 5)
            case .dot: CGSize(width: 6, height: 6)
            case .ribbon: CGSize(width: 4, height: 11)
            }
        }
    }

    /// 1 枚の紙。外の層が落ちる・揺れる・回る・消える、中の層（色の面）が裏返る。
    /// どのアニメーションも始まりは 0（描画に載った時点）にし、降りはじめのずれは keyTimes の中で持つ。
    /// 層そのもの（モデルの値）は、落ちきった所で見えない状態にしておく（アニメーションが外れても残らない）
    private static func piece(color: CGColor, shape: Shape, in size: CGSize) -> CALayer {
        let delay = Double.random(in: 0...0.6)
        let fall = Double.random(in: 2.4...3.6)
        let total = delay + fall
        let start = CGPoint(x: .random(in: -10...(size.width + 10)), y: .random(in: -36 ... -8))
        let endY = size.height + 30
        // 落ちる: 初めの速さ + 重さ（落ちきる時刻に画面の下を出るように重さを決める）
        let v0 = Double.random(in: 40...140)
        let gravity = max(0, 2 * (Double(endY - start.y) - v0 * fall) / (fall * fall))
        // 揺れる: 横に流れながら、左右に振れる
        let drift = Double.random(in: -60...60)
        let sway = Double.random(in: 6...18)
        let swayPeriod = Double.random(in: 0.9...1.6)
        let phase = Double.random(in: 0...(2 * .pi))
        let steps = 14
        var positions: [NSValue] = [NSValue(cgPoint: start)]
        var keyTimes: [NSNumber] = [0]
        for step in 0...steps {
            let t = fall * Double(step) / Double(steps)
            let x = Double(start.x) + drift * t / fall + sway * sin(2 * .pi * t / swayPeriod + phase) - sway * sin(phase)
            let y = Double(start.y) + v0 * t + 0.5 * gravity * t * t
            positions.append(NSValue(cgPoint: CGPoint(x: x, y: y)))
            keyTimes.append(NSNumber(value: (delay + t) / total))
        }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = positions
        move.keyTimes = keyTimes
        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let angle = Double.random(in: 0...(2 * .pi))
        spin.values = [angle, angle, angle + Double.random(in: -3...3) * 2 * .pi]
        spin.keyTimes = [0, NSNumber(value: delay / total), 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0, 1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: delay / total), NSNumber(value: min(1, (delay + 0.05) / total)), NSNumber(value: (delay + fall * 0.75) / total), 1]
        let group = CAAnimationGroup()
        group.animations = [move, spin, fade]
        group.duration = total
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        let outer = CALayer()
        outer.bounds = CGRect(origin: .zero, size: shape.size)
        outer.position = CGPoint(x: start.x, y: endY)
        outer.opacity = 0
        outer.add(group, forKey: "fall")

        let paper = CALayer()
        paper.frame = outer.bounds
        paper.backgroundColor = color
        paper.cornerRadius = shape == .dot ? shape.size.width / 2 : 1.2
        // 裏返る（縦に縮んで戻る。紙がひらひらして見える）
        let flip = CAKeyframeAnimation(keyPath: "transform.scale.y")
        flip.values = [1, 0.15, 1]
        flip.duration = Double.random(in: 0.35...0.8)
        flip.repeatDuration = total
        flip.isRemovedOnCompletion = false
        paper.add(flip, forKey: "flip")
        outer.addSublayer(paper)
        return outer
    }
}
