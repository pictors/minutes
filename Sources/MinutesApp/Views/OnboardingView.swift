import AppKit
import AVFoundation
import EventKit
import MinutesCore
import SwiftUI
import UserNotifications

/// 初回の案内のウィンドウ（`OnboardingModel`）。最初の起動で開き、設定 > 診断 からも開ける。
/// 最後まで進めずに閉じたら、新しく入れた人の既定（確認してから録音）で使い始める。
struct OnboardingView: View {
    static let size = CGSize(width: 640, height: 660)

    @Environment(AppModel.self) private var model
    @State private var onboarding: OnboardingModel?

    var body: some View {
        ZStack {
            if let onboarding { OnboardingContent(onboarding: onboarding) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear {
            if onboarding == nil { onboarding = OnboardingModel(model: model) }
            model.setOnboardingVisible(true)
        }
        .onDisappear {
            onboarding?.skip()
            onboarding = nil
            model.setOnboardingVisible(false)
        }
    }
}

private struct OnboardingContent: View {
    @Bindable var onboarding: OnboardingModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 進む向き（入ってくる段階を少し横から出す）
    @State private var forward = true

    var body: some View {
        VStack(spacing: 0) {
            // 上端は閉じるボタンの帯（タイトルバーを隠している）。スクロールした中身をその下に潜らせない
            ZStack {
                ScrollView {
                    page
                        .padding(.horizontal, 44)
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .id(onboarding.step)
                .transition(pageTransition)
            }
            .frame(maxHeight: .infinity)
            .clipped()
            footer
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.layout, value: onboarding.step)
    }

    @ViewBuilder private var page: some View {
        switch onboarding.step {
        case .welcome: WelcomePage()
        case .permissions: PermissionsPage(onboarding: onboarding)
        case .apps: AppsPage(onboarding: onboarding)
        case .providers: ProvidersPage(onboarding: onboarding)
        case .test: TestPage(onboarding: onboarding)
        case .done: DonePage(onboarding: onboarding)
        }
    }

    /// 前の段階は残さず消し（文字を重ねない）、次の段階を進む向きから浮かべる。
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .asymmetric(insertion: .opacity, removal: .identity) }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)), removal: .identity)
    }

    private var footer: some View {
        ZStack {
            StepDots(step: onboarding.step)
            footerButtons
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(alignment: .top) {
            Rectangle().fill(Surface.hairline).frame(height: 1)
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 10) {
            if onboarding.step == .welcome {
                Button("あとで設定する") { dismissWindow(id: "onboarding") }
                    .buttonStyle(.link)
                    .help("案内を閉じて使い始めます。設定 > 診断 からもう一度開けます。")
            } else {
                Button("戻る") {
                    forward = false
                    onboarding.back()
                }
                .controlSize(.large)
            }
            Spacer()
            Button(primaryTitle) {
                forward = true
                if onboarding.step == .done {
                    onboarding.complete()
                    dismissWindow(id: "onboarding")
                } else {
                    onboarding.next()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: String {
        switch onboarding.step {
        case .welcome: "始める"
        case .done: "Minutes を使い始める"
        default: "次へ"
        }
    }
}

/// 段階の印。今の段階だけ横に長くする。
private struct StepDots: View {
    let step: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == step ? Palette.periwinkle : (item < step ? Palette.periwinkle.opacity(0.45) : Surface.raised))
                    .frame(width: item == step ? 22 : 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.rawValue + 1) / \(OnboardingModel.Step.allCases.count)：\(step.title)")
    }
}

// MARK: - 部品

private struct PageHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 記号のタイル + 見出し + 説明。
private struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            TintedTile(systemImage: symbol, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 選択肢の行（丸い印 + 名前 + 説明）。行全体を押して選ぶ。
private struct ChoiceRow<Accessory: View>: View {
    let selected: Bool
    let title: String
    var detail: String?
    var icon: NSImage?
    var symbol: String?
    let action: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        Button(action: action) {
            HStack(alignment: detail == nil ? .center : .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
                } else if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension ChoiceRow where Accessory == EmptyView {
    init(selected: Bool, title: String, detail: String? = nil, icon: NSImage? = nil, symbol: String? = nil, action: @escaping () -> Void) {
        self.init(selected: selected, title: title, detail: detail, icon: icon, symbol: symbol, action: action, accessory: { EmptyView() })
    }
}

private struct AppLabel: View {
    let bundleID: String
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            if let icon = AppNames.icon(for: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed").foregroundStyle(.secondary).frame(width: 20, height: 20)
            }
            Text(name)
        }
    }
}

/// 補足の 1 行（記号 + 文）。注意は黄色で出す。
private struct NoteLine: View {
    let text: String
    var warning = false

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: warning ? "exclamationmark.circle.fill" : "info.circle")
                .foregroundStyle(warning ? Palette.amber : .secondary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - 1. ようこそ

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            MinutesBrandLockup(height: 30)
                .padding(.top, 6)
            PageHeader(title: "会議を録音して、議事録まで",
                       detail: "会議アプリの音と自分の声を録音し、会議が終わったら文字起こし・要約・アクションをまとめます。最初に、録音の許可と使うサービスを設定しましょう（3 分ほど）。")
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "waveform", tint: Palette.periwinkle, title: "相手の声と自分の声を分けて録音",
                           detail: "会議アプリの音とマイクを別々に録るので、誰が話したかを分けやすくなります。")
                FeatureRow(symbol: "captions.bubble", tint: Palette.teal, title: "録音中はライブ字幕",
                           detail: "字幕はこの Mac の中で作ります。")
                FeatureRow(symbol: "doc.text", tint: Palette.amber, title: "終わったら議事録",
                           detail: "要約・決定事項・アクションを作り、Markdown でも書き出せます。")
                FeatureRow(symbol: "lock", tint: Palette.mint, title: "データはこの Mac に",
                           detail: "音声と議事録はこの Mac に保存します。文字起こしと要約に使うサービスは、このあと選べます。")
            }
        }
    }
}

