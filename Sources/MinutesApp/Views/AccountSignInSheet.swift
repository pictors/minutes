import SwiftUI

/// Minutes アカウントのサインインのパネル（SPEC §5.6）。設定 > アカウント の「サインイン…」から開く。
/// 上に「Apple でサインイン」（ブラウザを通す）、「または」の下にメールに届く 6 桁のコード（iPhone のログインの画面と同じ並び）。
/// メールのコードは、同じパネルの中でアドレス → 6 桁と進む。入れたら閉じる。
/// 操作は外から受け取る（AppModel に頼らないので、パネルだけを描いて確かめられる）。
struct AccountSignInSheet: View {
    struct Actions {
        /// Apple でサインイン。利用者が閉じた・断ったときは CancellationError を投げる（何も出さない）
        var signInWithApple: () async throws -> Void
        var sendCode: (_ email: String) async throws -> Void
        var signIn: (_ email: String, _ code: String) async throws -> Void
    }

    let actions: Actions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var appleBusy = false
    @State private var message: String?
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Minutes アカウントにサインイン")
                    .font(.title3.weight(.semibold))
                Text("アカウントがなければ、ここで作られます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !codeSent {
                appleButton
                separator
                emailStep
            } else {
                codeStep
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("iPhone の Minutes と同じ方法を選ぶと、同じアカウントになります（メールなら、iPhone のアカウントの画面に出ているアドレス）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    // ブラウザで Apple のページを開いているあいだは閉じない（ブラウザの窓を閉じれば戻る）
                    .disabled(appleBusy)
            }
        }
        .padding(20)
        .frame(width: Self.width)
    }

    // MARK: Apple

    /// Apple の決まりに沿った見た目（ライトは黒地に白、ダークは白地に黒。ロゴと「Apple でサインイン」）
    private var appleButton: some View {
        Button {
            signInWithApple()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "apple.logo")
                Text(appleBusy ? "ブラウザで続けてください…" : "Apple でサインイン")
            }
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .background(colorScheme == .dark ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(busy && !appleBusy ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("Apple でサインイン")
    }

    private var separator: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            Text("または")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
    }

    // MARK: メールのコード

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("メールアドレス")
                .font(.callout)
            // 例のアドレスは verbatim で渡す（文字列のままだとリンクとして青く描かれる）
            TextField("", text: $email, prompt: Text(verbatim: "name@company.com").foregroundStyle(.tertiary))
                .labelsHidden()
                .modifier(TallField(focused: focus == .email))
                .focused($focus, equals: .email)
                .onSubmit { send() }
            Button {
                send()
            } label: {
                Text(busy && !appleBusy ? "送っています…" : "コードを送る")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(busy || !email.contains("@"))
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(email) に届いた 6 桁のコード")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $code, prompt: Text(verbatim: "123456").foregroundStyle(.tertiary))
                .labelsHidden()
                .modifier(TallField(focused: focus == .code))
                .font(.title3.monospacedDigit())
                .textContentType(.oneTimeCode)
                .focused($focus, equals: .code)
                .onChange(of: code) { _, value in
                    // 数字だけ・6 桁まで。6 桁そろったらそのままログインする（iPhone のアプリと同じ）
                    let digits = Self.digits(value)
                    if digits != value {
                        code = digits
                    } else if digits.count == 6, !busy {
                        signIn()
                    }
                }
                .onSubmit { signIn() }
            Button {
                signIn()
            } label: {
                Text(busy ? "確かめています…" : "ログイン")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(busy || code.count < 6)
            HStack(spacing: 14) {
                Button("コードを送り直す") { send() }
                Button("メールアドレスを変える") {
                    codeSent = false
                    code = ""
                    message = nil
                    focus = .email
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            .disabled(busy)
        }
    }

    /// 入れた文字から数字だけを 6 桁まで取る（全角の数字や、貼り付けた「123 456」も受ける）
    static func digits(_ text: String) -> String {
        let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return String(half.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: 操作

    private func signInWithApple() {
        guard !busy else { return }
        busy = true
        appleBusy = true
        message = nil
        Task {
            defer {
                busy = false
                appleBusy = false
            }
            do {
                try await actions.signInWithApple()
                dismiss()
            } catch is CancellationError {
                // 利用者が閉じた。何も出さない
            } catch {
                message = describe(error)
            }
        }
    }

    private func send() {
        guard !busy, email.contains("@") else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await actions.sendCode(email)
                codeSent = true
                code = ""
                focus = .code
                message = "コードを送りました（5 分で切れます）。メールが届かなければ、迷惑メールも見てください。"
            } catch {
                message = describe(error)
            }
        }
    }

    private func signIn() {
        guard !busy, code.count == 6 else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await actions.signIn(email, code)
                dismiss()
            } catch {
                message = describe(error)
            }
        }
    }
}

/// パネルの入力欄。標準の枠つきの欄は低く、上の「Apple でサインイン」や下のボタンと並べると細く見えるので、高さのある欄を自前で描く
/// （枠・地・フォーカスの輪は標準の欄に寄せる）。
private struct TallField: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: focused ? 2 : 1))
    }
}
