import MinutesCore
import SwiftUI

/// プロバイダの行に出す、Minutes アカウントのログインの状態。ログインしていなければ、設定 > アカウント へ進むボタンを添える。
struct MinutesCloudStatusLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let email = model.minutesCloudEmail {
            Label(email.isEmpty ? "ログイン中" : "ログイン中（\(email)）", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                Label("ログインしていません", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Button("ログイン…") { model.requestedSettingsTab = .account }
            }
        }
    }
}

/// 設定 > アカウント（SPEC §5.6・§10.3）: Minutes アカウントのログイン、プランと今月の量、このアカウントでできること。
/// ログインはメールに届く 6 桁のコード（要判断 #24。Developer ID の Mac は Sign in with Apple を使えない）。
/// ログインは、文字起こしと要約の手段（Minutes クラウド）を選ぶこととは別に置く: iPhone・Apple Watch の会議の取り込み（§4.5）は、
/// ログインだけで働く。印は Keychain に置く（MinutesCloudCredentials）。印・メールアドレスはログに出さない。
struct AccountSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var message: String?
    @State private var account: MinutesCloudAccount?
    @State private var accountError: String?
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    var body: some View {
        Form {
            if let signedIn = model.minutesCloudEmail {
                signedInSection(signedIn)
            } else {
                signInSection
            }
            featuresSection
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight)
        .task(id: model.minutesCloudEmail) { await loadAccount() }
    }

    // MARK: ログイン

    private var signInSection: some View {
        Section {
            if !codeSent {
                // 入力欄だと分かるように、枠のある欄に例のアドレスを薄く出す（プロバイダの API キーの欄と同じ見た目）
                LabeledContent("メールアドレス") {
                    HStack(spacing: 8) {
                        TextField("", text: $email, prompt: Text("name@company.com"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 260)
                            .focused($focus, equals: .email)
                            .onSubmit { send() }
                        Button(busy ? "送っています…" : "コードを送る") { send() }
                            .disabled(busy || !email.contains("@"))
                    }
                }
            } else {
                LabeledContent("メールアドレス") { Text(email) }
                LabeledContent("メールに届いた 6 桁のコード") {
                    HStack(spacing: 8) {
                        TextField("", text: $code, prompt: Text("123456"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 110)
                            .monospacedDigit()
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
                        Button(busy ? "確かめています…" : "ログイン") { signIn() }
                            .disabled(busy || code.count < 6)
                    }
                }
                HStack(spacing: 8) {
                    Button("コードを送り直す") { send() }
                        .disabled(busy)
                    Button("メールアドレスを変える") {
                        codeSent = false
                        code = ""
                        message = nil
                        focus = .email
                    }
                    .disabled(busy)
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Minutes アカウント")
        } footer: {
            Text("メールに届く 6 桁のコードでログインします。アカウントがなければ、ここで作られます。iPhone の Minutes と同じアカウントにするには、iPhone のアカウントの画面に出ているアドレスを入れてください。")
        }
    }

    private func signedInSection(_ signedIn: String) -> some View {
        Section {
            LabeledContent("ログイン中") {
                Text(signedIn.isEmpty ? "（メールアドレスは記録していません）" : signedIn)
                    .textSelection(.enabled)
            }
            LabeledContent("プラン") { Text(planText) }
            if let account, account.plan != "free" {
                LabeledContent("今月の利用") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(Self.usageText(account.usage))
                            .monospacedDigit()
                        ProgressView(value: Self.usageFraction(account.usage))
                            .frame(width: 200)
                    }
                }
            }
            Button("ログアウト", role: .destructive) { signOut() }
                .disabled(busy)
        } header: {
            Text("Minutes アカウント")
        }
    }

    // MARK: この Mac での使いみち

    /// このアカウントを、この Mac で何に使っているか（SPEC §4.5・§5.6）。取り込みはログインしていればいつも、
    /// Mac の会議の文字起こしと要約は「プロバイダ」で Minutes クラウドに任せているときだけ。
    private var featuresSection: some View {
        let signedIn = model.minutesCloudEmail != nil
        let cloud = model.settings.usesMinutesCloud
        return Section {
            usage("applewatch", title: "iPhone・Apple Watch の会議をこの Mac へ",
                  status: signedIn ? "取り込んでいます" : "ログインすると、自動で取り込みます", active: signedIn) {
                EmptyView()
            }
            usage("cloud", title: "Mac で録った会議の文字起こしと要約",
                  status: cloud ? "Minutes クラウドに任せています" : "使っていません（\(ownProvidersText) を使っています）", active: cloud) {
                Button("変える") { model.requestedSettingsTab = .providers }
            }
        } header: {
            Text("この Mac での使いみち")
        } footer: {
            Text("Minutes クラウドは、会議の音声と文字起こしを Pictors のサーバー（api.minutes.tools）に送ります。サーバーは ElevenLabs で文字起こしし、Anthropic で要約します。音声はサーバーに 30 日保存し、そのあと自動で消します。iPhone・Apple Watch で録った会議は、いつも Minutes クラウドで文字起こしと要約をします。")
        }
    }

    /// 「自分で選ぶ」で使っている手段（「ElevenLabs Scribe v2・Codex」）
    private var ownProvidersText: String {
        let summary: String = switch model.settings.resolvedSummaryProvider {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .anthropic: "Anthropic API"
        case .minutesCloud: "Minutes クラウド"
        case .none: "要約なし"
        }
        return "\(ProviderCatalog.finalShortTitle(model.settings.finalProviderId))・\(summary)"
    }

    private func usage(_ symbol: String, title: String, status: String, active: Bool, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Label(status, systemImage: active ? "checkmark.circle.fill" : "minus.circle")
                    .font(.callout)
                    .foregroundStyle(active ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 2)
    }

    // MARK: 表示

    private var planText: String {
        if let accountError { return accountError }
        guard let account else { return "確かめています…" }
        return account.plan == "free" ? "無料（Minutes クラウドは使えません）" : "有料"
    }

    /// 「4 時間 10 分 / 30 時間」（処理中の分も使った量に入れる）
    static func usageText(_ usage: MinutesCloudAccount.Usage) -> String {
        "\(duration(usage.secondsThisMonth + usage.secondsPending)) / \(duration(usage.secondsLimit))"
    }

    static func usageFraction(_ usage: MinutesCloudAccount.Usage) -> Double {
        guard usage.secondsLimit > 0 else { return 0 }
        return min(1, max(0, (usage.secondsThisMonth + usage.secondsPending) / usage.secondsLimit))
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.down))
        guard minutes >= 60 else { return "\(minutes) 分" }
        return minutes % 60 == 0 ? "\(minutes / 60) 時間" : "\(minutes / 60) 時間 \(minutes % 60) 分"
    }

    /// 入れた文字から数字だけを 6 桁まで取る（全角の数字や、貼り付けた「123 456」も受ける）
    private static func digits(_ text: String) -> String {
        let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return String(half.filter { $0.isASCII && $0.isNumber }.prefix(6))
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: 操作

    private func send() {
        guard !busy, email.contains("@") else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await model.sendMinutesCloudCode(email: email)
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