// MARK: - 2. 許可

private enum PermissionState: Equatable {
    case granted, notDetermined, denied, checking
}

private struct PermissionsPage: View {
    @Bindable var onboarding: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "録音の許可", detail: "Minutes が使う機能を許可します。許可を求める画面が出たら「許可」を押してください。")
            VStack(spacing: 10) {
                PermissionRow(symbol: "mic.fill", tint: SpeakerPalette.me, title: "マイク", detail: "自分の声を録音します。") {
                    PermissionControl(state: microphone, requestTitle: "許可する",
                                      request: { await onboarding.requestMicrophone() },
                                      openSettings: { SystemSettingsLink.openPrivacy() })
                }
                PermissionRow(symbol: "speaker.wave.2.fill", tint: Palette.periwinkle, title: "会議アプリの音",
                              detail: "会議アプリから出る相手の声を録音します。確かめるとテスト音が鳴ります。") {
                    PermissionControl(state: systemAudio, requestTitle: systemAudioFailure == nil ? "テスト音で確かめる" : "もう一度",
                                      request: { await onboarding.checkSystemAudio() },
                                      openSettings: SystemSettingsLink.openSystemAudio)
                } note: {
                    if systemAudio == .checking {
                        NoteLine(text: "許可を求められたら「許可」を押してください。")
                    } else if let systemAudioFailure {
                        VStack(alignment: .leading, spacing: 6) {
                            NoteLine(text: systemAudioFailure, warning: true)
                            Button("システム設定を開く", action: SystemSettingsLink.openSystemAudio)
                                .controlSize(.small)
                        }
                    }
                }
                PermissionRow(symbol: "calendar", tint: Palette.cyan, title: "カレンダー",
                              detail: "予定から会議名と参加者を入れ、予定の時刻に録音を準備します。") {
                    PermissionControl(state: calendar, requestTitle: "許可する",
                                      request: { await onboarding.requestCalendar() },
                                      openSettings: { SystemSettingsLink.openPrivacy(pane: "Privacy_Calendars") })
                }
                PermissionRow(symbol: "bell.badge.fill", tint: Palette.amber, title: "通知",
                              detail: "録音を始めるかの確認と、議事録ができたことを知らせます。") {
                    PermissionControl(state: notifications, requestTitle: "許可する",
                                      request: { await onboarding.requestNotifications() },
                                      openSettings: SystemSettingsLink.openNotifications)
                }
            }
            NoteLine(text: "あとから「システム設定 > プライバシーとセキュリティ」で変えられます。")
        }
        .task { await onboarding.refreshPermissions() }
        // システム設定で許可して戻ってきたら読み直す
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await onboarding.refreshPermissions() }
        }
    }

    private var microphone: PermissionState {
        switch onboarding.microphone {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private var calendar: PermissionState {
        switch onboarding.calendar {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private var notifications: PermissionState {
        switch onboarding.notifications {
        case .authorized, .provisional, .ephemeral: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// 会議アプリの音は事前に調べられないので、確かめるまでは「未確認」として扱う。
    private var systemAudio: PermissionState {
        switch onboarding.systemAudio {
        case .ok: .granted
        case .checking: .checking
        case .unknown, .failed: .notDetermined
        }
    }

    private var systemAudioFailure: String? {
        if case let .failed(message) = onboarding.systemAudio { message } else { nil }
    }
}

private struct PermissionRow<Control: View, Note: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var control: Control
    @ViewBuilder var note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            TintedTile(systemImage: symbol, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                note.padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .frame(minHeight: 34)
        }
        .padding(14)
        .cardBackground(cornerRadius: 14)
    }
}

extension PermissionRow where Note == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, control: control, note: { EmptyView() })
    }
}

