import MinutesKit
import SwiftUI

/// アカウント: ログイン中のアドレス（Mac で使うアドレス）、プランと今月の量、ログアウト、アカウントの削除（ガイドライン 5.1.1(v)）。
struct AccountView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var working = false
    @State private var message: String?
    @State private var apple = AppleAuthorization()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    usageCard
                    planCard
                    emailCard
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Palette.rose)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardBackground()
                    }
                    VStack(spacing: 0) {
                        Button {
                            Task {
                                await model.signOut()
                                dismiss()
                            }
                        } label: {
                            row("ログアウト", systemImage: "rectangle.portrait.and.arrow.right", tint: .primary)
                        }
                        Rectangle().fill(Surface.hairline).frame(height: 1).padding(.leading, 52)
                        Button {
                            confirmingDelete = true
                        } label: {
                            row("アカウントを消す", systemImage: "trash", tint: Palette.rose)
                        }
                        // 確認は押したボタンから出す（画面全体に付けると、関係のない場所から出る）
                        .confirmationDialog("アカウントを消しますか？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                            Button("アカウントを消す", role: .destructive) { deleteAccount() }
                        } message: {
                            Text(model.account?.planSource == "app_store"
                                ? "サーバーの録音・文字起こし・議事録と、この iPhone の録音を消します。元に戻せません。App Store のサブスクリプションは止まらないので、先に「プラン」の「契約を管理」から解約してください。"
                                : "サーバーの録音・文字起こし・議事録と、この iPhone の録音を消します。元に戻せません。")
                        }
                    }
                    .buttonStyle(CardPressStyle())
                    .cardBackground()
                    Text("アカウントを消すと、サーバーの録音・文字起こし・議事録もすべて消えます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Surface.page.ignoresSafeArea())
            .navigationTitle("アカウント")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .disabled(working)
            .overlay { if working { ProgressView().controlSize(.large) } }
            .task { await model.refresh() }
        }
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

    private func deleteAccount() {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                // Apple でログインしたアカウントは、Apple のログインも取り消す（その場で取ったコードを渡す。取れなくても消す）
                var code: String?
                if model.signedInWithApple {
                    code = try? await apple.request(nonce: MinutesCloudAppleNonce.make()).authorizationCodeString
                }
                _ = try await model.deleteAccount(appleAuthorizationCode: code)
                dismiss()
            } catch {
                message = "消せませんでした（\(error.localizedDescription)）"
            }
        }
    }
}
