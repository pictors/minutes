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
    @State private var position = ScrollPosition(edge: .top)
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MinutesBrandLockup(height: 30)
                    .padding(.top, 56)
                Text(BrandCopy.promise)
                    .brandDisplay(size: 36)
                    .padding(.top, 36)
                    .fixedSize(horizontal: false, vertical: true)
                Text(BrandCopy.promiseDetail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)

                // アカウントを消したあとの知らせ（消せたことを伝える）
                if let notice = model.signInNotice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Palette.mint)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardBackground()
                        .padding(.top, 24)
                        .accessibilityIdentifier("signIn.notice")
                }

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
                                .onChange(of: code) { _, value in
                                    // 数字だけ・6 桁まで。6 桁そろったらそのままログインする（数字のキーボードには送るキーがない）
                                    let digits = Self.digits(value)
                                    if digits != value {
                                        code = digits
                                    } else if digits.count == 6, !working {
                                        verify()
                                    }
                                }
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
        .scrollPosition($position)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: focus) { _, field in
            if field != nil { revealForm() }
        }
        .background(Surface.page.ignoresSafeArea())
        .overlay(alignment: .top) { statusBarFade }
        .overlay {
            if working { ProgressView().controlSize(.large) }
        }
    }

    /// 入力欄に入ったら、フォームの終わりまで送る。キーボードは欄の下のボタン（コードを送る・ログイン）を隠すので、
    /// キーボードの分だけ表示域が縮んでから動かす。
    private func revealForm() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard focus != nil else { return }
            withAnimation(reduceMotion ? nil : Motion.layout) { position.scrollTo(edge: .bottom) }
        }
    }

    /// 送った中身が時刻やダイナミックアイランドに重ならないように、上の安全域を地の色で覆い、その下を少しぼかす
    private var statusBarFade: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).background(Surface.page)
            LinearGradient(colors: [Surface.page, Surface.page.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
        }
        .allowsHitTesting(false)
    }

    /// 入れた文字から数字だけを 6 桁まで取る（全角の数字や、貼り付けた「123 456」も受ける）
    private static func digits(_ text: String) -> String {
        let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return String(half.filter { $0.isASCII && $0.isNumber }.prefix(6))
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
