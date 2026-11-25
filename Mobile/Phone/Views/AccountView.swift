import MinutesKit
import SwiftUI

/// アカウント: ログイン中のアドレス（Mac で使うアドレス）、プランと今月の量、ログアウト、アカウントの削除（ガイドライン 5.1.1(v)）。
/// ログアウトとアカウントの削除は隣に並べない。削除は画面のいちばん下の別の場所に置き、押すと説明と確認の画面（AccountDeletionView）に進む。
struct AccountView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    usageCard
                    planCard
                    emailCard
                    signOutCard
                    deletionSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Surface.page.ignoresSafeArea())
            .navigationTitle("アカウント")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task { await model.refresh() }
        }
    }

    /// ログアウト（1 回で済む。この iPhone の録音とサーバーのものは残る）
    private var signOutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    await model.signOut()
                    dismiss()
                }
            } label: {
                row("ログアウト", systemImage: "rectangle.portrait.and.arrow.right", tint: .primary)
            }
            .buttonStyle(CardPressStyle())
            .cardBackground()
            .accessibilityIdentifier("account.signOut")
            Text("ログアウトしても、この iPhone の録音とサーバーの議事録は消えません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
    }

    /// アカウントの削除（ガイドライン 5.1.1(v)）: 見つけやすい場所（アカウントの画面）のまま、ログアウトから離して画面のいちばん下に置く。
    /// 押してもすぐには消さず、消えるものを並べた画面に進む
    private var deletionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("アカウントの削除")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            NavigationLink {
                AccountDeletionView(onDeleted: { dismiss() })
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Palette.rose)
                        .frame(width: 24)
                    Text("アカウントを消す")
                        .foregroundStyle(Palette.rose)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .contentShape(.rect)
            }
            .buttonStyle(CardPressStyle())
            .cardBackground()
            .accessibilityIdentifier("account.delete")
            Text("アカウントと、サーバーの録音・文字起こし・議事録を消します。消えるものを確かめてから消せます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
        .padding(.top, 36)
    }

    private var usageCard: some View {
        // App Store の契約は契約した日から 1 か月ごと、ほかは暦の月で数える（P6）
        SectionCard(model.account?.planSource == "app_store" ? "この 1 か月の録音" : "今月の録音", systemImage: "chart.bar.fill", tint: Palette.periwinkle) {
            if let account = model.account {
                let limit = max(account.usage.secondsLimit, 1)
                let used = min(1, account.usage.secondsThisMonth / limit)
                let pending = min(1 - used, account.usage.secondsPending / limit)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        DurationText(seconds: account.usage.secondsThisMonth, size: 34)
                        Text("/ \(Formatting.duration(account.usage.secondsLimit))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        InfoChip(text: account.plan == "pro" ? "有料" : "無料", systemImage: account.plan == "pro" ? "star.fill" : nil)
                    }
                    GeometryReader { proxy in
                        HStack(spacing: 3) {
                            Capsule().fill(Palette.periwinkle).frame(width: max(6, proxy.size.width * used))
                            if pending > 0 { Capsule().fill(Palette.amber).frame(width: max(6, proxy.size.width * pending)) }
                            Capsule().fill(Surface.raised)
                        }
                    }
                    .frame(height: 8)
                    .animation(Motion.layout, value: used)
                    if account.usage.secondsPending > 0 {
                        Text("処理中 \(Formatting.duration(account.usage.secondsPending))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // App Store の契約は、契約した日から 1 か月ごとに戻る（P6）
                    if account.plan == "pro", account.planSource == "app_store", let end = account.usage.periodEnd {
                        Text("\(PlanView.date(end))に 0 に戻ります（契約した日から 1 か月ごと）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if account.plan != "pro" {
                        Text("無料のアカウントでは、録音を議事録にできません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("読み込んでいます").foregroundStyle(.secondary)
            }
        }
    }

    /// プラン（P6）: 無料なら Pro にする入口、Pro なら期限・自動更新と契約の管理
    private var planCard: some View {
        NavigationLink {
            PlanView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: model.account?.plan == "pro" ? "star.fill" : "sparkles")
                    .font(.body.weight(.medium))
                    .foregroundStyle(model.account?.plan == "pro" ? Palette.amber : Palette.periwinkle)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.account?.plan == "pro" ? "プラン" : "Pro にする")
                        .foregroundStyle(.primary)
                    Text(planSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 54)
            .contentShape(.rect)
        }
        .buttonStyle(CardPressStyle())
        .cardBackground()
        .accessibilityIdentifier("account.plan")
    }

    private var planSubtitle: String {
        guard let account = model.account else { return "読み込んでいます" }
        guard account.plan == "pro" else { return "文字起こしと議事録を使う・購入を復元する" }
        if account.planSource == "manual" { return "Pro（手で設定）" }
        if let end = account.planExpiresAt { return "Pro・いまの期間は\(PlanView.date(end))まで" }
        return "Pro"
    }

    private var emailCard: some View {
        SectionCard("ログイン", systemImage: "envelope.fill", tint: Palette.cyan) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.user?.email ?? "—")
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Text(model.user?.isApplePrivateRelay == true
                    ? "Apple の「メールを非公開」のアドレスです。Mac の Minutes では、このアドレスでログインしてください（コードは Apple が本当のアドレスへ転送します）。"
                    : "Mac の Minutes では、このアドレスでログインすると同じアカウントになります。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 24)
            Text(title)
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .frame(height: 54)
        .contentShape(.rect)
    }
}
