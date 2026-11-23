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
            Form {
                Section {
                    LabeledContent("メールアドレス", value: model.user?.email ?? "—")
                } footer: {
                    if model.user?.isApplePrivateRelay == true {
                        Text("Apple の「メールを非公開」のアドレスです。Mac の Minutes では、このアドレスでログインしてください（コードは Apple が本当のアドレスへ転送します）。")
                    } else {
                        Text("Mac の Minutes では、このアドレスでログインすると同じアカウントになります。")
                    }
                }

                Section("プラン") {
                    if let account = model.account {
                        LabeledContent("プラン", value: account.plan == "pro" ? "有料" : "無料")
                        LabeledContent("今月", value: "\(Formatting.duration(account.usage.secondsThisMonth)) / \(Formatting.duration(account.usage.secondsLimit))")
                        if account.usage.secondsPending > 0 {
                            LabeledContent("処理中", value: Formatting.duration(account.usage.secondsPending))
                        }
                    } else {
                        Text("読み込んでいます").foregroundStyle(.secondary)
                    }
                }

                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }

                Section {
                    Button("ログアウト") {
                        Task {
                            await model.signOut()
                            dismiss()
                        }
                    }
                    Button("アカウントを消す", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("アカウントを消すと、サーバーの録音・文字起こし・議事録もすべて消えます。")
                }
            }
            .navigationTitle("アカウント")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .disabled(working)
            .overlay { if working { ProgressView() } }
            .confirmationDialog("アカウントを消しますか？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("アカウントを消す", role: .destructive) { deleteAccount() }
            } message: {
                Text("サーバーの録音・文字起こし・議事録と、この iPhone の録音を消します。元に戻せません。")
            }
            .task { await model.refresh() }
        }
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