private struct PermissionControl: View {
    let state: PermissionState
    let requestTitle: String
    let request: () async -> Void
    let openSettings: () -> Void

    var body: some View {
        switch state {
        case .granted:
            Label("許可済み", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Palette.mint)
        case .notDetermined:
            Button(requestTitle) { Task { await request() } }
        case .denied:
            VStack(alignment: .trailing, spacing: 4) {
                Button("システム設定を開く", action: openSettings)
                Text("許可されていません").font(.caption).foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("確かめています…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 3. 会議アプリ

private struct AppsPage: View {
    @Bindable var onboarding: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "録音する会議アプリ", detail: "選んだアプリから出る音を録音します。自分の声はマイクから別に録音します。")
            SectionCard("ブラウザで会議をするとき", systemImage: "globe") {
                Text("ブラウザはタブを分けて録音できないため、ほかのタブの動画や通知の音も入ります。会議は会議専用のブラウザで開いてください（例: 普段は Safari、会議は Chrome）。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: Self.columns(2), alignment: .leading, spacing: 0) {
                    ForEach(onboarding.browsers) { app in
                        ChoiceRow(selected: onboarding.browser == app.bundleID, title: app.name, icon: AppNames.icon(for: app.bundleID)) {
                            onboarding.browser = app.bundleID
                        }
                    }
                    ChoiceRow(selected: onboarding.browser == nil, title: "ブラウザでは会議をしない", symbol: "nosign") {
                        onboarding.browser = nil
                    }
                }
            }
            SectionCard("会議アプリ", systemImage: "video") {
                if onboarding.meetingApps.isEmpty && onboarding.otherApps.isEmpty {
                    Text("Zoom・Teams などの会議アプリは見つかりませんでした。")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Self.columns(3), alignment: .leading, spacing: 10) {
                        ForEach(onboarding.meetingApps) { app in
                            Toggle(isOn: Binding(get: { onboarding.apps.contains(app.bundleID) }, set: { on in
                                if on { onboarding.apps.insert(app.bundleID) } else { onboarding.apps.remove(app.bundleID) }
                            })) {
                                AppLabel(bundleID: app.bundleID, name: app.name)
                            }
                            .toggleStyle(.checkbox)
                        }
                        ForEach(onboarding.otherApps) { app in
                            HStack(spacing: 6) {
                                AppLabel(bundleID: app.bundleID, name: app.name)
                                Button {
                                    onboarding.removeOtherApp(app.bundleID)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("録音の対象から外す")
                            }
                        }
                    }
                }
            } trailing: {
                Button("ほかのアプリを追加…") { onboarding.addOtherApps() }
                    .controlSize(.small)
            }
            SectionCard("予定の時刻に会議の音がしたら", systemImage: "calendar.badge.clock") {
                Picker("予定の時刻に会議の音がしたら", selection: $onboarding.autoRecord) {
                    ForEach(OnboardingModel.AutoRecord.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(onboarding.autoRecord.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(autoRecordNotes, id: \.self) { NoteLine(text: $0, warning: true) }
            }
            if let error = onboarding.appsError {
                Banner(kind: .warning, text: error)
            }
        }
        .task { await onboarding.refreshPermissions() }
    }

    static func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .leading), count: count)
    }

    /// 自動の録音に要る許可がないときの注意。
    private var autoRecordNotes: [String] {
        guard onboarding.autoRecord != .manual else { return [] }
        var notes: [String] = []
        if onboarding.calendar != .fullAccess {
            notes.append("予定を読むには、カレンダーの許可が要ります（「戻る」で許可できます）。")
        }
        if onboarding.autoRecord == .confirm, ![.authorized, .provisional].contains(onboarding.notifications) {
            notes.append("録音するかを確かめる通知を出すには、通知の許可が要ります。")
        }
        return notes
    }
}

extension OnboardingModel.AutoRecord {
    var title: String {
        switch self {
        case .confirm: "確認してから録音"
        case .automatic: "すぐに録音"
        case .manual: "自動では録音しない"
        }
    }

    var detail: String {
        switch self {
        case .confirm: "おすすめ。カレンダーの予定の時刻に会議アプリから音がすると、録音するかを通知で確かめます。"
        case .automatic: "カレンダーの予定の時刻に会議アプリから音がすると、確かめずに録音を始めます。"
        case .manual: "自動では録音しません。メニューバーやショートカットから自分で始めます。"
        }
    }
}

// MARK: - 4. 文字起こしと要約

private struct ProvidersPage: View {
    @Bindable var onboarding: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "文字起こしと要約", detail: "会議が終わったら、選んだサービスに会議の音声と本文を送って、文字起こしと要約を作ります。送りたくない会議は、録音の前に「ローカルのみ」を選ぶと、この Mac の中で文字起こしします（要約は作りません）。")
            SectionCard("文字起こし", systemImage: "waveform") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ProviderCatalog.finalProviders) { entry in
                        ChoiceRow(selected: onboarding.finalProvider == entry.id, title: title(entry), detail: detail(entry)) {
                            onboarding.finalProvider = entry.id
                        }
                        if onboarding.finalProvider == entry.id, let key = entry.keyName {
                            KeyEntry(name: key, provider: entry.title, fallback: "キーを登録するまでは、この Mac の中で文字起こしします。")
                        }
                    }
                }
                LiveModelLine(onboarding: onboarding)
            }
            SectionCard("要約", systemImage: "sparkles") {
                VStack(alignment: .leading, spacing: 0) {
                    summaryChoice(.codex, title: "Codex（ChatGPT のログイン）", check: onboarding.codex)
                    summaryChoice(.claudeCode, title: "Claude Code（Claude のログイン）", check: onboarding.claudeCode)
                    summaryChoice(.anthropic, title: "Anthropic API（API キー・従量課金）", check: nil)
                    if onboarding.summaryProvider == .anthropic {
                        KeyEntry(name: APIKeys.anthropic, provider: "Anthropic", fallback: "キーを登録するまでは要約を作りません。")
                    }
                    summaryChoice(.none, title: "要約しない（文字起こしだけを保存）", check: nil)
                }
            }
        }
        .task { await onboarding.prepareSpeechModel() }
        .task { await onboarding.checkSummaryConnections() }
    }

    private func title(_ entry: ProviderCatalog.Entry) -> String {
        switch entry.id {
        case "elevenlabs.scribe_v2": "ElevenLabs Scribe v2（おすすめ）"
        case "local.speechanalyzer+fluidaudio": "この Mac の中で文字起こし"
        default: entry.title
        }
    }

    private func detail(_ entry: ProviderCatalog.Entry) -> String {
        switch entry.id {
        case "elevenlabs.scribe_v2": "話者の聞き分けが良く、日本語が最も自然です。API キーが要ります（従量課金）。"
        case "openai.gpt-4o-transcribe-diarize": "API キーが要ります。処理が遅く、発話を落とすことがあります。"
        case "local.speechanalyzer+fluidaudio": "キーは要りませんが、精度は下がります。初めての文字起こしでモデル（約 100 MB）をダウンロードします。"
        default: entry.detail
        }
    }

    private func summaryChoice(_ provider: SummaryProvider, title: String, check: OnboardingModel.CheckState?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ChoiceRow(selected: onboarding.summaryProvider == provider, title: title, action: { onboarding.summaryProvider = provider }) {
                if let check { ConnectionBadge(state: check) }
            }
            if onboarding.summaryProvider == provider, case let .failed(message)? = check {
                NoteLine(text: message, warning: true)
                    .padding(.leading, 32)
                    .padding(.bottom, 6)
                    .textSelection(.enabled)
            }
        }
    }
}

