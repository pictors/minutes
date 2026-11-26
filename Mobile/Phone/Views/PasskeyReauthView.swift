import AuthenticationServices
import MinutesKit
import SwiftUI

/// パスキーを作る前の確かめ直し（サーバーは、ログインから 1 日以内のセッションでしかパスキーを作らせない）。
/// この iPhone でログインした方法（Apple・パスキー）と、アカウントのアドレスへのコードで、もう一度ログインする。
/// 入ったのが別のアカウントなら、そのログインは取り消して断る（PhoneModel.adoptReauthentication）。
struct PasskeyReauthView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 確かめられた（続けてパスキーを作る）
    var onDone: () -> Void
    @State private var nonce = MinutesCloudAppleNonce.make()
    @State private var code = ""
    @State private var codeSent = false
    @State private var working = false
    @State private var message: String?
    /// アカウントに Apple のログインがつながっているか（サーバーに聞く。この iPhone ではほかの方法で入っていても、Apple で確かめられる）
    @State private var appleLinked = false
    @FocusState private var codeFocused: Bool

    private var email: String? { model.user?.email }
    // 別の Apple ID で新しいアカウントを作らないように、Apple はこのアカウントにつながっているときだけ出す
    private var offersApple: Bool { model.signInMethod == .apple || appleLinked }
    private var offersPasskey: Bool { model.signInMethod == .passkey || model.passkeys?.isEmpty == false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("パスキーを作るには、ログインしてから 1 日以内である必要があります。もう一度ログインすると、続けてパスキーを作ります。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)

                    if offersApple {
                        SignInWithAppleButton(.continue) { request in
                            nonce = MinutesCloudAppleNonce.make()
                            request.requestedScopes = [.email]
                            request.nonce = nonce.hashed
                        } onCompletion: { result in
                            handleApple(result)
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 54)
                        .clipShape(.capsule)
                    }
                    if offersPasskey {
                        Button { run { try await model.reauthenticateWithPasskey() } } label: {
                            Label("パスキーで確かめる", systemImage: "person.badge.key.fill")
                        }
                        .buttonStyle(QuietPillButtonStyle(height: 54))
                    }
                    if let email { codeCard(email) }

                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Palette.rose)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .animation(Motion.layout, value: codeSent)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Surface.page.ignoresSafeArea())
            .navigationTitle("もう一度ログイン")
            .navigationBarTitleDisplayMode(.inline)
            .transparentNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
            }
            .disabled(working)
            .overlay { if working { ProgressView().controlSize(.large) } }
            .task { appleLinked = await model.accountUsesApple() }
        }
    }

    private func codeCard(_ email: String) -> some View {
        SectionCard("メールのコード", systemImage: "envelope.fill", tint: Palette.cyan) {
            VStack(alignment: .leading, spacing: 12) {
                Text(email)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if codeSent {
                    TextField("6 桁のコード", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .focused($codeFocused)
                        .inputField(height: 54, onCard: true, horizontalPadding: 18)
                        .onChange(of: code) { _, value in
                            let digits = Self.digits(value)
                            if digits != value {
                                code = digits
                            } else if digits.count == 6, !working {
                                verify(email)
                            }
                        }
                        .transition(Motion.content(reduceMotion: reduceMotion))
                    Button("確かめる") { verify(email) }
                        .buttonStyle(FilledPillButtonStyle(height: 48))
                        .disabled(code.count < 6)
                } else {
                    Button("コードを送る") { send(email) }
                        .buttonStyle(FilledPillButtonStyle(height: 48))
                }
                Text(model.user?.isApplePrivateRelay == true
                    ? "Apple の「メールを非公開」のアドレスです。コードは Apple が本当のアドレスへ転送します。"
                    : "このアドレスに 6 桁のコードを送ります。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential, let token = credential.identityTokenString else {
                message = "Apple のログインの情報を読めませんでした"
                return
            }
            run { try await model.reauthenticateWithApple(identityToken: token, nonce: nonce) }
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code != .canceled { message = error.localizedDescription }
        }
    }

    private func send(_ email: String) {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await model.sendCode(email: email)
                codeSent = true
                codeFocused = true
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func verify(_ email: String) {
        run { try await model.reauthenticate(email: email, code: code) }
    }

    /// 確かめ直しを行い、できたら閉じて続ける
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await work()
                dismiss()
                onDone()
            } catch PasskeyFailure.noPasskeyOnDevice {
                message = "\(PasskeyFailure.noPasskeyOnDevice.localizedDescription)。ほかの方法で確かめてください"
            } catch where PasskeyAuthorization.isCancellation(error) {
                // 閉じた
            } catch {
                message = PasskeyAuthorization.message(for: error)
            }
        }
    }

    /// 入れた文字から数字だけを 6 桁まで取る（全角の数字や、貼り付けた「123 456」も受ける）
    private static func digits(_ text: String) -> String {
        let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return String(half.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }
}
