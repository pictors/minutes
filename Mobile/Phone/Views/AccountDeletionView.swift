import AuthenticationServices
import MinutesKit
import StoreKit
import SwiftUI
import UIKit

/// アカウントを消す（ガイドライン 5.1.1(v)）。アカウントの画面のいちばん下の「アカウントを消す」から開く。
/// 押し間違えで消さないように、すぐには消さず、消えるものを並べたうえで、ログイン中のメールアドレス（Apple の「メールを非公開」の
/// アドレスや、分からないときは「削除」）を打ち込むまで、消すボタンを押せない（MinutesCloudDeletionConfirmation）。
struct AccountDeletionView: View {
    @Environment(PhoneModel.self) private var model
    /// 消したあと（アカウントのシートごと閉じる）
    var onDeleted: () -> Void
    @State private var typed = ""
    @State private var working = false
    @State private var message: String?
    @State private var managingSubscriptions = false
    @State private var apple = AppleAuthorization()
    @FocusState private var fieldFocused: Bool

    private var confirmation: MinutesCloudDeletionConfirmation { MinutesCloudDeletionConfirmation(user: model.user) }
    private var confirmed: Bool { confirmation.matches(typed) }
    private static let bottomID = "deletion.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            content
                .scrollDismissesKeyboard(.interactively)
                // キーボードが出たら、入力の欄と消すボタンが見えるところまで送る（キーボードの下に隠れないように）
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    guard fieldFocused else { return }
                    withAnimation(Motion.layout) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
        }
        .background(Surface.page.ignoresSafeArea())
        .navigationTitle("アカウントを消す")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(working)
        .manageSubscriptionsSheet(isPresented: $managingSubscriptions)
        .disabled(working)
        .overlay { if working { ProgressView().controlSize(.large) } }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                removedCard
                subscriptionCard
                confirmCard
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Palette.rose)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardBackground()
                }
                Button(role: .destructive) {
                    delete()
                } label: {
                    Label("アカウントを消す", systemImage: "trash")
                }
                .buttonStyle(FilledPillButtonStyle(tint: Palette.record))
                .disabled(!confirmed || working)
                .accessibilityIdentifier("deletion.delete")
                .padding(.top, 4)
                .padding(.bottom, 8)
                .id(Self.bottomID)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TintedTile(systemImage: "exclamationmark.triangle.fill", tint: Palette.rose, size: 44)
            Text("消すと、元に戻せません")
                .font(.title2.weight(.semibold))
            Text("アカウントを消すと、次のものがすぐに消えます。ログアウトしたいだけなら、前の画面の「ログアウト」を使ってください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private var removedCard: some View {
        SectionCard("消えるもの", systemImage: "trash.fill", tint: Palette.rose) {
            VStack(alignment: .leading, spacing: 12) {
                item("person.crop.circle", "Minutes アカウント", detail: model.user?.email)
                item("waveform", "サーバーの録音・文字起こし・議事録", detail: "同期した Mac の会議の写しも消えます")
                item("link", "閲覧用のリンク", detail: "リンクを渡した相手も、すぐに読めなくなります")
                item("iphone", "この iPhone の録音")
                if model.account?.plan == "pro", model.account?.planSource == "manual" {
                    item("star.fill", "手で設定した Pro")
                }
            }
        }
    }

    /// App Store の自動更新は、アカウントを消しても止まらない（Apple の「Offering account deletion in your app」: 続く支払いを知らせ、先に解約してもらう）
    private var subscriptionCard: some View {
        SectionCard("App Store の契約", systemImage: "creditcard.fill", tint: Palette.amber) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.account?.plan == "pro" && model.account?.planSource == "app_store"
                    ? "このアカウントは App Store で Pro を契約しています。アカウントを消しても、App Store の支払いは止まりません。先に解約してください。"
                    : "App Store で Pro を契約しているときは、アカウントを消しても支払いは止まりません。先に解約してください。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    managingSubscriptions = true
                } label: {
                    Label("契約を管理", systemImage: "creditcard")
                }
                .buttonStyle(PillButtonStyle(height: 36))
                .accessibilityIdentifier("deletion.manageSubscriptions")
            }
        }
    }

    private var confirmCard: some View {
        SectionCard("確認", systemImage: "keyboard", tint: .secondary) {
            VStack(alignment: .leading, spacing: 10) {
                Text(prompt)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                // 打ち込んでもらう（候補やキーボードの自動入力で埋まらないよう、入力の種類は付けない。Return では消さない）
                TextField(placeholder, text: $typed)
                    .keyboardType(isEmail ? .emailAddress : .default)
                    .textContentType(nil)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($fieldFocused)
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(Surface.raised, in: .capsule)
                    .accessibilityLabel(prompt)
                    .accessibilityIdentifier("deletion.confirm")
                // 打ち始めるまでは見せない（場所は空けておき、出たときに下の消すボタンがずれないようにする）
                let empty = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Label(confirmed ? "合っています" : "まだ合っていません", systemImage: confirmed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.footnote)
                    .foregroundStyle(confirmed ? Palette.mint : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(empty ? 0 : 1)
                    .accessibilityHidden(empty)
            }
        }
    }

    private var isEmail: Bool {
        if case .email = confirmation.expected { return true }
        return false
    }

    private var prompt: String {
        switch confirmation.expected {
        case let .email(email): "確かめのため、消すアカウントのメールアドレス（\(email)）を入力してください。"
        case .word: "確かめのため「\(MinutesCloudDeletionConfirmation.word)」（または \(MinutesCloudDeletionConfirmation.asciiWord)）と入力してください。"
        }
    }

    private var placeholder: String { isEmail ? "メールアドレスを入力" : "「\(MinutesCloudDeletionConfirmation.word)」と入力" }

    private func item(_ systemImage: String, _ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func delete() {
        guard confirmed, !working else { return }
        fieldFocused = false
        working = true
        message = nil
        Task {
            defer { working = false }
            // Apple でログインしたアカウントは、Apple のログインも取り消す（その場で取ったコードを渡す）。
            // Apple の確認を閉じたら消さない。ほかの理由でコードが取れないときは、コードなしで消す
            var code: String?
            if model.signedInWithApple {
                do {
                    code = try await apple.request(nonce: MinutesCloudAppleNonce.make()).authorizationCodeString
                } catch let error as ASAuthorizationError where error.code == .canceled {
                    return
                } catch {}
            }
            do {
                _ = try await model.deleteAccount(appleAuthorizationCode: code)
                onDeleted()
            } catch {
                message = "消せませんでした（\(error.localizedDescription)）"
            }
        }
    }
}
