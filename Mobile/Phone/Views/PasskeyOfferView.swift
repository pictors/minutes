import MinutesKit
import SwiftUI

/// メールのコードでログインした直後に、1 度だけパスキーを勧める（ログインしたばかりのセッションなので、確かめ直さずに作れる）。
/// 勧めるのはこの iPhone で 1 度だけ・アカウントにパスキーがないときだけ（PhoneModel.offerPasskeyIfUseful）。
struct PasskeyOfferView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Palette.violet)
                .frame(width: 64, height: 64)
                .background(Palette.violet.opacity(0.14), in: .rect(cornerRadius: 18, style: .continuous))
                .padding(.top, 32)
            Text("次からは、パスキーでログイン")
                .font(.title2.weight(.bold))
                .padding(.top, 20)
                .fixedSize(horizontal: false, vertical: true)
            Text("パスキーを作ると、メールのコードを待たずに、Face ID や Touch ID だけでログインできます。パスキーは iCloud キーチェーンに入り、同じ Apple アカウントのほかの iPhone・iPad でも使えます。")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.rose)
                    .padding(.top, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            Button {
                create()
            } label: {
                Label("パスキーを作る", systemImage: "person.badge.key.fill")
            }
            .buttonStyle(FilledPillButtonStyle(height: 54))
            .accessibilityIdentifier("passkeyOffer.create")
            Button("今はしない") { dismiss() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .accessibilityIdentifier("passkeyOffer.later")
            Text("あとからでも、アカウントの画面で作れます。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .background(Surface.page.ignoresSafeArea())
        .disabled(working)
        .overlay { if working { ProgressView().controlSize(.large) } }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func create() {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await model.createPasskey()
                dismiss()
            } catch where PasskeyAuthorization.isCancellation(error) {
                // 閉じた（シートは残す。「今はしない」で閉じられる）
            } catch {
                message = PasskeyAuthorization.message(for: error)
            }
        }
    }
}