/// API キーの欄（設定と同じ `APIKeyRow`）。キーがないあいだの動きを添える。
private struct KeyEntry: View {
    @Environment(AppModel.self) private var model
    let name: String
    let provider: String
    let fallback: String
    /// 表示のたびに Keychain を読まないよう、表示時とキーの変更時にだけ確かめる（`APIKeyRow` と同じ）。
    @State private var missing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            APIKeyRow(name: name, provider: provider)
            if missing {
                Text(fallback).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        .onAppear { missing = !KeyStatus.resolve(name).isAvailable }
        .onChange(of: model.apiKeysRevision) { _, _ in missing = !KeyStatus.resolve(name).isAvailable }
    }
}

private struct ConnectionBadge: View {
    let state: OnboardingModel.CheckState

    var body: some View {
        switch state {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Label("ログイン済み", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(Palette.mint)
        case let .failed(message):
            Text("使えません")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(message)
        }
    }
}

/// ライブ字幕の日本語モデルの準備（この段階を開いたときに始める）。
private struct LiveModelLine: View {
    let onboarding: OnboardingModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "captions.bubble").foregroundStyle(.secondary)
            Text("ライブ字幕の日本語モデル")
            Spacer(minLength: 8)
            switch onboarding.speechModel {
            case .unknown:
                EmptyView()
            case .checking:
                ProgressView(value: onboarding.speechProgress)
                    .frame(width: 90)
                Text("\(Int((onboarding.speechProgress * 100).rounded())) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            case .ok:
                Label("準備できました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.mint)
            case let .failed(message):
                Text("ダウンロードできませんでした").foregroundStyle(Palette.amber).help(message)
                Button("もう一度") { Task { await onboarding.prepareSpeechModel() } }
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

// MARK: - 5. 試しの録音

private struct TestPage: View {
    @Bindable var onboarding: OnboardingModel
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var test: TestRecording { onboarding.test }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "試しの録音", detail: "会議アプリで動画や音楽を流しながら、マイクに向かって話してみてください。20 秒で終わり、保存はしません。")
            VStack(alignment: .leading, spacing: 14) {
                switch test.phase {
                case .idle:
                    startButton
                    Text("会議アプリの音・自分の声・ライブ字幕が届くかを確かめます。")
                        .foregroundStyle(.secondary)
                case .starting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("録音の準備をしています…").foregroundStyle(.secondary)
                    }
                case .running:
                    runningHeader
                    meters
                    CaptionsBox(captions: test.captions)
                case .finished:
                    results
                    CaptionsBox(captions: test.captions)
                case let .failed(message):
                    Banner(kind: .error, text: message, actionTitle: "もう一度", action: start)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .animation(Motion.layout, value: test.phase)
            fullTestCard
        }
    }

    private var startButton: some View {
        Button(action: start) {
            HStack(spacing: 8) {
                PillGlyph(kind: .record, size: 26)
                Text("試しの録音を始める")
            }
        }
        .buttonStyle(PillButtonStyle())
    }

    private var runningHeader: some View {
        HStack(spacing: 8) {
            AnimatedSymbol(systemName: "record.circle", pointSize: 15, weight: .semibold, color: Palette.record, effect: .pulse)
                .frame(width: 18, height: 18)
            Text("録音しています").font(.headline)
            Spacer()
            Text("残り \(test.remaining) 秒")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: test.remaining)
            Button("やめる") { test.cancel() }
        }
    }

    private var meters: some View {
        VStack(alignment: .leading, spacing: 10) {
            MeterRow(title: "会議アプリの音", feed: test.systemLevel, tint: Palette.periwinkle, heard: test.heardSystem)
            if model.settings.includeMic {
                MeterRow(title: "自分の声", feed: test.micLevel, tint: SpeakerPalette.me, heard: test.heardMic)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResultRow(ok: test.heardSystem, title: "会議アプリの音",
                      okText: "録音できました",
                      ngText: "聞こえませんでした。会議アプリで音を流しながら、もう一度試してください。音が出ているのに録音できないときは、システム設定で Minutes を許可してください。")
            if model.settings.includeMic {
                ResultRow(ok: test.heardMic, title: "自分の声",
                          okText: "録音できました",
                          ngText: "聞こえませんでした。マイクの許可と、設定 > 録音 のマイクを確かめてください。")
            }
            ResultRow(ok: test.sawCaptions, title: "ライブ字幕",
                      okText: "字幕が出ました",
                      ngText: "字幕が出ませんでした。話してから字幕になるまで数秒かかります。")
            HStack(spacing: 8) {
                Button("もう一度試す", action: start)
                if !test.heardSystem {
                    Button("システム設定を開く", action: SystemSettingsLink.openSystemAudio)
                }
            }
            .padding(.top, 2)
        }
    }

    private var fullTestCard: some View {
        SectionCard("議事録まで試す（任意）", systemImage: "doc.text") {
            Text("20 秒を会議として録音し、文字起こしと要約まで作ります。「試しの録音」という会議として保存されます（あとで削除できます）。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch onboarding.fullTest {
            case .idle:
                Button("議事録まで試す") { Task { await onboarding.runFullTest() } }
                    .disabled(test.phase == .running || test.phase == .starting || model.isRecording)
            case let .recording(remaining):
                HStack(spacing: 8) {
                    AnimatedSymbol(systemName: "record.circle", pointSize: 13, weight: .semibold, color: Palette.record, effect: .pulse)
                        .frame(width: 16, height: 16)
                    Text("録音しています（残り \(remaining) 秒）")
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: remaining)
                }
            case .processing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("文字起こしと要約を作っています…").foregroundStyle(.secondary)
                }
            case let .done(meetingId):
                HStack(spacing: 10) {
                    Label("議事録ができました", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.mint)
                    Button("議事録を開く") { openMeeting(meetingId) }
                }
            case let .failed(message):
                Banner(kind: .error, text: message, actionTitle: "もう一度") { Task { await onboarding.runFullTest() } }
            }
        }
    }

