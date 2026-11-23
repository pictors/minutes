import AuthenticationServices
import MinutesKit
import SwiftUI

/// ログイン: Sign in with Apple か、メールに届く 6 桁のコード（Mac と同じアカウントにするとき）。
struct SignInView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nonce = MinutesCloudAppleNonce.make()
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var working = false
    @State private var message: String?
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TintedTile(systemImage: "waveform", tint: Palette.periwinkle, size: 64)
                    .padding(.top, 56)
                Text("Minutes")
                    .font(.system(size: 40, weight: .bold))
                    .padding(.top, 20)
                Text("会議を録音すると、文字起こしと議事録（要約・決まったこと・やること）ができます。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)

                SignInWithAppleButton(.signIn) { request in
                    nonce = MinutesCloudAppleNonce.make()
                    request.requestedScopes = [.email]
                    request.nonce = nonce.hashed
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 54)
                .clipShape(.capsule)
                .disabled(working)
                .padding(.top, 36)

                HStack(spacing: 12) {
                    Rectangle().fill(Surface.hairline).frame(height: 1)
                    Text("またはメールで").font(.footnote).foregroundStyle(.secondary).fixedSize()
                    Rectangle().fill(Surface.hairline).frame(height: 1)
                }
                .padding(.vertical, 24)

                VStack(alignment: .leading, spacing: 12) {
                    field {
                        TextField("メールアドレス", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .email)
                            .submitLabel(.send)
                            .onSubmit { if !codeSent { send() } }
                            .disabled(codeSent || working)
                            .foregroundStyle(codeSent ? .secondary : .primary)
                    }
                    if codeSent {
                        field {
                            TextField("6 桁のコード", text: $code)
                                .textContentType(.oneTimeCode)
                                .keyboardType(.numberPad)
                                .font(.title3.weight(.semibold).monospacedDigit())
                                .focused($focus, equals: .code)
                        }
                        .transition(Motion.content(reduceMotion: reduceMotion))
                        Button("ログイン") { verify() }
                            .buttonStyle(FilledPillButtonStyle(height: 54))
                            .disabled(code.count < 6 || working)
                        Button("アドレスを変える") {
                            codeSent = false
                            code = ""
                            focus = .email
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                    } else {
                        Button("コードを送る") { send() }
                            .buttonStyle(FilledPillButtonStyle(height: 54))
                            .disabled(!email.contains("@") || working)
                    }
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Palette.rose)
                            .transition(.opacity)
                    }
                    Text(codeSent ? "メールに届いた 6 桁のコードを入れてください。" : "Mac の Minutes でログインしたことがあれば、同じアドレスにすると同じアカウントになります。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .animation(Motion.layout, value: codeSent)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Surface.page.ignoresSafeArea())
        .overlay {
            if working { ProgressView().controlSize(.large) }
        }
    }

    private func field(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(Surface.card, in: .capsule)
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential, let token = credential.identityTokenString else {
                message = "Apple のログインの情報を読めませんでした"
                return
            }
            run { try await model.signInWithApple(identityToken: token, nonce: nonce) }
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code != .canceled { message = error.localizedDescription }
        }
    }

    private func send() {
        guard email.contains("@") else { return }
        run {
            try await model.sendCode(email: email)
            codeSent = true
            focus = .code
        }
    }

    private func verify() {
        run { try await model.signIn(email: email, code: code) }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await work()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
