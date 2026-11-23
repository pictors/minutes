import AuthenticationServices
import MinutesKit
import SwiftUI

/// ログイン: Sign in with Apple か、メールに届く 6 桁のコード（Mac と同じアカウントにするとき）。
struct SignInView: View {
    @Environment(PhoneModel.self) private var model
    @State private var nonce = MinutesCloudAppleNonce.make()
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var working = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Minutes")
                            .font(.largeTitle.bold())
                        Text("会議を録音すると、文字起こしと議事録（要約・決まったこと・やること）ができます。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    SignInWithAppleButton(.signIn) { request in
                        nonce = MinutesCloudAppleNonce.make()
                        request.requestedScopes = [.email]
                        request.nonce = nonce.hashed
                    } onCompletion: { result in
                        handleApple(result)
                    }
                    .frame(height: 48)
                    .disabled(working)
                }

                Section {
                    TextField("メールアドレス", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(codeSent || working)
                    if codeSent {
                        TextField("6 桁のコード", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                        Button("ログイン") { verify() }
                            .disabled(code.count < 6 || working)
                        Button("アドレスを変える", role: .cancel) {
                            codeSent = false
                            code = ""
                        }
                    } else {
                        Button("コードを送る") { send() }
                            .disabled(!email.contains("@") || working)
                    }
                } header: {
                    Text("メールで")
                } footer: {
                    Text("Mac の Minutes でログインしたことがあれば、同じアドレスにすると同じアカウントになります。")
                }

                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("ログイン")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if working { ProgressView() }
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
            run { try await model.signInWithApple(identityToken: token, nonce: nonce) }
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code != .canceled { message = error.localizedDescription }
        }
    }

    private func send() {
        run {
            try await model.sendCode(email: email)
            codeSent = true
            message = nil
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