    private func start() {
        Task { await onboarding.startTest() }
    }

    private func openMeeting(_ id: String) {
        guard let url = URL(string: "minutes://meeting/\(id)") else { return }
        model.handle(url: url)
        openWindow(id: "main")
        model.setMainWindowVisible(true)
    }
}

private struct MeterRow: View {
    let title: String
    let feed: LevelFeed
    let tint: Color
    let heard: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: heard ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(heard ? Palette.mint : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.symbol, value: heard)
            Text(title)
                .frame(width: 110, alignment: .leading)
            LevelMeter(feed: feed, tint: tint)
        }
    }
}

private struct ResultRow: View {
    let ok: Bool
    let title: String
    let okText: String
    let ngText: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Palette.mint : Palette.amber)
            Text(title)
                .font(.headline)
                .frame(width: 110, alignment: .leading)
            Text(ok ? okText : ngText)
                .foregroundStyle(ok ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 試しの録音の字幕（直近の 4 行）。
private struct CaptionsBox: View {
    let captions: [TestRecording.Caption]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if captions.isEmpty {
                Text("話すと、ここに字幕が出ます。")
                    .foregroundStyle(.tertiary)
            }
            ForEach(captions) { caption in
                let mine = caption.track == TrackMerger.micTrack
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(mine ? "自分" : "会議")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(mine ? SpeakerPalette.me : Palette.periwinkle)
                        .frame(width: 30, alignment: .leading)
                    Text(caption.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .padding(12)
        .background(Surface.card, in: .rect(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 6. 準備完了

private struct DonePage: View {
    @Bindable var onboarding: OnboardingModel
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "準備ができました", detail: "Minutes はメニューバーに常駐して、会議を待ちます。")
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "menubar.rectangle", tint: Palette.periwinkle, title: "メニューバーから録音",
                           detail: "メニューバーの Minutes を押すと、録音の開始・停止と今日の予定が出ます。録音中はメニューバーに経過時間が出ます。")
                FeatureRow(symbol: autoRecordSymbol, tint: Palette.teal, title: autoRecordTitle, detail: autoRecordDetail)
                FeatureRow(symbol: "keyboard", tint: Palette.amber, title: "ショートカット", detail: shortcutDetail)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            SectionCard("録音することを伝える", systemImage: "person.wave.2") {
                Text("録音する前に、参加者に伝えましょう。この文面は、録音の画面とメニューからいつでもコピーできます。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $onboarding.notice)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 58)
                    .padding(8)
                    .background(Surface.card, in: .rect(cornerRadius: 10, style: .continuous))
                HStack(spacing: 8) {
                    Button {
                        RecordingNotice.copy(onboarding.notice.trimmingCharacters(in: .whitespacesAndNewlines))
                        copied = true
                    } label: {
                        Label(copied ? "コピーしました" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button("既定の文面に戻す") { onboarding.notice = AppSettings.defaultRecordingNotice }
                        .disabled(onboarding.notice == AppSettings.defaultRecordingNotice)
                }
            }
        }
        .onChange(of: onboarding.notice) { _, _ in copied = false }
    }

    private var autoRecordSymbol: String {
        onboarding.autoRecord == .manual ? "hand.tap" : "calendar.badge.clock"
    }

    private var autoRecordTitle: String {
        switch onboarding.autoRecord {
        case .confirm: "予定の会議は、確認してから録音"
        case .automatic: "予定の会議は、自動で録音"
        case .manual: "録音は自分で始める"
        }
    }

    private var autoRecordDetail: String {
        switch onboarding.autoRecord {
        case .confirm: "カレンダーの予定の時刻に会議アプリから音がすると、録音するかを通知で確かめます。"
        case .automatic: "カレンダーの予定の時刻に会議アプリから音がすると、録音を始めます。"
        case .manual: "自動では録音しません。設定 > 録音 で変えられます。"
        }
    }

    private var shortcutDetail: String {
        if let shortcut = model.settings.globalShortcut {
            "\(shortcut.display) で、どのアプリからでも録音を始めたり止めたりできます。"
        } else {
            "設定 > 録音 で、どのアプリからでも録音を始められるショートカットを決められます。"
        }
    }
}
