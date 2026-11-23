import MinutesKit
import SwiftUI
import UIKit

/// アカウント: ログイン中のアドレス（Mac で使うアドレス）、プランと今月の量、ログアウト、アカウントの削除（ガイドライン 5.1.1(v)）。
struct AccountView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var working = false
    @State private var message: String?
    @State private var copied = false
    @State private var apple = AppleAuthorization()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    usageCard
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
            .confirmationDialog("アカウントを消しますか？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("アカウントを消す", role: .destructive) { deleteAccount() }
            } message: {
                Text("サーバーの録音・文字起こし・議事録と、この iPhone の録音を消します。元に戻せません。")
            }
            .task { await model.refresh() }
        }
    }

    private var usageCard: some View {
        SectionCard("今月の録音", systemImage: "chart.bar.fill", tint: Palette.periwinkle) {
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

    private var emailCard: some View {
        SectionCard(title: "ログイン", systemImage: "envelope.fill", count: nil, tint: Palette.cyan) {
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
        } trailing: {
            if let email = model.user?.email {
                Button {
                    UIPasteboard.general.string = email
                    copied = true
                } label: {
                    Label(copied ? "コピーしました" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .sensoryFeedback(.success, trigger: copied)
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
