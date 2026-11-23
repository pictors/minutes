import MinutesCore
import SwiftUI

/// Minutes（キーなし）のログインの状態（プロバイダの行に出す）。
struct MinutesCloudStatusLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let email = model.minutesCloudEmail {
            Label(email.isEmpty ? "ログイン中" : "ログイン中（\(email)）", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        } else {
            Label("ログインしていません", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

/// Minutes（キーなし）のアカウント（SPEC §5.6）。メールに届くコードでログインする（要判断 #24。Developer ID の Mac は Sign in with Apple を使えない）。
/// 印は Keychain に置く（MinutesCloudCredentials）。印・メールアドレスはログに出さない。
struct MinutesCloudAccountSection: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var message: String?
    @State private var account: MinutesCloudAccount?
    @State private var accountError: String?

    var body: some View {
        Section {
            if let signedIn = model.minutesCloudEmail {
                LabeledContent("ログイン中") { Text(signedIn.isEmpty ? "（メールアドレスは記録していません）" : signedIn) }
                LabeledContent("プラン") { Text(planText) }
                Button("ログアウト", role: .destructive) { signOut() }
                    .disabled(busy)
            } else if !codeSent {
                TextField("メールアドレス", text: $email)
                    .onSubmit { send() }
                Button(busy ? "送っています…" : "ログインのコードを送る") { send() }
                    .disabled(busy || !email.contains("@"))
            } else {
                LabeledContent("メールアドレス") { Text(email) }
                TextField("メールに届いた 6 桁のコード", text: $code)
                    .textContentType(.oneTimeCode)
                    .onSubmit { signIn() }
                HStack(spacing: 8) {
                    Button(busy ? "確かめています…" : "ログイン") { signIn() }
                        .disabled(busy || code.trimmingCharacters(in: .whitespaces).count < 6)
                    Button("コードを送り直す") { send() }
                        .disabled(busy)
                    Button("メールアドレスを変える") {
                        codeSent = false
                        code = ""
                        message = nil
                    }
                    .disabled(busy)
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Minutes（キーなし）のアカウント")
        } footer: {
            Text("キーなしは、会議の音声と文字起こしを Pictors のサーバー（api.minutes.tools）に送ります。サーバーは ElevenLabs で文字起こしし、Anthropic で要約します。音声はサーバーに 30 日保存し、そのあと自動で消します。有料のプランで使えます。Mac の会議は相手側と自分のマイクの 2 本を送りますが、使える量は会議の長さだけ数えます。ログインはメールに届くコードで行い、アカウントがなければここで作られます。")
        }
        .task(id: model.minutesCloudEmail) { await loadAccount() }
    }

    private var planText: String {
        if let accountError { return accountError }
        guard let account else { return "確かめています…" }
        guard account.plan != "free" else { return "無料（キーなしは使えません）" }
        let used = Int((account.usage.secondsThisMonth + account.usage.secondsPending) / 60)
        let limit = Int(account.usage.secondsLimit / 60)
        return "有料（今月 \(used) 分 / \(limit) 分）"
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func send() {
        guard !busy, email.contains("@") else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await model.sendMinutesCloudCode(email: email)
                codeSent = true
                message = "コードを送りました（5 分で切れます）。メールが届かなければ、迷惑メールも見てください。"
            } catch {
                message = describe(error)
            }
        }
    }

    private func signIn() {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await model.signInToMinutesCloud(email: email, code: code)
                codeSent = false
                code = ""
            } catch {
                message = describe(error)
            }
        }
    }

    private func signOut() {
        busy = true
        Task {
            await model.signOutOfMinutesCloud()
            account = nil
            accountError = nil
            message = nil
            busy = false
        }
    }

    private func loadAccount() async {
        account = nil
        accountError = nil
        guard model.minutesCloudEmail != nil else { return }
        do {
            account = try await model.minutesCloudAccount()
        } catch {
            accountError = describe(error)
        }
    }
}
